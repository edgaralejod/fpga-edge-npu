// npu_top: AC701 top level for the PCIe-attached NPU.
//
//   PCIe Gen2 x1 (edge connector) -> XDMA
//     BAR0  AXI-Lite master -> npu_regs        (control and status)
//     BAR1  XDMA DMA engine -> AXI4 master -> card memory (64 KiB BRAM)
//
// Phase 1 of the roadmap: the host can enumerate the card, read and write
// registers, raise an MSI, and DMA buffers to and from card memory. The
// inference engine attaches here in later phases.
//
// LEDs (GPIO_LED_0..3): 0 = link up, 1 = PCIe user-clock heartbeat (~1 Hz),
// 2..3 = software controlled through npu_regs CONTROL.

`timescale 1ns / 1ps
`default_nettype none

module npu_top #(
  parameter [31:0] BUILD_ID = 32'h0000_0000
) (
  input  wire       pcie_refclk_p,
  input  wire       pcie_refclk_n,
  input  wire       pcie_perst_n,
  output wire [0:0] pcie_txp,
  output wire [0:0] pcie_txn,
  input  wire [0:0] pcie_rxp,
  input  wire [0:0] pcie_rxn,
  output wire [3:0] led
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
    .CARD_MEM_KIB (16'd64)
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
    .link_up        (user_lnk_up),
    .user_led       (user_led),
    .irq_req        (usr_irq_req),
    .irq_ack        (usr_irq_ack)
  );

  // ---------------------------------------------------------------------------
  // Card memory: 64 KiB BRAM on the DMA path. Only the low 16 address bits are
  // decoded, so the 64 KiB window repeats across the AXI address space.
  wire        bram_rst, bram_clk, bram_en;
  wire [7:0]  bram_we;
  wire [15:0] bram_addr;
  wire [63:0] bram_wrdata, bram_rddata;

  axi_bram_ctrl_0 card_mem_ctrl (
    .s_axi_aclk    (axi_aclk),
    .s_axi_aresetn (axi_aresetn),
    .s_axi_awid    (m_axi_awid),    .s_axi_awaddr (m_axi_awaddr[15:0]), .s_axi_awlen  (m_axi_awlen),
    .s_axi_awsize  (m_axi_awsize),  .s_axi_awburst(m_axi_awburst),      .s_axi_awlock (m_axi_awlock),
    .s_axi_awcache (m_axi_awcache), .s_axi_awprot (m_axi_awprot),
    .s_axi_awvalid (m_axi_awvalid), .s_axi_awready(m_axi_awready),
    .s_axi_wdata   (m_axi_wdata),   .s_axi_wstrb  (m_axi_wstrb),        .s_axi_wlast  (m_axi_wlast),
    .s_axi_wvalid  (m_axi_wvalid),  .s_axi_wready (m_axi_wready),
    .s_axi_bid     (m_axi_bid),     .s_axi_bresp  (m_axi_bresp),
    .s_axi_bvalid  (m_axi_bvalid),  .s_axi_bready (m_axi_bready),
    .s_axi_arid    (m_axi_arid),    .s_axi_araddr (m_axi_araddr[15:0]), .s_axi_arlen  (m_axi_arlen),
    .s_axi_arsize  (m_axi_arsize),  .s_axi_arburst(m_axi_arburst),      .s_axi_arlock (m_axi_arlock),
    .s_axi_arcache (m_axi_arcache), .s_axi_arprot (m_axi_arprot),
    .s_axi_arvalid (m_axi_arvalid), .s_axi_arready(m_axi_arready),
    .s_axi_rid     (m_axi_rid),     .s_axi_rdata  (m_axi_rdata),        .s_axi_rresp  (m_axi_rresp),
    .s_axi_rlast   (m_axi_rlast),   .s_axi_rvalid (m_axi_rvalid),       .s_axi_rready (m_axi_rready),
    .bram_rst_a    (bram_rst),
    .bram_clk_a    (bram_clk),
    .bram_en_a     (bram_en),
    .bram_we_a     (bram_we),
    .bram_addr_a   (bram_addr),
    .bram_wrdata_a (bram_wrdata),
    .bram_rddata_a (bram_rddata)
  );

  dma_bram_0 card_mem (
    .clka      (bram_clk),
    .rsta      (bram_rst),
    .ena       (bram_en),
    .wea       (bram_we),
    .addra     ({16'd0, bram_addr}),
    .dina      (bram_wrdata),
    .douta     (bram_rddata),
    .rsta_busy ()
  );

  // ---------------------------------------------------------------------------
  // LEDs. bit 26 of a 125 MHz counter toggles about every 0.54 s.
  reg [26:0] heartbeat = 27'd0;
  always @(posedge axi_aclk) heartbeat <= heartbeat + 27'd1;

  assign led = {user_led, heartbeat[26], user_lnk_up};

endmodule

`default_nettype wire
