// Self-checking testbench for npu_cq (command queue engine).
//
// The testbench plays the host the way the fpga-npu driver will: it writes
// 64-byte commands into a submission ring in host memory, rings the SQ tail
// doorbell, polls the completion ring by phase bit, checks each completion,
// and releases CQ slots with the CQ head doorbell. Host memory (behind the
// PCIe bridge window at 0x8000_0000) and card memory are axi_mem_model
// slaves with random stalls and read latency, which also check the engine's
// AXI handshakes and 4 KiB rule.
//
// Covers: NOPs completed exactly once and in order across ring wraps (phase
// bits), a full completion ring stalling the engine, COPY_H2C and COPY_C2H
// round trips (multi-burst and a short last burst) checked byte for byte,
// invalid opcode and bad length or alignment, AXI errors, MSI requests,
// timestamps, slaves that wait for write data before the address, and GEMM
// (INT8 with and without ReLU, INT32) against an independent reference. Prints "RESULT: PASS" or "RESULT: FAIL".

`timescale 1ns / 1ps
`default_nettype none

module tb_npu_cq;

  reg clk = 1'b0, rst_n = 1'b0;
  always #4 clk = ~clk;   // 125 MHz
  reg [31:0] cycles = 0;
  always @(posedge clk) cycles <= cycles + 1;

  // Configuration and doorbells
  reg         cfg_enable = 0, cfg_irq_en = 1;
  reg  [3:0]  cfg_log2 = 4'd3;           // 8-entry rings
  reg  [63:0] cfg_sq_base = 64'h0000, cfg_cq_base = 64'h1000;
  reg         sq_tail_wr = 0, cq_head_wr = 0;
  reg  [11:0] sq_tail_val = 0, cq_head_val = 0;
  wire        busy, stalled, axi_err, cfg_err;
  wire [31:0] completed;
  reg         msi_enable = 1, msi_grant = 0;
  wire        msi_request;
  reg         host_stall = 1, card_stall = 1, host_err = 0, card_err = 0, waits_w = 0;

  wire [31:0] h_awaddr, h_araddr, c_awaddr, c_araddr;
  wire [7:0]  h_awlen, h_arlen, c_awlen, c_arlen, h_wstrb, c_wstrb;
  wire [2:0]  h_awsize, h_arsize, c_awsize, c_arsize;
  wire [1:0]  h_awburst, h_arburst, c_awburst, c_arburst, h_bresp, h_rresp, c_bresp, c_rresp;
  wire [63:0] h_wdata, h_rdata, c_wdata, c_rdata;
  wire        h_awvalid, h_awready, h_wlast, h_wvalid, h_wready, h_bvalid, h_bready;
  wire        h_arvalid, h_arready, h_rlast, h_rvalid, h_rready;
  wire        c_awvalid, c_awready, c_wlast, c_wvalid, c_wready, c_bvalid, c_bready;
  wire        c_arvalid, c_arready, c_rlast, c_rvalid, c_rready;

  npu_cq dut (
    .clk(clk), .rst_n(rst_n),
    .cfg_enable(cfg_enable), .cfg_irq_en(cfg_irq_en), .cfg_log2(cfg_log2),
    .cfg_sq_base(cfg_sq_base), .cfg_cq_base(cfg_cq_base),
    .sq_tail_wr(sq_tail_wr), .sq_tail_val(sq_tail_val), .cq_head_wr(cq_head_wr), .cq_head_val(cq_head_val),
    .cycles(cycles), .busy(busy), .stalled(stalled), .axi_err(axi_err), .cfg_err(cfg_err), .completed(completed),
    .msi_enable(msi_enable), .msi_request(msi_request), .msi_grant(msi_grant), .irq_test(1'b0),
    .h_awaddr(h_awaddr), .h_awlen(h_awlen), .h_awsize(h_awsize), .h_awburst(h_awburst), .h_awvalid(h_awvalid), .h_awready(h_awready),
    .h_wdata(h_wdata), .h_wstrb(h_wstrb), .h_wlast(h_wlast), .h_wvalid(h_wvalid), .h_wready(h_wready),
    .h_bresp(h_bresp), .h_bvalid(h_bvalid), .h_bready(h_bready),
    .h_araddr(h_araddr), .h_arlen(h_arlen), .h_arsize(h_arsize), .h_arburst(h_arburst), .h_arvalid(h_arvalid), .h_arready(h_arready),
    .h_rdata(h_rdata), .h_rresp(h_rresp), .h_rlast(h_rlast), .h_rvalid(h_rvalid), .h_rready(h_rready),
    .c_awaddr(c_awaddr), .c_awlen(c_awlen), .c_awsize(c_awsize), .c_awburst(c_awburst), .c_awvalid(c_awvalid), .c_awready(c_awready),
    .c_wdata(c_wdata), .c_wstrb(c_wstrb), .c_wlast(c_wlast), .c_wvalid(c_wvalid), .c_wready(c_wready),
    .c_bresp(c_bresp), .c_bvalid(c_bvalid), .c_bready(c_bready),
    .c_araddr(c_araddr), .c_arlen(c_arlen), .c_arsize(c_arsize), .c_arburst(c_arburst), .c_arvalid(c_arvalid), .c_arready(c_arready),
    .c_rdata(c_rdata), .c_rresp(c_rresp), .c_rlast(c_rlast), .c_rvalid(c_rvalid), .c_rready(c_rready)
  );

  // Host memory: 128 KiB of bus addresses 0x0..0x1FFFF, at AXI 0x8000_0000.
  axi_mem_model #(.BASE(32'h8000_0000), .WORDS_LOG2(14), .READ_LATENCY(40), .SEED(11)) host (
    .clk(clk), .stall(host_stall), .err(host_err), .aw_waits_w(waits_w),
    .awaddr(h_awaddr), .awlen(h_awlen), .awsize(h_awsize), .awburst(h_awburst), .awvalid(h_awvalid), .awready(h_awready),
    .wdata(h_wdata), .wstrb(h_wstrb), .wlast(h_wlast), .wvalid(h_wvalid), .wready(h_wready),
    .bresp(h_bresp), .bvalid(h_bvalid), .bready(h_bready),
    .araddr(h_araddr), .arlen(h_arlen), .arsize(h_arsize), .arburst(h_arburst), .arvalid(h_arvalid), .arready(h_arready),
    .rdata(h_rdata), .rresp(h_rresp), .rlast(h_rlast), .rvalid(h_rvalid), .rready(h_rready));

  // Card memory: 128 KiB at AXI 0x0.
  axi_mem_model #(.BASE(32'h0), .WORDS_LOG2(19), .READ_LATENCY(12), .SEED(23)) card (
    .clk(clk), .stall(card_stall), .err(card_err), .aw_waits_w(waits_w),
    .awaddr(c_awaddr), .awlen(c_awlen), .awsize(c_awsize), .awburst(c_awburst), .awvalid(c_awvalid), .awready(c_awready),
    .wdata(c_wdata), .wstrb(c_wstrb), .wlast(c_wlast), .wvalid(c_wvalid), .wready(c_wready),
    .bresp(c_bresp), .bvalid(c_bvalid), .bready(c_bready),
    .araddr(c_araddr), .arlen(c_arlen), .arsize(c_arsize), .arburst(c_arburst), .arvalid(c_arvalid), .arready(c_arready),
    .rdata(c_rdata), .rresp(c_rresp), .rlast(c_rlast), .rvalid(c_rvalid), .rready(c_rready));

  // The bridge grants each MSI request a few cycles later.
  integer msi_count = 0;
  always @(posedge clk) begin
    msi_grant <= 1'b0;
    if (msi_request) begin
      msi_count = msi_count + 1;
      repeat (5) @(posedge clk);
      msi_grant <= 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Host side, as the driver will do it
  integer errors = 0;
  integer sq_tail = 0, cq_head = 0, exp_phase = 1, entries = 8;
  reg [63:0] w0, w1;

  task fail(input [511:0] what); begin $display("FAIL  %0s", what); errors = errors + 1; end endtask
  task check(input [1023:0] what, input [31:0] got, input [31:0] want);
    begin
      if (got !== want) begin $display("FAIL  %0s: got %0d (0x%0h), want %0d", what, got, got, want); errors = errors + 1; end
      else $display("ok    %0s = %0d", what, got);
    end
  endtask

  task submit(input [7:0] op, input [7:0] fl, input [15:0] cid, input [31:0] len, input [63:0] ha, input [63:0] ca);
    integer base, i;
    begin
      base = (cfg_sq_base + sq_tail * 64) >> 3;
      host.mem[base + 0] = {len, cid, fl, op};
      host.mem[base + 1] = ha;
      host.mem[base + 2] = ca;
      for (i = 3; i < 8; i = i + 1) host.mem[base + i] = 64'd0;
      sq_tail = (sq_tail + 1) % entries;
    end
  endtask

  // The completion record lands in host memory before its write response
  // returns, and `completed` counts responses, so wait for idle to compare it.
  task settle; integer n; begin n = 0; @(posedge clk); while (busy && n < 100000) begin @(posedge clk); n = n + 1; end end endtask

  task ring_sq; begin @(posedge clk); sq_tail_val <= sq_tail; sq_tail_wr <= 1; @(posedge clk); sq_tail_wr <= 0; end endtask
  task ring_cq; begin @(posedge clk); cq_head_val <= cq_head; cq_head_wr <= 1; @(posedge clk); cq_head_wr <= 0; end endtask

  // Waits for the next completion, checks it and consumes it.
  task expect_cpl(input [15:0] cid, input [7:0] status, input free_slot);
    integer base, n;
    begin
      base = (cfg_cq_base + cq_head * 16) >> 3;
      n = 0;
      while (host.mem[base][40] !== exp_phase[0] && n < 400000) begin @(posedge clk); n = n + 1; end
      w0 = host.mem[base]; w1 = host.mem[base + 1];
      if (n >= 400000) fail("completion did not arrive");
      else begin
        if (w0[15:0] !== cid) begin $display("FAIL  completion cid %0d, want %0d", w0[15:0], cid); errors = errors + 1; end
        if (w0[39:32] !== status) begin $display("FAIL  cid %0d status %0d, want %0d", cid, w0[39:32], status); errors = errors + 1; end
        if (w1[63:32] < w1[31:0]) begin $display("FAIL  cid %0d t_done before t_fetch", cid); errors = errors + 1; end
        if (w0[63:48] !== 16'd0 || w0[47:41] !== 7'd0) begin $display("FAIL  cid %0d reserved bits set", cid); errors = errors + 1; end
      end
      cq_head = (cq_head + 1) % entries;
      if (cq_head == 0) exp_phase = 1 - exp_phase;
      if (free_slot) ring_cq;
    end
  endtask

  task fill_host(input integer bus, input integer bytes, input integer seed);
    integer i; begin for (i = 0; i < bytes / 8; i = i + 1) host.mem[(bus >> 3) + i] = {seed[15:0], i[15:0], ~i[15:0], seed[15:0] ^ 16'hA5A5}; end
  endtask
  function integer same_host(input integer a, input integer b, input integer bytes);
    integer i; begin same_host = 1; for (i = 0; i < bytes / 8; i = i + 1) if (host.mem[(a >> 3) + i] !== host.mem[(b >> 3) + i]) same_host = 0; end
  endfunction

  integer i, c0, msi0;

  // ---------------------------------------------------------------------------
  // GEMM reference: the same arithmetic as npu_mm and sw/npu/npu_ref.py.
  function [7:0] cbyte(input integer addr); cbyte = card.mem[addr >> 3][(addr & 7) * 8 +: 8]; endfunction
  function [31:0] cword(input integer addr); cword = card.mem[addr >> 3][(addr & 4) * 8 +: 32]; endfunction
  task cset(input integer addr, input [7:0] v); card.mem[addr >> 3][(addr & 7) * 8 +: 8] = v; endtask
  task cset32(input integer addr, input [31:0] v); card.mem[addr >> 3][(addr & 4) * 8 +: 32] = v; endtask

  // Verilog-2001 functions are static: two calls in one expression share a
  // return value, so each byte goes through its own temporary.
  function signed [31:0] ref_acc(input integer a, input integer bt, input integer bias, input integer k, input integer m, input integer n);
    integer t; reg signed [31:0] s; reg signed [7:0] x, y;
    begin
      s = $signed(cword(bias + 4 * n));
      for (t = 0; t < k; t = t + 1) begin
        x = cbyte(a + m * k + t);
        y = cbyte(bt + n * k + t);
        s = s + x * y;
      end
      ref_acc = s;
    end
  endfunction
  function [7:0] ref_q(input signed [31:0] acc, input [15:0] mult, input [4:0] sh, input rl);
    reg signed [48:0] p;
    begin
      p = acc * $signed({1'b0, mult});
      if (sh != 0) p = (p + (49'sd1 <<< (sh - 1))) >>> sh;
      if (rl && p < 0) p = 0;
      if (p > 127) p = 127;
      if (p < -128) p = -128;
      ref_q = p[7:0];
    end
  endfunction

  // Fills A (M x K) and Bt (N x K) with random INT8, bias with random INT32.
  task gemm_data(input integer a, input integer bt, input integer bias, input integer m, input integer k, input integer n, input integer seed);
    integer t, sd; begin
      sd = seed;
      for (t = 0; t < m * k; t = t + 1) cset(a + t, $random(sd));
      for (t = 0; t < n * k; t = t + 1) cset(bt + t, $random(sd));
      for (t = 0; t < n; t = t + 1) cset32(bias + 4 * t, $random(sd) % 20000);
    end
  endtask

  // Submits a GEMM: word0 M; word1 A, Bt; word2 C, bias; word3 K, N, shift, relu, out32, mult.
  task submit_gemm(input [15:0] cid, input integer m, input integer a, input integer bt, input integer c, input integer bias,
                   input integer k, input integer n, input [4:0] sh, input rl, input o32, input [15:0] mult);
    integer base, t;
    begin
      base = (cfg_sq_base + sq_tail * 64) >> 3;
      host.mem[base + 0] = {m[31:0], cid, 8'h00, 8'h10};
      host.mem[base + 1] = {bt[31:0], a[31:0]};
      host.mem[base + 2] = {bias[31:0], c[31:0]};
      host.mem[base + 3] = {mult, 6'd0, o32, rl, 3'd0, sh, n[15:0], k[15:0]};
      for (t = 4; t < 8; t = t + 1) host.mem[base + t] = 64'd0;
      sq_tail = (sq_tail + 1) % entries;
    end
  endtask

  integer gm, gn, gbad;
  reg signed [31:0] gacc;

  initial begin
    for (i = 0; i < 16384; i = i + 1) host.mem[i] = 64'd0;
    for (i = 0; i < (1 << 19); i = i + 1) card.mem[i] = 64'd0;
    repeat (5) @(posedge clk); rst_n = 1;
    repeat (5) @(posedge clk);
    check("ring settings accepted (cfg_err)", cfg_err, 0);
    cfg_enable = 1;
    repeat (3) @(posedge clk);

    // 1. 40 NOPs in batches of 5: in order, across five ring wraps.
    msi0 = msi_count;
    for (c0 = 0; c0 < 40; c0 = c0 + 5) begin
      for (i = 0; i < 5; i = i + 1) submit(8'h00, (i == 4) ? 8'h01 : 8'h00, c0 + i, 0, 0, 0);
      ring_sq;
      for (i = 0; i < 5; i = i + 1) expect_cpl(c0 + i, 8'd0, 1);
    end
    settle;
    check("NOPs completed", completed, 40);
    repeat (20) @(posedge clk);
    check("MSIs requested (one per batch, flags[0] on the last)", msi_count - msi0, 8);

    // 2. A full CQ stalls the engine until the host releases a slot.
    for (i = 0; i < 7; i = i + 1) submit(8'h00, 8'h00, 100 + i, 0, 0, 0);
    ring_sq;
    i = 0; while (completed != 47 && i < 100000) begin @(posedge clk); i = i + 1; end
    check("7 completions fill the 8-entry CQ", completed, 47);
    submit(8'h00, 8'h00, 107, 0, 0, 0);
    ring_sq;
    repeat (3000) @(posedge clk);
    check("engine stalled on a full CQ", stalled, 1);
    check("no completion while stalled", completed, 47);
    for (i = 0; i < 8; i = i + 1) expect_cpl(100 + i, 8'd0, 1);
    settle;
    check("stall released", completed, 48);

    // 3. Copies: 32 KiB host -> card -> host, then 8256 bytes (short last burst).
    fill_host(32'h4000, 32768, 7);
    submit(8'h01, 8'h00, 200, 32768, 64'h4000, 64'h2000);
    submit(8'h02, 8'h01, 201, 32768, 64'hC000, 64'h2000);
    ring_sq;
    expect_cpl(200, 8'd0, 1);
    expect_cpl(201, 8'd0, 1);
    check("32 KiB round trip matches", same_host(32'h4000, 32'hC000, 32768), 1);
    check("card memory holds the copy", card.mem[(32'h2000 >> 3) + 77] === host.mem[(32'h4000 >> 3) + 77], 1);
    fill_host(32'h4000, 8256, 9);
    submit(8'h01, 8'h00, 202, 8256, 64'h4000, 64'h10000);
    submit(8'h02, 8'h00, 203, 8256, 64'h14000, 64'h10000);
    ring_sq;
    expect_cpl(202, 8'd0, 1);
    expect_cpl(203, 8'd0, 1);
    check("8256-byte round trip matches", same_host(32'h4000, 32'h14000, 8256), 1);
    check("bytes after the copy untouched", host.mem[(32'h14000 + 8256) >> 3], 0);

    // 4. Rejected commands.
    submit(8'h07, 8'h00, 300, 0, 0, 0);                            // unknown opcode
    submit(8'h01, 8'h00, 301, 100, 64'h4000, 64'h2000);            // length not a multiple of 64
    submit(8'h01, 8'h00, 302, 4096, 64'h4040, 64'h2000);           // host address not 4 KiB aligned
    submit(8'h02, 8'h00, 303, 4096, 64'h4000, 64'h4000_0000);      // beyond card memory
    submit(8'h01, 8'h00, 304, 4096, 64'h8000_0000, 64'h2000);      // beyond the 2 GiB host window
    ring_sq;
    expect_cpl(300, 8'd1, 1);
    expect_cpl(301, 8'd2, 1);
    expect_cpl(302, 8'd2, 1);
    expect_cpl(303, 8'd2, 1);
    expect_cpl(304, 8'd2, 1);
    check("no AXI error from rejected commands", axi_err, 0);

    // 5. An AXI error on the card side.
    card_err = 1;
    submit(8'h01, 8'h00, 400, 4096, 64'h4000, 64'h2000);
    ring_sq;
    expect_cpl(400, 8'd3, 1);
    card_err = 0;
    check("AXI error is sticky", axi_err, 1);

    // 6. Re-enabling resets the rings and the error.
    cfg_enable = 0; repeat (5) @(posedge clk); cfg_enable = 1; repeat (5) @(posedge clk);
    sq_tail = 0; cq_head = 0; exp_phase = 1;
    for (i = 0; i < 16; i = i + 1) host.mem[(32'h1000 >> 3) + i] = 64'd0;
    check("re-enable clears the AXI error", axi_err, 0);
    submit(8'h00, 8'h00, 500, 0, 0, 0);
    ring_sq;
    expect_cpl(500, 8'd0, 1);
    settle;
    check("completed restarts from 0", completed, 1);

    // 7. No stalls: a long copy at full rate.
    host_stall = 0; card_stall = 0;
    fill_host(32'h4000, 32768, 3);
    c0 = cycles;
    submit(8'h01, 8'h00, 600, 32768, 64'h4000, 64'h2000);
    ring_sq;
    expect_cpl(600, 8'd0, 1);
    $display("ok    32 KiB COPY_H2C without stalls: %0d cycles (4096 beats)", w1[63:32] - w1[31:0]);
    if (w1[63:32] - w1[31:0] > 4096 + 1000) fail("copy far slower than one beat per cycle");

    // 8. Slaves that wait for write data before taking the address.
    waits_w = 1; host_stall = 1; card_stall = 1;
    fill_host(32'h4000, 8192, 5);
    submit(8'h01, 8'h00, 700, 8192, 64'h4000, 64'h6000);
    submit(8'h02, 8'h00, 701, 8192, 64'hC000, 64'h6000);
    ring_sq;
    expect_cpl(700, 8'd0, 1);
    expect_cpl(701, 8'd0, 1);
    check("round trip with slaves waiting for WVALID", same_host(32'h4000, 32'hC000, 8192), 1);
    waits_w = 0;

    // 9. GEMM: INT8 output with ReLU, INT8 without, INT32 output; bad shapes.
    gemm_data(32'h4000, 32'h8000, 32'hF000, 3, 192, 128, 77);
    submit_gemm(800, 3, 32'h4000, 32'h8000, 32'h10000, 32'hF000, 192, 128, 5'd9, 1'b1, 1'b0, 16'd37);
    submit_gemm(801, 3, 32'h4000, 32'h8000, 32'h11000, 32'hF000, 192, 128, 5'd4, 1'b0, 1'b0, 16'd1000);
    submit_gemm(802, 3, 32'h4000, 32'h8000, 32'h12000, 32'hF000, 192, 128, 5'd0, 1'b0, 1'b1, 16'd1);
    ring_sq;
    expect_cpl(800, 8'd0, 1);
    expect_cpl(801, 8'd0, 1);
    expect_cpl(802, 8'd0, 1);
    // Also checked against the Python model: sw/npu/check_gemm.py reads this dump.
    $writememh("card_mem_after_gemm.hex", card.mem);
    gbad = 0;
    for (gm = 0; gm < 3; gm = gm + 1)
      for (gn = 0; gn < 128; gn = gn + 1) begin
        gacc = ref_acc(32'h4000, 32'h8000, 32'hF000, 192, gm, gn);
        if (cbyte(32'h10000 + gm * 128 + gn) !== ref_q(gacc, 16'd37, 5'd9, 1'b1)) gbad = gbad + 1;
        if (cbyte(32'h11000 + gm * 128 + gn) !== ref_q(gacc, 16'd1000, 5'd4, 1'b0)) gbad = gbad + 1;
        if (cword(32'h12000 + 4 * (gm * 128 + gn)) !== gacc) gbad = gbad + 1;
      end
    check("GEMM 3x192 . 192x128: outputs differing from the reference (of 1152)", gbad, 0);
    check("GEMM with ReLU produced no negative outputs", cbyte(32'h10000 + 5) < 8'h80, 1);
    submit_gemm(803, 1, 32'h4000, 32'h8000, 32'h10000, 32'hF000, 100, 128, 5'd0, 1'b0, 1'b0, 16'd1);   // K not a multiple of 64
    submit_gemm(804, 1, 32'h4000, 32'h8000, 32'h10000, 32'hF000, 192, 10, 5'd0, 1'b0, 1'b0, 16'd1);    // N not a multiple of 64
    submit_gemm(805, 1, 32'h4010, 32'h8000, 32'h10000, 32'hF000, 192, 128, 5'd0, 1'b0, 1'b0, 16'd1);   // A not 64-byte aligned
    ring_sq;
    expect_cpl(803, 8'd2, 1);
    expect_cpl(804, 8'd2, 1);
    expect_cpl(805, 8'd2, 1);

    // 10. GEMM at the engine's limits, K = 2048 and N = 1024: a 2 MiB Bt,
    // and INT32 rows of 4 KiB (512 words). INT8 and INT32 outputs.
    gemm_data(32'h20000, 32'h100000, 32'h21000, 1, 2048, 1024, 91);
    submit_gemm(806, 1, 32'h20000, 32'h100000, 32'h22000, 32'h21000, 2048, 1024, 5'd12, 1'b1, 1'b0, 16'd300);
    submit_gemm(807, 1, 32'h20000, 32'h100000, 32'h24000, 32'h21000, 2048, 1024, 5'd0, 1'b0, 1'b1, 16'd1);
    ring_sq;
    expect_cpl(806, 8'd0, 1);
    expect_cpl(807, 8'd0, 1);
    gbad = 0;
    for (gn = 0; gn < 1024; gn = gn + 1) begin
      gacc = ref_acc(32'h20000, 32'h100000, 32'h21000, 2048, 0, gn);
      if (cbyte(32'h22000 + gn) !== ref_q(gacc, 16'd300, 5'd12, 1'b1)) gbad = gbad + 1;
      if (cword(32'h24000 + 4 * gn) !== gacc) gbad = gbad + 1;
    end
    check("GEMM 1x2048 . 2048x1024: outputs differing from the reference (of 2048)", gbad, 0);

    // 11. Tiles: M = 19 is two full 8-row tiles and a short one of 3. Then
    // the speed-up of the tiles: Bt is read once per 8 rows, not per row.
    gemm_data(32'h30000, 32'h31000, 32'h34000, 19, 128, 64, 55);
    submit_gemm(808, 19, 32'h30000, 32'h31000, 32'h35000, 32'h34000, 128, 64, 5'd7, 1'b1, 1'b0, 16'd90);
    submit_gemm(809, 19, 32'h30000, 32'h31000, 32'h36000, 32'h34000, 128, 64, 5'd0, 1'b0, 1'b1, 16'd1);
    ring_sq;
    expect_cpl(808, 8'd0, 1);
    expect_cpl(809, 8'd0, 1);
    gbad = 0;
    for (gm = 0; gm < 19; gm = gm + 1)
      for (gn = 0; gn < 64; gn = gn + 1) begin
        gacc = ref_acc(32'h30000, 32'h31000, 32'h34000, 128, gm, gn);
        if (cbyte(32'h35000 + gm * 64 + gn) !== ref_q(gacc, 16'd90, 5'd7, 1'b1)) gbad = gbad + 1;
        if (cword(32'h36000 + 4 * (gm * 64 + gn)) !== gacc) gbad = gbad + 1;
      end
    check("GEMM 19x128 . 128x64 in tiles of 8, 8 and 3: outputs differing from the reference (of 2432)", gbad, 0);
    check("bytes after the last C row untouched", cbyte(32'h35000 + 19 * 64), 0);
    gemm_data(32'h40000, 32'h50000, 32'h48000, 64, 512, 256, 33);
    submit_gemm(810, 64, 32'h40000, 32'h50000, 32'h70000, 32'h48000, 512, 256, 5'd12, 1'b0, 1'b0, 16'd7);
    ring_sq;
    expect_cpl(810, 8'd0, 1);
    $display("info  GEMM 64x512 . 512x256: %0d cycles, %0d MACs per cycle (Bt alone: %0d beats per tile, 8 tiles)",
             w1[63:32] - w1[31:0], 64 * 512 * 256 / (w1[63:32] - w1[31:0]), 256 * 512 / 8);
    gbad = 0;
    for (gm = 0; gm < 64; gm = gm + 7)
      for (gn = 0; gn < 256; gn = gn + 1) begin
        gacc = ref_acc(32'h40000, 32'h50000, 32'h48000, 512, gm, gn);   // static functions: one call per statement
        if (cbyte(32'h70000 + gm * 256 + gn) !== ref_q(gacc, 16'd7, 5'd12, 1'b0)) gbad = gbad + 1;
      end
    check("GEMM 64x512 . 512x256, every 7th row: outputs differing from the reference (of 2560)", gbad, 0);

    repeat (20) @(posedge clk);
    check("host port AXI violations", host.violations, 0);
    check("card port AXI violations", card.violations, 0);

    if (errors == 0) $display("RESULT: PASS");
    else             $display("RESULT: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #50000000;
    $display("RESULT: FAIL (timeout)");
    $finish;
  end

endmodule

`default_nettype wire
