// axi_mem_model: AXI4 slave memory for testbenches (simulation only).
//
// 64-bit data, INCR bursts. Memory of 2^WORDS_LOG2 64-bit words starting at
// BASE; addresses outside it get DECERR. Random stalls on every channel when
// `stall` is set, a fixed read latency, write data accepted before its
// address (as AXI allows), and SLVERR on every response while `err` is set.
// With `aw_waits_w` it also waits for write data before taking the address,
// which deadlocks a master that holds WVALID until AWREADY.
//
// It also checks the master: VALID and its payload held until READY, bursts
// that cross a 4 KiB boundary. Each violation increments `violations`.

`timescale 1ns / 1ps
`default_nettype none

module axi_mem_model #(
  parameter [31:0] BASE = 32'h0,
  parameter integer WORDS_LOG2 = 14,       // 128 KiB
  parameter integer READ_LATENCY = 12,
  parameter integer SEED = 1
) (
  input  wire        clk,
  input  wire        stall,
  input  wire        err,
  input  wire        aw_waits_w,     // raise AWREADY only while WVALID is high, as AXI allows
  input  wire [31:0] awaddr, input wire [7:0] awlen, input wire [2:0] awsize, input wire [1:0] awburst,
  input  wire        awvalid, output reg awready,
  input  wire [63:0] wdata, input wire [7:0] wstrb, input wire wlast, input wire wvalid, output reg wready,
  output reg  [1:0]  bresp, output reg bvalid, input wire bready,
  input  wire [31:0] araddr, input wire [7:0] arlen, input wire [2:0] arsize, input wire [1:0] arburst,
  input  wire        arvalid, output reg arready,
  output reg  [63:0] rdata, output reg [1:0] rresp, output reg rlast, output reg rvalid, input wire rready
);

  localparam integer WORDS = 1 << WORDS_LOG2;
  reg [63:0] mem [0:WORDS-1];

  integer seed = SEED;
  integer cyc = 0;
  integer violations = 0;
  integer writes = 0, reads = 0;

  function chance(input integer pct);
    chance = !stall || (($random(seed) & 32'h7fffffff) % 100) < pct;
  endfunction

  function in_range(input [31:0] a, input [7:0] len);
    in_range = (a >= BASE) && ({1'b0, a} + ({1'b0, 24'd0, len} + 33'd1) * 8 <= {1'b0, BASE} + WORDS * 8);
  endfunction

  // Queues
  reg [31:0] aw_a [0:63]; reg [7:0] aw_l [0:63];
  reg [31:0] ar_a [0:63]; reg [7:0] ar_l [0:63]; integer ar_t [0:63];
  reg [63:0] w_d [0:1023]; reg [7:0] w_s [0:1023]; reg w_last [0:1023];
  integer aw_wr = 0, aw_rd = 0, ar_wr = 0, ar_rd = 0, w_wr = 0, w_rd = 0, b_pend = 0;
  reg [1:0] b_q [0:63]; integer b_wr = 0, b_rd = 0;
  integer rbeat = 0;
  integer i, k, n, idx;
  reg ok;

  // Master-side protocol checks
  reg aw_hold = 0, ar_hold = 0, w_hold = 0;
  reg [31:0] aw_prev, ar_prev; reg [63:0] w_prev;
  always @(posedge clk) begin
    if (aw_hold && (!awvalid || awaddr !== aw_prev)) begin violations = violations + 1; $display("VIOLATION %m: AWVALID/AWADDR changed before AWREADY"); end
    if (ar_hold && (!arvalid || araddr !== ar_prev)) begin violations = violations + 1; $display("VIOLATION %m: ARVALID/ARADDR changed before ARREADY"); end
    if (w_hold && (!wvalid || wdata !== w_prev)) begin violations = violations + 1; $display("VIOLATION %m: WVALID/WDATA changed before WREADY"); end
    aw_hold <= awvalid && !awready; aw_prev <= awaddr;
    ar_hold <= arvalid && !arready; ar_prev <= araddr;
    w_hold  <= wvalid && !wready;   w_prev  <= wdata;
    if (awvalid && ((awaddr & 32'hFFF) + ({24'd0, awlen} + 1) * 8 > 4096)) begin violations = violations + 1; $display("VIOLATION %m: write burst crosses 4 KiB at %h", awaddr); end
    if (arvalid && ((araddr & 32'hFFF) + ({24'd0, arlen} + 1) * 8 > 4096)) begin violations = violations + 1; $display("VIOLATION %m: read burst crosses 4 KiB at %h", araddr); end
    if ((awvalid && (awsize != 3'd3 || awburst != 2'b01)) || (arvalid && (arsize != 3'd3 || arburst != 2'b01))) begin
      violations = violations + 1; $display("VIOLATION %m: not 64-bit INCR");
    end
  end

  initial begin awready = 0; wready = 0; bvalid = 0; bresp = 0; arready = 0; rvalid = 0; rlast = 0; rresp = 0; rdata = 0; end

  always @(posedge clk) begin
    cyc = cyc + 1;
    // AW and W are independent; data may arrive first.
    if (awvalid && awready) begin aw_a[aw_wr % 64] = awaddr; aw_l[aw_wr % 64] = awlen; aw_wr = aw_wr + 1; end
    if (wvalid && wready) begin w_d[w_wr % 1024] = wdata; w_s[w_wr % 1024] = wstrb; w_last[w_wr % 1024] = wlast; w_wr = w_wr + 1; end
    awready <= (aw_wr - aw_rd < 32) && chance(60) && (!aw_waits_w || wvalid);
    wready  <= (w_wr - w_rd < 900) && chance(70);

    // Commit a write burst when its address and all its beats are in.
    if (aw_wr != aw_rd && (w_wr - w_rd) > aw_l[aw_rd % 64]) begin
      n = aw_l[aw_rd % 64] + 1;
      ok = in_range(aw_a[aw_rd % 64], aw_l[aw_rd % 64]);
      for (k = 0; k < n; k = k + 1) begin
        idx = ((aw_a[aw_rd % 64] - BASE) >> 3) + k;
        if (ok) for (i = 0; i < 8; i = i + 1) if (w_s[(w_rd + k) % 1024][i]) mem[idx % WORDS][i*8 +: 8] = w_d[(w_rd + k) % 1024][i*8 +: 8];
        if ((k == n - 1) != w_last[(w_rd + k) % 1024]) begin violations = violations + 1; $display("VIOLATION %m: WLAST on beat %0d of %0d", k, n); end
      end
      w_rd = w_rd + n; aw_rd = aw_rd + 1; writes = writes + 1;
      b_q[b_wr % 64] = err ? 2'b10 : (ok ? 2'b00 : 2'b11); b_wr = b_wr + 1;
    end
    if (bvalid && bready) bvalid <= 1'b0;
    else if (!bvalid && b_wr != b_rd && chance(50)) begin bvalid <= 1'b1; bresp <= b_q[b_rd % 64]; b_rd = b_rd + 1; end

    // Reads: in order, beats back to back once the latency has passed.
    if (arvalid && arready) begin ar_a[ar_wr % 64] = araddr; ar_l[ar_wr % 64] = arlen; ar_t[ar_wr % 64] = cyc; ar_wr = ar_wr + 1; end
    arready <= (ar_wr - ar_rd < 32) && chance(60);
    if (!rvalid || rready) begin
      if (rvalid) begin
        if (rlast) begin ar_rd = ar_rd + 1; rbeat = 0; reads = reads + 1; end
        else rbeat = rbeat + 1;
      end
      if (ar_wr != ar_rd && cyc >= ar_t[ar_rd % 64] + READ_LATENCY && chance(75)) begin
        ok = in_range(ar_a[ar_rd % 64], ar_l[ar_rd % 64]);
        idx = ((ar_a[ar_rd % 64] - BASE) >> 3) + rbeat;
        rvalid <= 1'b1;
        rdata  <= ok ? mem[idx % WORDS] : 64'hDEAD_DEAD_DEAD_DEAD;
        rresp  <= err ? 2'b10 : (ok ? 2'b00 : 2'b11);
        rlast  <= (rbeat == ar_l[ar_rd % 64]);
      end else rvalid <= 1'b0;
    end
  end

endmodule

`default_nettype wire
