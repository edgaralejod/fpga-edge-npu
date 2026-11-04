// npu_top: AC701 top level for the PCIe-attached NPU.
//
//   PCIe Gen2 x1 (edge connector) -> XDMA
//     BAR0  AXI-Lite master -> npu_regs        (control and status)
//     BAR1  XDMA DMA engine -> AXI4 master -> card_mem: DDR3 SODIMM, 1 GiB
//
// card_mem is a block design (hw/bd/card_mem.tcl): the MIG DDR3 controller,
// a SmartConnect shared with a JTAG-to-AXI master and the card-side
// bandwidth engine mem_bw, System ILAs with AXI
// protocol checkers on both sides, and a VIO. The debug cores run from the
// board's Si570 user clock (divided to 78.125 MHz), so Vivado's Hardware
// Manager reaches them with no PCIe host and with the MIG in reset.
//
// Roadmap phase 2. The inference engine attaches here in later phases.
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

  wire axi_aclk;     // 125 MHz user clock from XDMA
  wire axi_aresetn;
  wire user_lnk_up;
  wire usr_irq_req;
  wire usr_irq_ack;

  // XDMA AXI4 master (DMA data path)
  wire [3:0]  m_axi_awid,   m_axi_arid,   m_axi_bid,   m_axi_rid;
  wire [63:0] m_axi_awaddr, m_axi_araddr;
  wire [7:0]  m_axi_awlen,  m_axi_arlen;
  wire [2:0]  m_axi_awsize, m_axi_arsize, m_axi_awprot, m_axi_arprot;
  wire [1:0]  m_axi_awburst, m_axi_arburst, m_axi_bresp, m_axi_rresp;
  wire [3:0]  m_axi_awcache, m_axi_arcache;
  wire        m_axi_awlock, m_axi_arlock;
  wire        m_axi_awvalid, m_axi_awready, m_axi_wvalid, m_axi_wready, m_axi_wlast;
  wire        m_axi_bvalid, m_axi_bready, m_axi_arvalid, m_axi_arready;
  wire        m_axi_rvalid, m_axi_rready, m_axi_rlast;
  wire [63:0] m_axi_wdata, m_axi_rdata;
  wire [7:0]  m_axi_wstrb;

  // XDMA AXI-Lite master (BAR0)
  wire [31:0] m_axil_awaddr, m_axil_araddr, m_axil_wdata, m_axil_rdata;
  wire [2:0]  m_axil_awprot, m_axil_arprot;
  wire [3:0]  m_axil_wstrb;
  wire [1:0]  m_axil_bresp, m_axil_rresp;
  wire        m_axil_awvalid, m_axil_awready, m_axil_wvalid, m_axil_wready;
  wire        m_axil_bvalid, m_axil_bready, m_axil_arvalid, m_axil_arready;
  wire        m_axil_rvalid, m_axil_rready;

  xdma_0 xdma (
    .sys_clk          (pcie_refclk),
    .sys_rst_n        (pcie_perst_n),
    .user_lnk_up      (user_lnk_up),
    .pci_exp_txp      (pcie_txp),
    .pci_exp_txn      (pcie_txn),
    .pci_exp_rxp      (pcie_rxp),
    .pci_exp_rxn      (pcie_rxn),
    .axi_aclk         (axi_aclk),
    .axi_aresetn      (axi_aresetn),
    .usr_irq_req      (usr_irq_req),
    .usr_irq_ack      (usr_irq_ack),
    .msi_enable       (),
    .msi_vector_width (),

    .m_axi_awready (m_axi_awready), .m_axi_wready (m_axi_wready),
    .m_axi_bid     (m_axi_bid),     .m_axi_bresp  (m_axi_bresp),  .m_axi_bvalid (m_axi_bvalid),
    .m_axi_arready (m_axi_arready),
    .m_axi_rid     (m_axi_rid),     .m_axi_rdata  (m_axi_rdata),  .m_axi_rresp  (m_axi_rresp),
    .m_axi_rlast   (m_axi_rlast),   .m_axi_rvalid (m_axi_rvalid),
    .m_axi_awid    (m_axi_awid),    .m_axi_awaddr (m_axi_awaddr), .m_axi_awlen  (m_axi_awlen),
    .m_axi_awsize  (m_axi_awsize),  .m_axi_awburst(m_axi_awburst),.m_axi_awprot (m_axi_awprot),
    .m_axi_awvalid (m_axi_awvalid), .m_axi_awlock (m_axi_awlock), .m_axi_awcache(m_axi_awcache),
    .m_axi_wdata   (m_axi_wdata),   .m_axi_wstrb  (m_axi_wstrb),  .m_axi_wlast  (m_axi_wlast),
    .m_axi_wvalid  (m_axi_wvalid),  .m_axi_bready (m_axi_bready),
    .m_axi_arid    (m_axi_arid),    .m_axi_araddr (m_axi_araddr), .m_axi_arlen  (m_axi_arlen),
    .m_axi_arsize  (m_axi_arsize),  .m_axi_arburst(m_axi_arburst),.m_axi_arprot (m_axi_arprot),
    .m_axi_arvalid (m_axi_arvalid), .m_axi_arlock (m_axi_arlock), .m_axi_arcache(m_axi_arcache),
    .m_axi_rready  (m_axi_rready),

    .m_axil_awaddr (m_axil_awaddr), .m_axil_awprot (m_axil_awprot),
    .m_axil_awvalid(m_axil_awvalid),.m_axil_awready(m_axil_awready),
    .m_axil_wdata  (m_axil_wdata),  .m_axil_wstrb  (m_axil_wstrb),
    .m_axil_wvalid (m_axil_wvalid), .m_axil_wready (m_axil_wready),
    .m_axil_bvalid (m_axil_bvalid), .m_axil_bresp  (m_axil_bresp), .m_axil_bready(m_axil_bready),
    .m_axil_araddr (m_axil_araddr), .m_axil_arprot (m_axil_arprot),
    .m_axil_arvalid(m_axil_arvalid),.m_axil_arready(m_axil_arready),
    .m_axil_rdata  (m_axil_rdata),  .m_axil_rresp  (m_axil_rresp),
    .m_axil_rvalid (m_axil_rvalid), .m_axil_rready (m_axil_rready)
  );

  // ---------------------------------------------------------------------------
  // Control registers on BAR0
  wire [1:0] user_led;

  npu_regs #(
    .BUILD_ID     (BUILD_ID),
    .CARD_MEM_MIB (16'd1024)
  ) regs (
    .clk            (axi_aclk),
    .rst_n          (axi_aresetn),
    .s_axil_awaddr  (m_axil_awaddr),
    .s_axil_awvalid (m_axil_awvalid),
    .s_axil_awready (m_axil_awready),
    .s_axil_wdata   (m_axil_wdata),
    .s_axil_wstrb   (m_axil_wstrb),
    .s_axil_wvalid  (m_axil_wvalid),
    .s_axil_wready  (m_axil_wready),
    .s_axil_bresp   (m_axil_bresp),
    .s_axil_bvalid  (m_axil_bvalid),
    .s_axil_bready  (m_axil_bready),
    .s_axil_araddr  (m_axil_araddr),
    .s_axil_arvalid (m_axil_arvalid),
    .s_axil_arready (m_axil_arready),
    .s_axil_rdata   (m_axil_rdata),
    .s_axil_rresp   (m_axil_rresp),
    .s_axil_rvalid  (m_axil_rvalid),
    .s_axil_rready  (m_axil_rready),
    .link_up         (user_lnk_up),
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
    .user_led       (user_led),
    .irq_req        (usr_irq_req),
    .irq_ack        (usr_irq_ack)
  );

  // ---------------------------------------------------------------------------
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
  // Card memory: DDR3 through the card_mem block design.
  wire ddr_calib_done, ddr_mmcm_locked;
  wire ui_clk, ui_aresetn;   // MIG user clock (100 MHz) and its AXI reset

  // mem_bw's AXI4 master into card_mem (S_AXI_BW)
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

  card_mem card_mem (
    .pcie_aclk    (axi_aclk),
    .pcie_aresetn (axi_aresetn),
    .S_AXI_PCIE_awid    (m_axi_awid),    .S_AXI_PCIE_awaddr  (m_axi_awaddr),  .S_AXI_PCIE_awlen   (m_axi_awlen),
    .S_AXI_PCIE_awsize  (m_axi_awsize),  .S_AXI_PCIE_awburst (m_axi_awburst), .S_AXI_PCIE_awlock  (m_axi_awlock),
    .S_AXI_PCIE_awcache (m_axi_awcache), .S_AXI_PCIE_awprot  (m_axi_awprot),  .S_AXI_PCIE_awqos   (4'd0),
    .S_AXI_PCIE_awvalid (m_axi_awvalid), .S_AXI_PCIE_awready (m_axi_awready),
    .S_AXI_PCIE_wdata   (m_axi_wdata),   .S_AXI_PCIE_wstrb   (m_axi_wstrb),   .S_AXI_PCIE_wlast   (m_axi_wlast),
    .S_AXI_PCIE_wvalid  (m_axi_wvalid),  .S_AXI_PCIE_wready  (m_axi_wready),
    .S_AXI_PCIE_bid     (m_axi_bid),     .S_AXI_PCIE_bresp   (m_axi_bresp),
    .S_AXI_PCIE_bvalid  (m_axi_bvalid),  .S_AXI_PCIE_bready  (m_axi_bready),
    .S_AXI_PCIE_arid    (m_axi_arid),    .S_AXI_PCIE_araddr  (m_axi_araddr),  .S_AXI_PCIE_arlen   (m_axi_arlen),
    .S_AXI_PCIE_arsize  (m_axi_arsize),  .S_AXI_PCIE_arburst (m_axi_arburst), .S_AXI_PCIE_arlock  (m_axi_arlock),
    .S_AXI_PCIE_arcache (m_axi_arcache), .S_AXI_PCIE_arprot  (m_axi_arprot),  .S_AXI_PCIE_arqos   (4'd0),
    .S_AXI_PCIE_arvalid (m_axi_arvalid), .S_AXI_PCIE_arready (m_axi_arready),
    .S_AXI_PCIE_rid     (m_axi_rid),     .S_AXI_PCIE_rdata   (m_axi_rdata),   .S_AXI_PCIE_rresp   (m_axi_rresp),
    .S_AXI_PCIE_rlast   (m_axi_rlast),   .S_AXI_PCIE_rvalid  (m_axi_rvalid),  .S_AXI_PCIE_rready  (m_axi_rready),
    .sys_diff_clock_clk_p (sys_clk_p),
    .sys_diff_clock_clk_n (sys_clk_n),
    .ddr3_sdram_addr    (ddr3_addr),    .ddr3_sdram_ba      (ddr3_ba),
    .ddr3_sdram_cas_n   (ddr3_cas_n),   .ddr3_sdram_ras_n   (ddr3_ras_n),   .ddr3_sdram_we_n (ddr3_we_n),
    .ddr3_sdram_ck_p    (ddr3_ck_p),    .ddr3_sdram_ck_n    (ddr3_ck_n),
    .ddr3_sdram_cke     (ddr3_cke),     .ddr3_sdram_cs_n    (ddr3_cs_n),    .ddr3_sdram_odt  (ddr3_odt),
    .ddr3_sdram_dm      (ddr3_dm),      .ddr3_sdram_dq      (ddr3_dq),
    .ddr3_sdram_dqs_p   (ddr3_dqs_p),   .ddr3_sdram_dqs_n   (ddr3_dqs_n),
    .ddr3_sdram_reset_n (ddr3_reset_n),
    .ui_clk     (ui_clk),
    .ui_aresetn (ui_aresetn),
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
    .dbg_clk         (dbg_clk),
    .ddr_rst         (cpu_reset),
    .ddr_calib_done  (ddr_calib_done),
    .ddr_mmcm_locked (ddr_mmcm_locked)
  );

  // Card-side DDR3 bandwidth engine, controlled from npu_regs (BW_*).
  wire        bw_start, bw_read, bw_busy;
  wire [4:0]  bw_outstanding;
  wire [15:0] bw_seed;
  wire [31:0] bw_addr, bw_len, bw_runs, bw_cycles, bw_mismatches, bw_errors;

  mem_bw bw (
    .ctl_clk (axi_aclk), .ctl_rst_n (axi_aresetn),
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

  // DMA traffic counters for npu_regs.
  wire [31:0] dma_writes, dma_reads, dma_errors;

  axi_dma_mon dma_mon (
    .clk     (axi_aclk),      .rst_n   (axi_aresetn),
    .awvalid (m_axi_awvalid), .awready (m_axi_awready),
    .arvalid (m_axi_arvalid), .arready (m_axi_arready),
    .bvalid  (m_axi_bvalid),  .bready  (m_axi_bready),  .bresp (m_axi_bresp),
    .rvalid  (m_axi_rvalid),  .rready  (m_axi_rready),  .rresp (m_axi_rresp),
    .writes  (dma_writes),    .reads   (dma_reads),     .errors (dma_errors)
  );

  // ---------------------------------------------------------------------------
  // LEDs. bit 26 of a 125 MHz counter toggles about every 0.54 s.
  reg [26:0] heartbeat = 27'd0;
  always @(posedge axi_aclk) heartbeat <= heartbeat + 27'd1;

  assign led = {user_led, heartbeat[26], user_lnk_up};

endmodule

`default_nettype wire
