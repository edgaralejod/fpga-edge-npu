// Self-checking testbench for npu_regs (AXI4-Lite register block).
//
// Covers: identity reads, scratch write/read with byte strobes, AW-before-W
// and W-before-AW ordering, read-only registers ignoring writes, the coherent
// 64-bit cycle counter, the interrupt request/ack handshake, and unmapped
// reads, the DDR status and DMA counter inputs, the mem_bw controls (start
// pulse, settings held while busy), back-to-back reads with RREADY
// held high (as XDMA does), and an AXI protocol monitor. Prints "RESULT: PASS" or "RESULT: FAIL".

`timescale 1ns / 1ps
`default_nettype none

module tb_npu_regs;

  reg clk = 1'b0;
  reg rst_n = 1'b0;
  always #4 clk = ~clk; // 125 MHz

  reg  [31:0] awaddr = 0, wdata = 0, araddr = 0;
  reg  [3:0]  wstrb = 0;
  reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
  wire        awready, wready, bvalid, arready, rvalid;
  wire [1:0]  bresp, rresp;
  wire [31:0] rdata;
  reg         link_up = 1'b1;
  reg         ddr_calib_done = 1'b0, ddr_mmcm_locked = 1'b1;
  reg  [31:0] dma_writes = 32'h0000_1234, dma_reads = 32'h0000_5678, dma_errors = 32'd0;
  wire        bw_start, bw_read;
  wire [4:0]  bw_outstanding;
  wire [15:0] bw_seed;
  wire [31:0] bw_addr, bw_len;
  reg         bw_busy = 1'b0;
  reg  [31:0] bw_runs = 32'd3, bw_cycles = 32'd1000, bw_mismatches = 32'd0, bw_errors = 32'd0;
  integer     bw_starts = 0;
  always @(posedge clk) if (bw_start) bw_starts = bw_starts + 1;
  wire [31:0] cycles_lo;
  wire        cq_enable, cq_irq_en, cq_sq_tail_wr, cq_cq_head_wr;
  wire [3:0]  cq_log2;
  wire [63:0] cq_sq_base, cq_cq_base;
  wire [11:0] cq_doorbell;
  reg         cq_busy = 0, cq_stalled = 1, cq_axi_err = 0, cq_cfg_err = 1;
  reg  [31:0] cq_completed = 32'd42;
  integer     sq_rings = 0, cq_rings = 0; reg [11:0] last_bell;
  always @(posedge clk) begin
    if (cq_sq_tail_wr) begin sq_rings = sq_rings + 1; last_bell = cq_doorbell; end
    if (cq_cq_head_wr) begin cq_rings = cq_rings + 1; last_bell = cq_doorbell; end
  end
  reg         irq_ack = 1'b0;
  wire [1:0]  user_led;
  wire        irq_req;

  npu_regs #(.BUILD_ID(32'h2611_0315), .CARD_MEM_MIB(16'd1024)) dut (
    .clk(clk), .rst_n(rst_n),
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
    .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
    .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
    .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
    .link_up(link_up), .ddr_calib_done(ddr_calib_done), .ddr_mmcm_locked(ddr_mmcm_locked),
    .dma_writes(dma_writes), .dma_reads(dma_reads), .dma_errors(dma_errors),
    .bw_start(bw_start), .bw_read(bw_read), .bw_outstanding(bw_outstanding), .bw_seed(bw_seed),
    .bw_addr(bw_addr), .bw_len(bw_len), .bw_busy(bw_busy), .bw_runs(bw_runs),
    .bw_cycles(bw_cycles), .bw_mismatches(bw_mismatches), .bw_errors(bw_errors),
    .cycles_lo(cycles_lo), .cq_enable(cq_enable), .cq_irq_en(cq_irq_en), .cq_log2(cq_log2),
    .cq_sq_base(cq_sq_base), .cq_cq_base(cq_cq_base), .cq_sq_tail_wr(cq_sq_tail_wr), .cq_cq_head_wr(cq_cq_head_wr),
    .cq_doorbell(cq_doorbell), .cq_busy(cq_busy), .cq_stalled(cq_stalled), .cq_axi_err(cq_axi_err),
    .cq_cfg_err(cq_cfg_err), .cq_completed(cq_completed),
    .user_led(user_led), .irq_req(irq_req), .irq_ack(irq_ack)
  );

  integer errors = 0;

  task check(input [511:0] what, input [31:0] got, input [31:0] want);
    begin
      if (got !== want) begin
        $display("FAIL  %0s: got 0x%08h, want 0x%08h", what, got, want);
        errors = errors + 1;
      end else begin
        $display("ok    %0s = 0x%08h", what, got);
      end
    end
  endtask

  // AXI-Lite master tasks. Signals change on clock edges; a handshake is
  // seen at an edge where VALID and READY were both high just before it.
  // order: 0 = AW and W together, 1 = AW first, 2 = W first
  task axil_write(input [31:0] addr, input [31:0] data, input [3:0] strb, input integer order);
    integer n;
    begin
      @(posedge clk);
      fork
        begin
          if (order == 2) repeat (3) @(posedge clk);
          awaddr <= addr; awvalid <= 1'b1;
          @(posedge clk);
          while (!awready) @(posedge clk);
          awvalid <= 1'b0;
        end
        begin
          if (order == 1) repeat (3) @(posedge clk);
          wdata <= data; wstrb <= strb; wvalid <= 1'b1;
          @(posedge clk);
          while (!wready) @(posedge clk);
          wvalid <= 1'b0;
        end
      join
      bready <= 1'b1;
      n = 0;
      @(posedge clk);
      while (!bvalid && n < 50) begin @(posedge clk); n = n + 1; end
      if (n == 50) begin $display("FAIL  write 0x%03h: no response", addr); errors = errors + 1; end
      else if (bresp !== 2'b00) begin $display("FAIL  write 0x%03h: bresp %b", addr, bresp); errors = errors + 1; end
      bready <= 1'b0;
      @(posedge clk);
    end
  endtask

  // rready_idle: leave RREADY high between reads, as XDMA does. A response
  // the slave raises during the address handshake is then lost to the master;
  // the protocol monitor below reports it.
  reg rready_idle = 1'b0;

  task axil_read(input [31:0] addr, output [31:0] data);
    integer n;
    begin
      @(posedge clk);
      araddr <= addr; arvalid <= 1'b1;
      @(posedge clk);
      while (!arready) @(posedge clk);
      arvalid <= 1'b0;
      rready  <= 1'b1;
      n = 0;
      @(posedge clk);
      while (!rvalid && n < 50) begin @(posedge clk); n = n + 1; end
      if (n == 50) begin $display("FAIL  read 0x%03h: no response", addr); errors = errors + 1; end
      data = rdata;
      rready <= rready_idle;
    end
  endtask

  // AXI protocol monitor: a response may only appear after its address (and,
  // for writes, its data) was accepted in an earlier cycle.
  integer ar_open = 0, aw_open = 0, w_open = 0;
  always @(posedge clk) begin
    if (rst_n) begin
      if (rvalid && ar_open == 0) begin
        $display("FAIL  protocol: RVALID before its read address was accepted"); errors = errors + 1;
      end
      if (bvalid && (aw_open == 0 || w_open == 0)) begin
        $display("FAIL  protocol: BVALID before its write address and data were accepted"); errors = errors + 1;
      end
      ar_open = ar_open + (arvalid && arready) - (rvalid && rready);
      aw_open = aw_open + (awvalid && awready) - (bvalid && bready);
      w_open  = w_open  + (wvalid && wready)   - (bvalid && bready);
    end
  end

  reg [31:0] v, lo1, hi1, lo2, hi2;
  reg [63:0] c1, c2;

  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);

    axil_read(32'h000, v); check("ID",      v, 32'h4E50_5530);
    axil_read(32'h004, v); check("VERSION", v, 32'h0000_0500);
    axil_read(32'h008, v); check("BUILD",   v, 32'h2611_0315);
    axil_read(32'h00C, v); check("CAPS",    v, 32'h0400_000F);
    axil_read(32'h018, v); check("STATUS, DDR not calibrated", v, 32'h0000_0005);
    ddr_calib_done = 1'b1;
    repeat (3) @(posedge clk);
    axil_read(32'h018, v); check("STATUS, DDR calibrated", v, 32'h0000_0007);
    axil_read(32'h030, v); check("DMA_WRITES", v, 32'h0000_1234);
    axil_read(32'h034, v); check("DMA_READS",  v, 32'h0000_5678);
    dma_errors = 32'd2;
    axil_read(32'h038, v); check("DMA_ERRORS", v, 32'h0000_0002);

    axil_write(32'h010, 32'hA5A5_1234, 4'hF, 0);
    axil_read(32'h010, v); check("SCRATCH full write", v, 32'hA5A5_1234);
    axil_write(32'h010, 32'h0000_CC00, 4'b0010, 1);
    axil_read(32'h010, v); check("SCRATCH byte 1, AW first", v, 32'hA5A5_CC34);
    axil_write(32'h010, 32'h7700_0000, 4'b1000, 2);
    axil_read(32'h010, v); check("SCRATCH byte 3, W first", v, 32'h77A5_CC34);

    axil_write(32'h000, 32'hFFFF_FFFF, 4'hF, 0);
    axil_read(32'h000, v); check("ID ignores writes", v, 32'h4E50_5530);

    axil_write(32'h014, 32'h0000_0002, 4'hF, 0);
    axil_read(32'h014, v); check("CONTROL", v, 32'h0000_0002);
    check("user_led follows CONTROL", {30'd0, user_led}, 32'h0000_0002);

    axil_read(32'h020, lo1); axil_read(32'h024, hi1);
    repeat (20) @(posedge clk);
    axil_read(32'h020, lo2); axil_read(32'h024, hi2);
    c1 = {hi1, lo1}; c2 = {hi2, lo2};
    if (c2 <= c1 || (c2 - c1) < 20) begin
      $display("FAIL  CYCLE counter: %0d then %0d", c1, c2); errors = errors + 1;
    end else $display("ok    CYCLE counter advanced %0d cycles", c2 - c1);

    axil_write(32'h028, 32'h0000_0001, 4'hF, 0);
    check("irq_req raised", {31'd0, irq_req}, 32'd1);
    @(posedge clk); irq_ack <= 1'b1; @(posedge clk); irq_ack <= 1'b0;
    axil_read(32'h028, v); check("IRQ level + acked", v, 32'h0000_0003);
    axil_write(32'h028, 32'h0000_0002, 4'hF, 0);
    axil_read(32'h028, v); check("IRQ cleared", v, 32'h0000_0000);
    check("irq_req dropped", {31'd0, irq_req}, 32'd0);

    axil_read(32'h7F0, v); check("unmapped read", v, 32'hDEAD_BEEF);

    // mem_bw controls
    axil_write(32'h044, 32'h0010_0000, 4'hF, 0);
    axil_write(32'h048, 32'h0040_0000, 4'hF, 0);
    axil_write(32'h040, 32'hBEEF_1003, 4'hF, 0);     // seed BEEF, 16 in flight, read, START
    check("BW start pulses", bw_starts, 1);
    check("BW_CTRL fields out", {bw_seed, 3'd0, bw_outstanding, 6'd0, bw_read, 1'b0}, 32'hBEEF_1002);
    axil_read(32'h040, v); check("BW_CTRL reads back (START reads as busy)", v, 32'hBEEF_1002);
    axil_read(32'h044, v); check("BW_ADDR", v, 32'h0010_0000);
    axil_read(32'h048, v); check("BW_LEN",  v, 32'h0040_0000);
    bw_busy = 1'b1;
    axil_write(32'h044, 32'h0000_0000, 4'hF, 0);
    axil_write(32'h040, 32'h0000_0001, 4'hF, 0);
    axil_read(32'h044, v); check("BW_ADDR ignores writes while busy", v, 32'h0010_0000);
    check("BW start ignored while busy", bw_starts, 1);
    axil_read(32'h040, v); check("BW_CTRL busy bit", v, 32'hBEEF_1003);
    bw_busy = 1'b0;
    axil_read(32'h04C, v); check("BW_RUNS", v, 32'd3);
    axil_read(32'h050, v); check("BW_CYCLES", v, 32'd1000);
    axil_read(32'h05C, v); check("BW_CLK_KHZ", v, 32'd100000);

    // Command queue registers and doorbells
    axil_write(32'h084, 32'd6, 4'hF, 0);
    axil_write(32'h088, 32'h0012_3000, 4'hF, 0);
    axil_write(32'h090, 32'h0045_6000, 4'hF, 0);
    axil_write(32'h080, 32'h0000_0003, 4'hF, 0);                 // enable, interrupts
    check("CQ enable and irq out", {30'd0, cq_irq_en, cq_enable}, 3);
    check("CQ log2 out", {28'd0, cq_log2}, 6);
    check("SQ base out", cq_sq_base[31:0], 32'h0012_3000);
    axil_write(32'h088, 32'h0000_0000, 4'hF, 0);                 // ignored while enabled
    axil_read(32'h088, v); check("SQ base ignores writes while enabled", v, 32'h0012_3000);
    axil_write(32'h098, 32'd5, 4'hF, 0);
    check("SQ tail doorbell pulses once", sq_rings, 1);
    check("doorbell value", {20'd0, last_bell}, 5);
    axil_write(32'h09C, 32'd4, 4'hF, 0);
    check("CQ head doorbell pulses once", cq_rings, 1);
    axil_read(32'h0A0, v); check("CQ_STATUS (cfg_err, stalled)", v, 32'h0000_000A);
    axil_read(32'h0A4, v); check("CQ_COMPLETED", v, 32'd42);

    // Back-to-back reads with RREADY held high between them, as XDMA does.
    rready_idle = 1'b1; rready <= 1'b1;
    axil_read(32'h000, v); check("RREADY idle high: ID",      v, 32'h4E50_5530);
    axil_read(32'h004, v); check("RREADY idle high: VERSION", v, 32'h0000_0500);
    axil_read(32'h000, v); check("RREADY idle high: ID again", v, 32'h4E50_5530);
    rready_idle = 1'b0; rready <= 1'b0;

    if (errors == 0) $display("RESULT: PASS");
    else             $display("RESULT: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #200000;
    $display("RESULT: FAIL (timeout)");
    $finish;
  end

endmodule

`default_nettype wire
