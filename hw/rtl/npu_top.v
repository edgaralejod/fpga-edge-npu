// npu_top: AC701 top level for the PCIe-attached NPU.
//
//   PCIe Gen2 x1 (edge connector) → card_sys block design:
//     axi_pcie bridge (AMD PG055), device 10ee:ed10
//       BAR0 → npu_regs                 control, status, doorbells
//       AXI slave window ← npu_cq       the card reaches host memory itself
//       MSI ← npu_cq                    completion interrupts
//     MIG → DDR3 SODIMM, 1 GiB          card memory, shared by npu_cq, mem_bw
//                                       and a JTAG-to-AXI master
//     System ILAs, VIO                  debug, on the Si570 user clock
//
//   npu_cq   command queue engine: fetches commands from host memory, copies
//            between host and card memory, runs GEMM on npu_mm, writes
//            completions back (docs/command-queue.md)
//   mem_bw   card-side DDR3 bandwidth engine
//
// card_sys is rebuilt from hw/bd/card_sys.tcl. Roadmap phases 3 and 4: the
// host drives the card through rings in its own memory, and the card computes.
//
// LEDs (GPIO_LED_0..3): 0 = link up, 1 = PCIe user-clock heartbeat (~1 Hz),
// 2..3 = software controlled through npu_regs CONTROL.

`timescale 1ns / 1ps
`default_nettype none

