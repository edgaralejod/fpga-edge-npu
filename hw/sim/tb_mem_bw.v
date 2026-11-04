// Self-checking testbench for mem_bw (card-side DDR3 bandwidth engine).
//
// Two unrelated clocks (control 125 MHz, memory 100 MHz) and an AXI4 slave
// memory model with random stalls on every channel. Covers: write then read
// back with no mismatches, a wrong seed (every beat mismatches), a single
// corrupted word (exactly one mismatch), a zero-length run, the outstanding-
// burst window (16 in flight is faster than 1), AXI error responses, a slave
// that waits for WVALID before AWREADY (legal; a master that waits for AWREADY
// first deadlocks), and the master's handshake rules (VALID and payload held
// until READY). Prints
// "RESULT: PASS" or "RESULT: FAIL".

`timescale 1ns / 1ps
`default_nettype none

module tb_mem_bw;

  reg ctl_clk = 1'b0, m_clk = 1'b0;
  always #4 ctl_clk = ~ctl_clk;   // 125 MHz
  always #5 m_clk   = ~m_clk;     // 100 MHz
  reg ctl_rst_n = 1'b0, m_rst_n = 1'b0;

  reg         ctl_start = 1'b0, ctl_read = 1'b0;
  reg  [31:0] ctl_addr = 0, ctl_len = 0;
  reg  [4:0]  ctl_outstanding = 0;
  reg  [15:0] ctl_seed = 0;
  wire        ctl_busy;
  wire [31:0] ctl_cycles, ctl_mismatches, ctl_errors, ctl_runs;

  wire [31:0]  awaddr, araddr;
  wire [7:0]   awlen, arlen;
  wire [2:0]   awsize, arsize;
  wire [1:0]   awburst, arburst;
  wire [3:0]   awcache, arcache;
  wire [2:0]   awprot, arprot;
  wire         awlock, arlock;
  wire         awvalid, wlast, wvalid, bready, arvalid, rready;
  wire [511:0] wdata;
  wire [63:0]  wstrb;
  reg          awready = 0, wready = 0, bvalid = 0, arready = 0, rvalid = 0, rlast = 0;
  reg  [1:0]   bresp = 0, rresp = 0;
  reg  [511:0] rdata = 0;

  mem_bw dut (
    .ctl_clk(ctl_clk), .ctl_rst_n(ctl_rst_n), .ctl_start(ctl_start), .ctl_read(ctl_read),
    .ctl_addr(ctl_addr), .ctl_len(ctl_len), .ctl_outstanding(ctl_outstanding), .ctl_seed(ctl_seed),
    .ctl_busy(ctl_busy), .ctl_cycles(ctl_cycles), .ctl_mismatches(ctl_mismatches),
    .ctl_errors(ctl_errors), .ctl_runs(ctl_runs),
    .m_clk(m_clk), .m_rst_n(m_rst_n),
    .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize), .m_axi_awburst(awburst),
    .m_axi_awcache(awcache), .m_axi_awprot(awprot), .m_axi_awlock(awlock),
    .m_axi_awvalid(awvalid), .m_axi_awready(awready),
    .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
    .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
    .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize), .m_axi_arburst(arburst),
    .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arlock(arlock),
    .m_axi_arvalid(arvalid), .m_axi_arready(arready),
    .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
  );

  // ---------------------------------------------------------------------------
  // AXI4 slave memory model: 64 KiB (1024 beats), address bits [15:6].
  reg [511:0] mem [0:1023];
  reg [31:0]  aw_q [0:15];
  reg [31:0]  ar_q [0:15];
  integer     ar_t [0:15];           // cycle each read address arrived
  integer     cyc = 0;
  localparam  READ_LATENCY = 20;     // cycles from AR to the first R beat, like a DRAM controller
  reg [4:0]   ar_rd_n;
  reg [5:0]   rbeat_n;
  reg [4:0]   aw_wr = 0, aw_rd = 0, ar_wr = 0, ar_rd = 0;
  reg [5:0]   wbeat = 0, rbeat = 0;
  integer     b_pending = 0;
  reg         stall = 1'b1;          // random stalls on all channels
  reg         err_inject = 1'b0;     // answer SLVERR instead of OKAY
  reg         aw_waits_w = 1'b0;     // AWREADY only after WVALID, as AXI allows a slave to do
  integer     seed = 7;

  function chance(input integer pct);
    chance = !stall || (($random(seed) & 32'h7fffffff) % 100) < pct;
  endfunction

  always @(posedge m_clk) begin
    // AW: queue addresses
    if (awvalid && awready) begin aw_q[aw_wr[3:0]] <= awaddr; aw_wr <= aw_wr + 1; end
    awready <= ((aw_wr - aw_rd) < 5'd8) && chance(60) && (!aw_waits_w || wvalid);
    // W: needs an address in the queue
    if (wvalid && wready) begin
      mem[aw_q[aw_rd[3:0]][15:6] + wbeat] <= wdata;
      wbeat <= wbeat + 1;
      if (wlast) begin aw_rd <= aw_rd + 1; wbeat <= 0; b_pending = b_pending + 1; end
    end
    wready <= (aw_wr != aw_rd) && chance(70);
    // B
    if (bvalid && bready) begin bvalid <= 1'b0; b_pending = b_pending - 1; end
    else if (!bvalid && b_pending > 0 && chance(50)) begin
      bvalid <= 1'b1; bresp <= err_inject ? 2'b10 : 2'b00;
    end
    // AR
    cyc = cyc + 1;
    if (arvalid && arready) begin ar_q[ar_wr[3:0]] <= araddr; ar_t[ar_wr[3:0]] <= cyc; ar_wr <= ar_wr + 1; end
    arready <= ((ar_wr - ar_rd) < 5'd8) && chance(60);
    // R: beats stream back to back from the queue head once its latency has passed
    if (!rvalid || rready) begin
      ar_rd_n = ar_rd; rbeat_n = rbeat;
      if (rvalid) begin
        if (rlast) begin ar_rd_n = ar_rd + 1; rbeat_n = 0; end
        else rbeat_n = rbeat + 1;
      end
      ar_rd <= ar_rd_n; rbeat <= rbeat_n;
      if (ar_wr != ar_rd_n && cyc >= ar_t[ar_rd_n[3:0]] + READ_LATENCY && chance(70)) begin
        rvalid <= 1'b1;
        rdata  <= mem[ar_q[ar_rd_n[3:0]][15:6] + rbeat_n];
        rlast  <= (rbeat_n == 6'd63);
        rresp  <= err_inject ? 2'b10 : 2'b00;
      end else rvalid <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Checks
  integer errors = 0;

  task check(input [511:0] what, input [31:0] got, input [31:0] want);
    begin
      if (got !== want) begin
        $display("FAIL  %0s: got %0d, want %0d", what, got, want); errors = errors + 1;
      end else $display("ok    %0s = %0d", what, got);
    end
  endtask

  // Master handshake rules: once VALID is up it stays up, with the same
  // payload, until READY.
  reg         aw_hold = 0, ar_hold = 0, w_hold = 0;
  reg [31:0]  aw_prev, ar_prev;
  reg [511:0] w_prev;
  always @(posedge m_clk) begin
    if (aw_hold && (!awvalid || awaddr !== aw_prev)) begin $display("FAIL  AWVALID or AWADDR changed before AWREADY"); errors = errors + 1; end
    if (ar_hold && (!arvalid || araddr !== ar_prev)) begin $display("FAIL  ARVALID or ARADDR changed before ARREADY"); errors = errors + 1; end
    if (w_hold  && (!wvalid  || wdata  !== w_prev))  begin $display("FAIL  WVALID or WDATA changed before WREADY");   errors = errors + 1; end
    aw_hold <= awvalid && !awready; aw_prev <= awaddr;
    ar_hold <= arvalid && !arready; ar_prev <= araddr;
    w_hold  <= wvalid  && !wready;  w_prev  <= wdata;
    if ((awvalid && (awlen != 8'd63 || awsize != 3'd6 || awburst != 2'b01 || awaddr[11:0] != 0)) ||
        (arvalid && (arlen != 8'd63 || arsize != 3'd6 || arburst != 2'b01 || araddr[11:0] != 0))) begin
      $display("FAIL  burst is not 64 x 64-byte INCR on a 4 KiB boundary"); errors = errors + 1;
    end
  end

  task run(input rd, input [31:0] addr, input [31:0] len, input [4:0] outst, input [15:0] sd);
    integer n;
    begin
      @(posedge ctl_clk);
      ctl_read <= rd; ctl_addr <= addr; ctl_len <= len; ctl_outstanding <= outst; ctl_seed <= sd;
      @(posedge ctl_clk); ctl_start <= 1'b1;
      @(posedge ctl_clk); ctl_start <= 1'b0;
      @(posedge ctl_clk);
      n = 0;
      while (ctl_busy && n < 200000) begin @(posedge ctl_clk); n = n + 1; end
      if (ctl_busy) begin $display("FAIL  run did not finish"); errors = errors + 1; end
    end
  endtask

  integer c1, c16;

  initial begin
    repeat (5) @(posedge m_clk);
    ctl_rst_n = 1'b1; m_rst_n = 1'b1;
    repeat (5) @(posedge m_clk);

    run(0, 32'h0000_8000, 32'h8000, 0, 16'hBEEF);   // write 32 KiB
    check("write run: errors", ctl_errors, 0);
    check("runs", ctl_runs, 1);
    run(1, 32'h0000_8000, 32'h8000, 0, 16'hBEEF);   // read back
    check("read back: mismatched beats", ctl_mismatches, 0);
    check("read back: errors", ctl_errors, 0);
    check("runs", ctl_runs, 2);

    run(1, 32'h0000_8000, 32'h8000, 0, 16'h1234);   // wrong seed
    check("wrong seed: mismatched beats (all 512)", ctl_mismatches, 512);

    mem[600][100] = ~mem[600][100];                 // corrupt one bit
    run(1, 32'h0000_8000, 32'h8000, 0, 16'hBEEF);
    check("one corrupted bit: mismatched beats", ctl_mismatches, 1);

    run(1, 32'h0000_8000, 32'h0, 0, 16'hBEEF);      // zero length
    check("zero length: runs", ctl_runs, 5);
    check("zero length: mismatched beats", ctl_mismatches, 0);

    stall = 1'b0;                                   // no stalls: compare windows
    run(1, 32'h0000_0000, 32'h10000, 1, 16'h0);
    c1 = ctl_cycles;
    run(1, 32'h0000_0000, 32'h10000, 16, 16'h0);
    c16 = ctl_cycles;
    // 16 bursts of 64 beats: with one burst in flight each pays the read
    // latency; with 16 in flight the latency is paid once.
    if (c1 > 1024 + 15 * READ_LATENCY) $display("ok    1 burst in flight: %0d cycles (latency paid per burst)", c1);
    else begin $display("FAIL  1 burst in flight: %0d cycles, expected over %0d", c1, 1024 + 15 * READ_LATENCY); errors = errors + 1; end
    if (c16 < 1024 + 2 * READ_LATENCY) $display("ok    16 bursts in flight: %0d cycles for 1024 beats (latency hidden)", c16);
    else begin $display("FAIL  16 bursts in flight: %0d cycles, expected under %0d", c16, 1024 + 2 * READ_LATENCY); errors = errors + 1; end
    stall = 1'b1;

    aw_waits_w = 1'b1;                              // slave waits for WVALID before AWREADY
    run(0, 32'h0000_4000, 32'h4000, 0, 16'h5A5A);
    check("slave waiting for WVALID: write runs complete", ctl_runs, 8);
    run(1, 32'h0000_4000, 32'h4000, 0, 16'h5A5A);
    check("slave waiting for WVALID: mismatched beats", ctl_mismatches, 0);
    aw_waits_w = 1'b0;

    err_inject = 1'b1;                              // SLVERR on every response
    run(0, 32'h0000_0000, 32'h2000, 0, 16'h0);
    check("write SLVERR: errors (one per burst)", ctl_errors, 2);
    run(1, 32'h0000_0000, 32'h2000, 0, 16'h0);
    check("read SLVERR: errors (one per beat)", ctl_errors, 128);
    err_inject = 1'b0;

    if (errors == 0) $display("RESULT: PASS");
    else             $display("RESULT: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #20000000;
    $display("RESULT: FAIL (timeout)");
    $finish;
  end

endmodule

`default_nettype wire
