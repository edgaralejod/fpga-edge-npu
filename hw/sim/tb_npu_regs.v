// Self-checking testbench for npu_regs (AXI4-Lite register block).
//
// Covers: identity reads, scratch write/read with byte strobes, AW-before-W
// and W-before-AW ordering, read-only registers ignoring writes, the coherent
// 64-bit cycle counter, the interrupt request/ack handshake, and unmapped
// reads, back-to-back reads with RREADY held high (as XDMA does), and an AXI
// protocol monitor. Prints "RESULT: PASS" or "RESULT: FAIL".

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
  reg         irq_ack = 1'b0;
  wire [1:0]  user_led;
  wire        irq_req;

  npu_regs #(.BUILD_ID(32'h2611_0315), .CARD_MEM_KIB(16'd64)) dut (
    .clk(clk), .rst_n(rst_n),
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
    .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
    .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
    .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
    .link_up(link_up), .user_led(user_led), .irq_req(irq_req), .irq_ack(irq_ack)
  );

  integer errors = 0;

  task check(input [255:0] what, input [31:0] got, input [31:0] want);
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
    axil_read(32'h004, v); check("VERSION", v, 32'h0000_0101);
    axil_read(32'h008, v); check("BUILD",   v, 32'h2611_0315);
    axil_read(32'h00C, v); check("CAPS",    v, 32'h0040_0001);
    axil_read(32'h018, v); check("STATUS",  v, 32'h0000_0001);

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

    // Back-to-back reads with RREADY held high between them, as XDMA does.
    rready_idle = 1'b1; rready <= 1'b1;
    axil_read(32'h000, v); check("RREADY idle high: ID",      v, 32'h4E50_5530);
    axil_read(32'h004, v); check("RREADY idle high: VERSION", v, 32'h0000_0101);
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