module npu_top #(
  parameter [31:0] BUILD_ID = 32'h0000_0000
) (
  input  wire        pcie_refclk_p,
  input  wire        pcie_refclk_n,
  input  wire        pcie_perst_n,
  output wire [0:0]  pcie_txp,
  output wire [0:0]  pcie_txn,
  input  wire [0:0]  pcie_rxp,
  input  wire [0:0]  pcie_rxn,

  // DDR3 SODIMM and its 200 MHz system clock (pins from the MIG board preset)
  input  wire        sys_clk_p,
  input  wire        sys_clk_n,
  output wire [13:0] ddr3_addr,
  output wire [2:0]  ddr3_ba,
  output wire        ddr3_cas_n,
  output wire [0:0]  ddr3_ck_n,
  output wire [0:0]  ddr3_ck_p,
  output wire [0:0]  ddr3_cke,
  output wire [0:0]  ddr3_cs_n,
  output wire [7:0]  ddr3_dm,
  inout  wire [63:0] ddr3_dq,
  inout  wire [7:0]  ddr3_dqs_n,
  inout  wire [7:0]  ddr3_dqs_p,
  output wire [0:0]  ddr3_odt,
  output wire        ddr3_ras_n,
  output wire        ddr3_reset_n,
  output wire        ddr3_we_n,

  input  wire        user_clk_p,  // Si570, 156.25 MHz at power-up: debug clock
  input  wire        user_clk_n,
  input  wire        cpu_reset,   // CPU_RESET pushbutton, active high: resets the MIG

  output wire [3:0]  led
);

  // 100 MHz PCIe reference clock from the host, through the edge connector.
  wire pcie_refclk;
  IBUFDS_GTE2 refclk_ibuf (
    .I     (pcie_refclk_p),
    .IB    (pcie_refclk_n),
    .CEB   (1'b0),
    .O     (pcie_refclk),
    .ODIV2 ()
  );

  // Free-running debug clock for the VIO and the debug hub: the Si570's
  // 156.25 MHz divided to 78.125 MHz. At the full rate the hub side of the
  // 512-bit MIG ILA, spread across the device, missed timing on routing alone.
  wire user_clk_ibuf, dbg_clk_mmcm, dbg_fb, dbg_clk;
  IBUFDS user_clk_buf (.I(user_clk_p), .IB(user_clk_n), .O(user_clk_ibuf));
  MMCME2_BASE #(
    .CLKIN1_PERIOD    (6.400),
    .CLKFBOUT_MULT_F  (6.000),   // VCO 937.5 MHz
    .CLKOUT0_DIVIDE_F (12.000)   // 78.125 MHz
  ) dbg_mmcm (
    .CLKIN1 (user_clk_ibuf), .CLKFBIN (dbg_fb), .CLKFBOUT (dbg_fb),
    .CLKOUT0 (dbg_clk_mmcm), .RST (1'b0), .PWRDWN (1'b0),
    .CLKFBOUTB (), .CLKOUT0B (), .CLKOUT1 (), .CLKOUT1B (), .CLKOUT2 (), .CLKOUT2B (),
    .CLKOUT3 (), .CLKOUT3B (), .CLKOUT4 (), .CLKOUT5 (), .CLKOUT6 (), .LOCKED ()
  );
  BUFG dbg_clk_bufg (.I(dbg_clk_mmcm), .O(dbg_clk));

  // ---------------------------------------------------------------------------
  // Signals between card_sys and the project's logic
  wire        clk, rst_n;           // bridge clock (125 MHz) and reset
  wire        link_up;
  wire        msi_request, msi_grant, msi_enable;
  wire        ddr_calib_done, ddr_mmcm_locked;
  wire        ui_clk, ui_aresetn;   // MIG user clock (100 MHz) and its AXI reset

  // BAR0 → npu_regs (AXI4-Lite)
  wire [31:0] r_awaddr, r_wdata, r_araddr, r_rdata;
  wire [3:0]  r_wstrb;
  wire [1:0]  r_bresp, r_rresp;
  wire        r_awvalid, r_awready, r_wvalid, r_wready, r_bvalid, r_bready;
  wire        r_arvalid, r_arready, r_rvalid, r_rready;

  // npu_cq host port (h_*) and card port (c_*), 64-bit AXI4
  wire [31:0] h_awaddr, h_araddr, c_awaddr, c_araddr;
  wire [7:0]  h_awlen, h_arlen, c_awlen, c_arlen, h_wstrb, c_wstrb;
  wire [2:0]  h_awsize, h_arsize, c_awsize, c_arsize;
  wire [1:0]  h_awburst, h_arburst, c_awburst, c_arburst, h_bresp, h_rresp, c_bresp, c_rresp;
  wire [63:0] h_wdata, h_rdata, c_wdata, c_rdata;
  wire        h_awvalid, h_awready, h_wlast, h_wvalid, h_wready, h_bvalid, h_bready;
  wire        h_arvalid, h_arready, h_rlast, h_rvalid, h_rready;
  wire        c_awvalid, c_awready, c_wlast, c_wvalid, c_wready, c_bvalid, c_bready;
  wire        c_arvalid, c_arready, c_rlast, c_rvalid, c_rready;

  // mem_bw's AXI4 master (S_AXI_BW)
  wire [31:0]  bw_awaddr, bw_araddr;
  wire [7:0]   bw_awlen, bw_arlen;
  wire [2:0]   bw_awsize, bw_arsize;
  wire [1:0]   bw_awburst, bw_arburst, bw_bresp, bw_rresp;
  wire [3:0]   bw_awcache, bw_arcache;
  wire [2:0]   bw_awprot, bw_arprot;
  wire         bw_awlock, bw_arlock;
  wire         bw_awvalid, bw_awready, bw_wlast, bw_wvalid, bw_wready, bw_bvalid, bw_bready;
  wire         bw_arvalid, bw_arready, bw_rlast, bw_rvalid, bw_rready;
  wire [511:0] bw_wdata, bw_rdata;
  wire [63:0]  bw_wstrb;

  card_sys card_sys (
    .pcie_refclk (pcie_refclk), .pcie_perst_n (pcie_perst_n),
    .pcie_mgt_txp (pcie_txp), .pcie_mgt_txn (pcie_txn), .pcie_mgt_rxp (pcie_rxp), .pcie_mgt_rxn (pcie_rxn),
    .pcie_aclk (clk), .pcie_aresetn (rst_n), .pcie_link_up (link_up),
    .msi_request (msi_request), .msi_grant (msi_grant), .msi_enable (msi_enable),

    .M_AXIL_REGS_awaddr (r_awaddr), .M_AXIL_REGS_awprot (), .M_AXIL_REGS_awvalid (r_awvalid), .M_AXIL_REGS_awready (r_awready),
    .M_AXIL_REGS_wdata  (r_wdata),  .M_AXIL_REGS_wstrb  (r_wstrb), .M_AXIL_REGS_wvalid (r_wvalid), .M_AXIL_REGS_wready (r_wready),
    .M_AXIL_REGS_bresp  (r_bresp),  .M_AXIL_REGS_bvalid (r_bvalid), .M_AXIL_REGS_bready (r_bready),
    .M_AXIL_REGS_araddr (r_araddr), .M_AXIL_REGS_arprot (), .M_AXIL_REGS_arvalid (r_arvalid), .M_AXIL_REGS_arready (r_arready),
    .M_AXIL_REGS_rdata  (r_rdata),  .M_AXIL_REGS_rresp  (r_rresp), .M_AXIL_REGS_rvalid (r_rvalid), .M_AXIL_REGS_rready (r_rready),

    .S_AXI_HOST_awaddr (h_awaddr), .S_AXI_HOST_awlen (h_awlen), .S_AXI_HOST_awsize (h_awsize), .S_AXI_HOST_awburst (h_awburst),
    .S_AXI_HOST_awlock (1'b0), .S_AXI_HOST_awcache (4'b0010), .S_AXI_HOST_awprot (3'b000), .S_AXI_HOST_awqos (4'd0),
    .S_AXI_HOST_awvalid (h_awvalid), .S_AXI_HOST_awready (h_awready),
    .S_AXI_HOST_wdata (h_wdata), .S_AXI_HOST_wstrb (h_wstrb), .S_AXI_HOST_wlast (h_wlast),
    .S_AXI_HOST_wvalid (h_wvalid), .S_AXI_HOST_wready (h_wready),
    .S_AXI_HOST_bresp (h_bresp), .S_AXI_HOST_bvalid (h_bvalid), .S_AXI_HOST_bready (h_bready),
    .S_AXI_HOST_araddr (h_araddr), .S_AXI_HOST_arlen (h_arlen), .S_AXI_HOST_arsize (h_arsize), .S_AXI_HOST_arburst (h_arburst),
    .S_AXI_HOST_arlock (1'b0), .S_AXI_HOST_arcache (4'b0010), .S_AXI_HOST_arprot (3'b000), .S_AXI_HOST_arqos (4'd0),
    .S_AXI_HOST_arvalid (h_arvalid), .S_AXI_HOST_arready (h_arready),
    .S_AXI_HOST_rdata (h_rdata), .S_AXI_HOST_rresp (h_rresp), .S_AXI_HOST_rlast (h_rlast),
    .S_AXI_HOST_rvalid (h_rvalid), .S_AXI_HOST_rready (h_rready),

    .S_AXI_NPU_awaddr (c_awaddr), .S_AXI_NPU_awlen (c_awlen), .S_AXI_NPU_awsize (c_awsize), .S_AXI_NPU_awburst (c_awburst),
    .S_AXI_NPU_awvalid (c_awvalid), .S_AXI_NPU_awready (c_awready),
    .S_AXI_NPU_wdata (c_wdata), .S_AXI_NPU_wstrb (c_wstrb), .S_AXI_NPU_wlast (c_wlast),
    .S_AXI_NPU_wvalid (c_wvalid), .S_AXI_NPU_wready (c_wready),
    .S_AXI_NPU_bresp (c_bresp), .S_AXI_NPU_bvalid (c_bvalid), .S_AXI_NPU_bready (c_bready),
    .S_AXI_NPU_araddr (c_araddr), .S_AXI_NPU_arlen (c_arlen), .S_AXI_NPU_arsize (c_arsize), .S_AXI_NPU_arburst (c_arburst),
    .S_AXI_NPU_arvalid (c_arvalid), .S_AXI_NPU_arready (c_arready),
    .S_AXI_NPU_rdata (c_rdata), .S_AXI_NPU_rresp (c_rresp), .S_AXI_NPU_rlast (c_rlast),
    .S_AXI_NPU_rvalid (c_rvalid), .S_AXI_NPU_rready (c_rready),

    .ui_clk (ui_clk), .ui_aresetn (ui_aresetn),
    .S_AXI_BW_awaddr  (bw_awaddr),  .S_AXI_BW_awlen  (bw_awlen),  .S_AXI_BW_awsize  (bw_awsize),
    .S_AXI_BW_awburst (bw_awburst), .S_AXI_BW_awvalid (bw_awvalid), .S_AXI_BW_awready (bw_awready),
    .S_AXI_BW_awcache (bw_awcache), .S_AXI_BW_awprot  (bw_awprot),  .S_AXI_BW_awlock  (bw_awlock),
    .S_AXI_BW_wdata   (bw_wdata),   .S_AXI_BW_wstrb  (bw_wstrb),  .S_AXI_BW_wlast   (bw_wlast),
    .S_AXI_BW_wvalid  (bw_wvalid),  .S_AXI_BW_wready (bw_wready),
    .S_AXI_BW_bresp   (bw_bresp),   .S_AXI_BW_bvalid (bw_bvalid), .S_AXI_BW_bready  (bw_bready),
    .S_AXI_BW_araddr  (bw_araddr),  .S_AXI_BW_arlen  (bw_arlen),  .S_AXI_BW_arsize  (bw_arsize),
    .S_AXI_BW_arburst (bw_arburst), .S_AXI_BW_arvalid (bw_arvalid), .S_AXI_BW_arready (bw_arready),
    .S_AXI_BW_arcache (bw_arcache), .S_AXI_BW_arprot  (bw_arprot),  .S_AXI_BW_arlock  (bw_arlock),
    .S_AXI_BW_rdata   (bw_rdata),   .S_AXI_BW_rresp  (bw_rresp),  .S_AXI_BW_rlast   (bw_rlast),
    .S_AXI_BW_rvalid  (bw_rvalid),  .S_AXI_BW_rready (bw_rready),

    .sys_diff_clock_clk_p (sys_clk_p),
    .sys_diff_clock_clk_n (sys_clk_n),
    .ddr3_sdram_addr    (ddr3_addr),    .ddr3_sdram_ba      (ddr3_ba),
    .ddr3_sdram_cas_n   (ddr3_cas_n),   .ddr3_sdram_ras_n   (ddr3_ras_n),   .ddr3_sdram_we_n (ddr3_we_n),
    .ddr3_sdram_ck_p    (ddr3_ck_p),    .ddr3_sdram_ck_n    (ddr3_ck_n),
    .ddr3_sdram_cke     (ddr3_cke),     .ddr3_sdram_cs_n    (ddr3_cs_n),    .ddr3_sdram_odt  (ddr3_odt),
    .ddr3_sdram_dm      (ddr3_dm),      .ddr3_sdram_dq      (ddr3_dq),
    .ddr3_sdram_dqs_p   (ddr3_dqs_p),   .ddr3_sdram_dqs_n   (ddr3_dqs_n),
    .ddr3_sdram_reset_n (ddr3_reset_n),
    .dbg_clk         (dbg_clk),
    .ddr_rst         (cpu_reset),
    .ddr_calib_done  (ddr_calib_done),
    .ddr_mmcm_locked (ddr_mmcm_locked)
  );

  // ---------------------------------------------------------------------------
  // Control registers on BAR0
  wire [1:0]  user_led;
  wire        irq_req, irq_ack;
  wire [31:0] cycles_lo;
  wire        cq_enable, cq_irq_en, cq_sq_tail_wr, cq_cq_head_wr;
  wire [3:0]  cq_log2;
  wire [63:0] cq_sq_base, cq_cq_base;
  wire [11:0] cq_doorbell;
  wire        cq_busy, cq_stalled, cq_axi_err, cq_cfg_err;
  wire [31:0] cq_completed;
  wire        bw_start, bw_read, bw_busy;
  wire [4:0]  bw_outstanding;
  wire [15:0] bw_seed;
  wire [31:0] bw_addr, bw_len, bw_runs, bw_cycles, bw_mismatches, bw_errors;
  wire [31:0] dma_writes, dma_reads, dma_errors;

  npu_regs #(
    .BUILD_ID     (BUILD_ID),
    .CARD_MEM_MIB (16'd1024)
  ) regs (
    .clk            (clk),
    .rst_n          (rst_n),
    .s_axil_awaddr  (r_awaddr),  .s_axil_awvalid (r_awvalid), .s_axil_awready (r_awready),
    .s_axil_wdata   (r_wdata),   .s_axil_wstrb   (r_wstrb),   .s_axil_wvalid  (r_wvalid), .s_axil_wready (r_wready),
    .s_axil_bresp   (r_bresp),   .s_axil_bvalid  (r_bvalid),  .s_axil_bready  (r_bready),
    .s_axil_araddr  (r_araddr),  .s_axil_arvalid (r_arvalid), .s_axil_arready (r_arready),
    .s_axil_rdata   (r_rdata),   .s_axil_rresp   (r_rresp),   .s_axil_rvalid  (r_rvalid), .s_axil_rready (r_rready),
    .link_up         (link_up),
    .ddr_calib_done  (ddr_calib_done),
    .ddr_mmcm_locked (ddr_mmcm_locked),
    .dma_writes      (dma_writes),
    .dma_reads       (dma_reads),
    .dma_errors      (dma_errors),
    .bw_start        (bw_start),
    .bw_read         (bw_read),
    .bw_outstanding  (bw_outstanding),
    .bw_seed         (bw_seed),
    .bw_addr         (bw_addr),
    .bw_len          (bw_len),
    .bw_busy         (bw_busy),
    .bw_runs         (bw_runs),
    .bw_cycles       (bw_cycles),
    .bw_mismatches   (bw_mismatches),
    .bw_errors       (bw_errors),
    .user_led        (user_led),
    .irq_req         (irq_req),
    .irq_ack         (irq_ack),
    .cycles_lo       (cycles_lo),
    .cq_enable (cq_enable), .cq_irq_en (cq_irq_en), .cq_log2 (cq_log2),
    .cq_sq_base (cq_sq_base), .cq_cq_base (cq_cq_base),
    .cq_sq_tail_wr (cq_sq_tail_wr), .cq_cq_head_wr (cq_cq_head_wr), .cq_doorbell (cq_doorbell),
    .cq_busy (cq_busy), .cq_stalled (cq_stalled), .cq_axi_err (cq_axi_err), .cq_cfg_err (cq_cfg_err),
    .cq_completed (cq_completed)
  );

  // The IRQ register's request raises one MSI through npu_cq's requester; the
  // grant that follows is its acknowledgement.
  reg irq_req_d;
  always @(posedge clk) irq_req_d <= rst_n ? irq_req : 1'b0;
  assign irq_ack = msi_grant;

  // ---------------------------------------------------------------------------
  // Command queue engine, with the GEMM engine inside
  npu_cq cq (
    .clk (clk), .rst_n (rst_n),
    .cfg_enable (cq_enable), .cfg_irq_en (cq_irq_en), .cfg_log2 (cq_log2),
    .cfg_sq_base (cq_sq_base), .cfg_cq_base (cq_cq_base),
    .sq_tail_wr (cq_sq_tail_wr), .sq_tail_val (cq_doorbell),
    .cq_head_wr (cq_cq_head_wr), .cq_head_val (cq_doorbell),
    .cycles (cycles_lo),
    .busy (cq_busy), .stalled (cq_stalled), .axi_err (cq_axi_err), .cfg_err (cq_cfg_err),
    .completed (cq_completed),
    .msi_enable (msi_enable), .msi_request (msi_request), .msi_grant (msi_grant),
    .irq_test (irq_req && !irq_req_d),
    .h_awaddr (h_awaddr), .h_awlen (h_awlen), .h_awsize (h_awsize), .h_awburst (h_awburst), .h_awvalid (h_awvalid), .h_awready (h_awready),
    .h_wdata (h_wdata), .h_wstrb (h_wstrb), .h_wlast (h_wlast), .h_wvalid (h_wvalid), .h_wready (h_wready),
    .h_bresp (h_bresp), .h_bvalid (h_bvalid), .h_bready (h_bready),
    .h_araddr (h_araddr), .h_arlen (h_arlen), .h_arsize (h_arsize), .h_arburst (h_arburst), .h_arvalid (h_arvalid), .h_arready (h_arready),
    .h_rdata (h_rdata), .h_rresp (h_rresp), .h_rlast (h_rlast), .h_rvalid (h_rvalid), .h_rready (h_rready),
    .c_awaddr (c_awaddr), .c_awlen (c_awlen), .c_awsize (c_awsize), .c_awburst (c_awburst), .c_awvalid (c_awvalid), .c_awready (c_awready),
    .c_wdata (c_wdata), .c_wstrb (c_wstrb), .c_wlast (c_wlast), .c_wvalid (c_wvalid), .c_wready (c_wready),
    .c_bresp (c_bresp), .c_bvalid (c_bvalid), .c_bready (c_bready),
    .c_araddr (c_araddr), .c_arlen (c_arlen), .c_arsize (c_arsize), .c_arburst (c_arburst), .c_arvalid (c_arvalid), .c_arready (c_arready),
    .c_rdata (c_rdata), .c_rresp (c_rresp), .c_rlast (c_rlast), .c_rvalid (c_rvalid), .c_rready (c_rready)
  );

  // Traffic counters on the engine's card port (DMA_WRITES, DMA_READS, DMA_ERRORS).
  axi_dma_mon dma_mon (
    .clk     (clk),       .rst_n   (rst_n),
    .awvalid (c_awvalid), .awready (c_awready),
    .arvalid (c_arvalid), .arready (c_arready),
    .bvalid  (c_bvalid),  .bready  (c_bready),  .bresp (c_bresp),
    .rvalid  (c_rvalid),  .rready  (c_rready),  .rresp (c_rresp),
    .writes  (dma_writes), .reads  (dma_reads), .errors (dma_errors)
  );

  // ---------------------------------------------------------------------------
  // Card-side DDR3 bandwidth engine, controlled from npu_regs (BW_*).
  mem_bw bw (
    .ctl_clk (clk), .ctl_rst_n (rst_n),
    .ctl_start (bw_start), .ctl_read (bw_read), .ctl_addr (bw_addr), .ctl_len (bw_len),
    .ctl_outstanding (bw_outstanding), .ctl_seed (bw_seed),
    .ctl_busy (bw_busy), .ctl_cycles (bw_cycles), .ctl_mismatches (bw_mismatches),
    .ctl_errors (bw_errors), .ctl_runs (bw_runs),
    .m_clk (ui_clk), .m_rst_n (ui_aresetn),
    .m_axi_awaddr (bw_awaddr), .m_axi_awlen (bw_awlen), .m_axi_awsize (bw_awsize), .m_axi_awburst (bw_awburst),
    .m_axi_awcache (bw_awcache), .m_axi_awprot (bw_awprot), .m_axi_awlock (bw_awlock),
    .m_axi_awvalid (bw_awvalid), .m_axi_awready (bw_awready),
    .m_axi_wdata (bw_wdata), .m_axi_wstrb (bw_wstrb), .m_axi_wlast (bw_wlast),
    .m_axi_wvalid (bw_wvalid), .m_axi_wready (bw_wready),
    .m_axi_bresp (bw_bresp), .m_axi_bvalid (bw_bvalid), .m_axi_bready (bw_bready),
    .m_axi_araddr (bw_araddr), .m_axi_arlen (bw_arlen), .m_axi_arsize (bw_arsize), .m_axi_arburst (bw_arburst),
    .m_axi_arcache (bw_arcache), .m_axi_arprot (bw_arprot), .m_axi_arlock (bw_arlock),
    .m_axi_arvalid (bw_arvalid), .m_axi_arready (bw_arready),
    .m_axi_rdata (bw_rdata), .m_axi_rresp (bw_rresp), .m_axi_rlast (bw_rlast),
    .m_axi_rvalid (bw_rvalid), .m_axi_rready (bw_rready)
  );

  // ---------------------------------------------------------------------------
  // LEDs. bit 26 of a 125 MHz counter toggles about every 0.54 s.
  reg [26:0] heartbeat = 27'd0;
  always @(posedge clk) heartbeat <= heartbeat + 27'd1;

  assign led = {user_led, heartbeat[26], link_up};

endmodule

`default_nettype wire
