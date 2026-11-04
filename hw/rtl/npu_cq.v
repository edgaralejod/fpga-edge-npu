// npu_cq: the card's command queue engine (roadmap phase 3).
//
// Implements docs/command-queue.md: the host keeps a submission ring (SQ) of
// 64-byte commands and a completion ring (CQ) of 16-byte completions in its
// own memory. This engine fetches commands through the PCIe bridge's AXI
// slave (the host port), runs them, writes completions back with an
// NVMe-style phase bit, and requests an MSI when a command asks for one.
//
//   NOP       completes at once (measures the queue's own overhead)
//   COPY_H2C  host memory -> card memory
//   COPY_C2H  card memory -> host memory
//   GEMM      INT8 matrix multiply in card memory (npu_mm)
//
// Copies stream through a FIFO: up to four 2 KiB reads in flight, writes
// issued a burst at a time once the burst's data is in the FIFO. Host and
// card addresses must be 4 KiB aligned and the length a multiple of 64, so
// no 2 KiB burst crosses a 4 KiB boundary.
//
// Host bus addresses reach the bridge's AXI window at 0x8000_0000 (bus
// addresses below 2 GiB, a fixed translation); card addresses are AXI
// addresses of the DDR3 (below 1 GiB).
//
// AXI master rules, as AMD's AXI4 master template and hw/sim checks: VALIDs
// never depend on READY and hold with their payload until the handshake;
// write data may go out while its address is still waiting.
//
// Everything runs in the bridge's 125 MHz clock domain, the same as npu_regs.

`timescale 1ns / 1ps
`default_nettype none

module npu_cq (
  input  wire        clk,
  input  wire        rst_n,

  // Configuration and doorbells, from npu_regs
  input  wire        cfg_enable,
  input  wire        cfg_irq_en,
  input  wire [3:0]  cfg_log2,        // ring entries = 2^cfg_log2, 1..12
  input  wire [63:0] cfg_sq_base,     // bus addresses
  input  wire [63:0] cfg_cq_base,
  input  wire        sq_tail_wr,
  input  wire [11:0] sq_tail_val,
  input  wire        cq_head_wr,
  input  wire [11:0] cq_head_val,
  input  wire [31:0] cycles,          // npu_regs' cycle counter, for timestamps

  // Status, to npu_regs
  output wire        busy,
  output wire        stalled,         // waiting for the host to release a CQ slot
  output reg         axi_err,         // sticky until the queue is re-enabled
  output wire        cfg_err,         // ring addresses outside the window
  output reg  [31:0] completed,

  // MSI, to the bridge
  input  wire        msi_enable,
  output reg         msi_request,     // one-cycle pulse
  input  wire        msi_grant,       // one-cycle pulse

  // Host port: AXI4 master into the bridge's slave window
  output wire [31:0] h_awaddr,  output wire [7:0] h_awlen,  output wire [2:0] h_awsize,
  output wire [1:0]  h_awburst, output wire       h_awvalid, input  wire       h_awready,
  output wire [63:0] h_wdata,   output wire [7:0] h_wstrb,  output wire       h_wlast,
  output wire        h_wvalid,  input  wire       h_wready,
  input  wire [1:0]  h_bresp,   input  wire       h_bvalid, output wire       h_bready,
  output wire [31:0] h_araddr,  output wire [7:0] h_arlen,  output wire [2:0] h_arsize,
  output wire [1:0]  h_arburst, output wire       h_arvalid, input  wire       h_arready,
  input  wire [63:0] h_rdata,   input  wire [1:0] h_rresp,  input  wire       h_rlast,
  input  wire        h_rvalid,  output wire       h_rready,

  // Card port: AXI4 master into card memory
  output wire [31:0] c_awaddr,  output wire [7:0] c_awlen,  output wire [2:0] c_awsize,
  output wire [1:0]  c_awburst, output wire       c_awvalid, input  wire       c_awready,
  output wire [63:0] c_wdata,   output wire [7:0] c_wstrb,  output wire       c_wlast,
  output wire        c_wvalid,  input  wire       c_wready,
  input  wire [1:0]  c_bresp,   input  wire       c_bvalid, output wire       c_bready,
  output wire [31:0] c_araddr,  output wire [7:0] c_arlen,  output wire [2:0] c_arsize,
  output wire [1:0]  c_arburst, output wire       c_arvalid, input  wire       c_arready,
  input  wire [63:0] c_rdata,   input  wire [1:0] c_rresp,  input  wire       c_rlast,
  input  wire        c_rvalid,  output wire       c_rready
);

  localparam [7:0] OP_NOP = 8'h00, OP_COPY_H2C = 8'h01, OP_COPY_C2H = 8'h02, OP_GEMM = 8'h10;
  localparam [7:0] ST_OK = 8'd0, ST_BAD_OPCODE = 8'd1, ST_BAD_LENGTH = 8'd2, ST_AXI_ERROR = 8'd3;

  localparam [31:0] WINDOW = 32'h8000_0000;   // AXI address of host bus address 0
  localparam [32:0] HOST_LIMIT = 33'h0_8000_0000;  // 2 GiB of host bus addresses
  localparam [32:0] CARD_LIMIT = 33'h0_4000_0000;  // 1 GiB of DDR3

  // Host bus address -> AXI address in the bridge window.
  function [31:0] host_axi(input [31:0] bus);
    host_axi = WINDOW | {1'b0, bus[30:0]};
  endfunction

  // ---------------------------------------------------------------------------
  // Rings
  wire [11:0] mask = ~(12'hFFF << cfg_log2);
  reg  [11:0] sq_head, sq_tail, cq_tail, cq_head;
  reg         phase;
  reg         en_d;

  assign cfg_err = (cfg_sq_base[63:31] != 0) || (cfg_cq_base[63:31] != 0) ||
                   (cfg_log2 == 4'd0) || (cfg_log2 > 4'd12);
  wire running = cfg_enable && !cfg_err;

  // ---------------------------------------------------------------------------
  // Controller
  localparam [3:0] S_IDLE = 4'd0, S_FETCH_AR = 4'd1, S_FETCH_R = 4'd2, S_EXEC = 4'd3,
                   S_MOVE = 4'd4, S_CQ_WAIT = 4'd5, S_CPL = 4'd6, S_CPL_B = 4'd7, S_GEMM = 4'd8;
  reg [3:0]  state;
  reg [2:0]  fbeat;            // command beat being received
  reg [63:0] cmd0, cmd1, cmd2, cmd3; // see docs/command-queue.md for each opcode's layout
  reg        fetch_err;
  reg [7:0]  status;
  reg [31:0] t_fetch, t_done;
  reg        cpl_aw_ok;
  reg [1:0]  cpl_wbeat;
  reg        msi_pending, msi_wait;

  wire [7:0]  opcode  = cmd0[7:0];
  wire [7:0]  flags   = cmd0[15:8];
  wire [15:0] cid     = cmd0[31:16];
  wire [31:0] length  = cmd0[63:32];
  wire [63:0] haddr   = cmd1;
  wire [63:0] caddr   = cmd2;

  wire copy_ok = (length != 32'd0) && (length[5:0] == 6'd0) &&
                 (haddr[11:0] == 12'd0) && (caddr[11:0] == 12'd0) &&
                 (haddr[63:31] == 0) && (caddr[63:30] == 0) &&
                 ({1'b0, haddr[31:0]} + {1'b0, length} <= HOST_LIMIT) &&
                 ({1'b0, caddr[31:0]} + {1'b0, length} <= CARD_LIMIT);

  // GEMM: word0 [63:32] M; word1 A, Bt; word2 C, bias; word3 [15:0] K,
  // [31:16] N, [36:32] shift, [40] relu, [41] out32, [63:48] mult.
  wire [31:0] g_m = cmd0[63:32];
  wire [15:0] g_k = cmd3[15:0], g_n = cmd3[31:16];
  wire        g_out32 = cmd3[41];
  wire [63:0] g_a_end = {32'd0, cmd1[31:0]}  + {32'd0, g_m} * {48'd0, g_k};
  wire [63:0] g_b_end = {32'd0, cmd1[63:32]} + {48'd0, g_n} * {48'd0, g_k};
  wire [63:0] g_c_end = {32'd0, cmd2[31:0]}  + {32'd0, g_m} * {48'd0, g_n} * (g_out32 ? 64'd4 : 64'd1);
  wire [63:0] g_bias_end = {32'd0, cmd2[63:32]} + {48'd0, g_n} * 64'd4;
  wire gemm_ok = (g_m != 0) && (g_k != 0) && (g_k[5:0] == 0) && (g_k <= 16'd2048) &&
                 (g_n != 0) && (g_n[5:0] == 0) && (g_n <= 16'd1024) &&
                 (cmd1[5:0] == 0) && (cmd1[37:32] == 0) && (cmd2[5:0] == 0) && (cmd2[37:32] == 0) &&
                 (g_a_end <= 64'h4000_0000) && (g_b_end <= 64'h4000_0000) &&
                 (g_c_end <= 64'h4000_0000) && (g_bias_end <= 64'h4000_0000);

  wire cq_full = (((cq_tail + 12'd1) & mask) == cq_head);

  assign busy    = (state != S_IDLE);
  assign stalled = (state == S_CQ_WAIT) && cq_full;

  // Mover and matrix engine handshakes
  reg        mv_start, mv_dir;          // dir 0: H2C, 1: C2H
  wire       mv_done, mv_err;
  reg        mm_start;
  wire       mm_done, mm_err;

  always @(posedge clk) begin
    if (!rst_n) begin
      state <= S_IDLE; en_d <= 1'b0;
      sq_head <= 0; sq_tail <= 0; cq_tail <= 0; cq_head <= 0; phase <= 1'b1;
      fbeat <= 0; cmd0 <= 0; cmd1 <= 0; cmd2 <= 0; cmd3 <= 0; fetch_err <= 1'b0;
      status <= ST_OK; t_fetch <= 0; t_done <= 0;
      cpl_aw_ok <= 1'b0; cpl_wbeat <= 0;
      axi_err <= 1'b0; completed <= 0;
      msi_pending <= 1'b0; msi_wait <= 1'b0; msi_request <= 1'b0;
      mv_start <= 1'b0; mv_dir <= 1'b0; mm_start <= 1'b0;
    end else begin
      en_d     <= cfg_enable;
      mv_start <= 1'b0;
      mm_start <= 1'b0;

      // Enabling the queue starts both rings empty, phase 1.
      if (cfg_enable && !en_d) begin
        sq_head <= 0; sq_tail <= 0; cq_tail <= 0; cq_head <= 0; phase <= 1'b1;
        completed <= 0; axi_err <= 1'b0;
      end else begin
        if (sq_tail_wr) sq_tail <= sq_tail_val & mask;
        if (cq_head_wr) cq_head <= cq_head_val & mask;
      end

      // MSI requester: one request in flight, retried until granted.
      msi_request <= 1'b0;
      if (msi_pending && !msi_wait && msi_enable) begin
        msi_request <= 1'b1;
        msi_wait    <= 1'b1;
        msi_pending <= 1'b0;
      end
      if (msi_grant || !msi_enable) msi_wait <= 1'b0;   // no grant comes once MSI is off

      case (state)
        S_IDLE:
          if (running && en_d && (sq_head != sq_tail)) state <= S_FETCH_AR;

        S_FETCH_AR:
          if (h_arvalid && h_arready) begin
            state <= S_FETCH_R; fbeat <= 0; fetch_err <= 1'b0;
          end

        S_FETCH_R:
          if (h_rvalid && h_rready) begin
            case (fbeat)
              3'd0: cmd0 <= h_rdata;
              3'd1: cmd1 <= h_rdata;
              3'd2: cmd2 <= h_rdata;
              3'd3: cmd3 <= h_rdata;
              default: ;
            endcase
            if (h_rresp != 2'b00) fetch_err <= 1'b1;
            fbeat <= fbeat + 3'd1;
            if (h_rlast) begin
              t_fetch <= cycles;
              sq_head <= (sq_head + 12'd1) & mask;
              state   <= S_EXEC;
            end
          end

        S_EXEC: begin
          if (fetch_err) begin
            status <= ST_AXI_ERROR; axi_err <= 1'b1; t_done <= cycles; state <= S_CQ_WAIT;
          end else if (opcode == OP_NOP) begin
            status <= ST_OK; t_done <= cycles; state <= S_CQ_WAIT;
          end else if (opcode == OP_COPY_H2C || opcode == OP_COPY_C2H) begin
            if (copy_ok) begin
              mv_dir <= (opcode == OP_COPY_C2H); mv_start <= 1'b1; state <= S_MOVE;
            end else begin
              status <= ST_BAD_LENGTH; t_done <= cycles; state <= S_CQ_WAIT;
            end
          end else if (opcode == OP_GEMM) begin
            if (gemm_ok) begin
              mm_start <= 1'b1; state <= S_GEMM;
            end else begin
              status <= ST_BAD_LENGTH; t_done <= cycles; state <= S_CQ_WAIT;
            end
          end else begin
            status <= ST_BAD_OPCODE; t_done <= cycles; state <= S_CQ_WAIT;
          end
        end

        S_GEMM:
          if (mm_done && !mm_start) begin
            status <= mm_err ? ST_AXI_ERROR : ST_OK;
            if (mm_err) axi_err <= 1'b1;
            t_done <= cycles;
            state  <= S_CQ_WAIT;
          end

        S_MOVE:
          if (mv_done && !mv_start) begin
            status <= mv_err ? ST_AXI_ERROR : ST_OK;
            if (mv_err) axi_err <= 1'b1;
            t_done <= cycles;
            state  <= S_CQ_WAIT;
          end

        S_CQ_WAIT:
          if (!cq_full) begin
            state <= S_CPL; cpl_aw_ok <= 1'b0; cpl_wbeat <= 0;
          end

        S_CPL: begin
          if (h_awvalid && h_awready) cpl_aw_ok <= 1'b1;
          if (h_wvalid && h_wready) cpl_wbeat <= cpl_wbeat + 2'd1;
          if ((cpl_aw_ok || (h_awvalid && h_awready)) &&
              (cpl_wbeat == 2'd2 || (cpl_wbeat == 2'd1 && h_wvalid && h_wready)))
            state <= S_CPL_B;
        end

        S_CPL_B:
          if (h_bvalid && h_bready) begin
            if (h_bresp != 2'b00) axi_err <= 1'b1;
            cq_tail   <= (cq_tail + 12'd1) & mask;
            if (cq_tail == mask) phase <= ~phase;
            completed <= completed + 32'd1;
            if (flags[0] && cfg_irq_en) msi_pending <= 1'b1;
            state <= S_IDLE;
          end

        default: state <= S_IDLE;
      endcase
    end
  end

  // Completion record, two 64-bit beats.
  wire [63:0] cpl_beat0 = {16'd0, 7'd0, phase, status, 4'd0, sq_head, cid};
  wire [63:0] cpl_beat1 = {t_done, t_fetch};

  // ---------------------------------------------------------------------------
  // Mover: streams a copy through a FIFO.
  localparam integer FIFO_LOG2 = 10;          // 1024 beats, 8 KiB
  localparam [31:0]  FIFO_BEATS = 32'd1024;
  localparam [31:0]  BURST = 32'd256;         // 2 KiB of 64-bit beats

  reg        mv_run;
  reg [31:0] mv_src, mv_dst, mv_total;        // AXI addresses, total beats
  reg [31:0] rd_issued, wr_issued, popped;    // beats
  reg [31:0] b_need, b_got;                   // write bursts
  reg        ws_busy, ws_aw_ok;
  reg [8:0]  ws_left;                         // beats left in the current write burst
  reg [8:0]  ws_len;
  reg        mv_err_r;

  wire [31:0] rd_left   = mv_total - rd_issued;
  wire [31:0] rd_len    = (rd_left < BURST) ? rd_left : BURST;
  wire [31:0] in_flight = rd_issued - popped;           // beats reserved in the FIFO
  wire        rd_can    = mv_run && (rd_issued < mv_total) && (in_flight + rd_len <= FIFO_BEATS);

  wire [31:0] wr_left   = mv_total - wr_issued;
  wire [31:0] wr_len    = (wr_left < BURST) ? wr_left : BURST;
  wire [FIFO_LOG2:0] f_count;
  wire        f_valid;
  wire [63:0] f_dout;
  wire        wr_can    = mv_run && !ws_busy && (wr_issued < mv_total) && ({21'd0, f_count} >= wr_len);

  // Generic mover channels, routed to the host or card port by mv_dir.
  wire        m_arvalid = rd_can;
  wire [31:0] m_araddr  = mv_src + {rd_issued[28:0], 3'd0};
  wire [7:0]  m_arlen   = rd_len[7:0] - 8'd1;
  wire        m_arready = mv_dir ? c_arready : h_arready;
  wire        m_rvalid  = mv_dir ? c_rvalid : h_rvalid;
  wire [63:0] m_rdata   = mv_dir ? c_rdata : h_rdata;
  wire [1:0]  m_rresp   = mv_dir ? c_rresp : h_rresp;

  wire        m_awvalid = ws_busy && !ws_aw_ok;
  wire [31:0] m_awaddr  = mv_dst + {wr_issued[28:0], 3'd0} - {20'd0, ws_len, 3'd0};
  wire [7:0]  m_awlen   = ws_len[7:0] - 8'd1;
  wire        m_awready = mv_dir ? h_awready : c_awready;
  wire        m_wvalid  = ws_busy && (ws_left != 0) && f_valid;
  wire        m_wlast   = (ws_left == 9'd1);
  wire        m_wready  = mv_dir ? h_wready : c_wready;
  wire        m_bvalid  = mv_dir ? h_bvalid : c_bvalid;
  wire [1:0]  m_bresp   = mv_dir ? h_bresp : c_bresp;

  wire r_fire = mv_run && m_rvalid;            // RREADY is high while running
  wire w_fire = m_wvalid && m_wready;

  fifo_fwft #(.WIDTH(64), .DEPTH_LOG2(FIFO_LOG2)) fifo (
    .clk (clk), .rst_n (rst_n),
    .push (r_fire), .din (m_rdata),
    .pop (w_fire), .dout (f_dout), .valid (f_valid), .count (f_count)
  );

  assign mv_done = !mv_run;
  assign mv_err  = mv_err_r;

  always @(posedge clk) begin
    if (!rst_n) begin
      mv_run <= 1'b0; mv_src <= 0; mv_dst <= 0; mv_total <= 0;
      rd_issued <= 0; wr_issued <= 0; popped <= 0; b_need <= 0; b_got <= 0;
      ws_busy <= 1'b0; ws_aw_ok <= 1'b0; ws_left <= 0; ws_len <= 0; mv_err_r <= 1'b0;
    end else if (mv_start) begin
      mv_run    <= 1'b1;
      mv_src    <= mv_dir ? caddr[31:0] : host_axi(haddr[31:0]);
      mv_dst    <= mv_dir ? host_axi(haddr[31:0]) : caddr[31:0];
      mv_total  <= {3'd0, length[31:3]};
      b_need    <= (length + 32'd2047) >> 11;
      rd_issued <= 0; wr_issued <= 0; popped <= 0; b_got <= 0;
      ws_busy <= 1'b0; ws_aw_ok <= 1'b0; ws_left <= 0; mv_err_r <= 1'b0;
    end else if (mv_run) begin
      if (m_arvalid && m_arready) rd_issued <= rd_issued + rd_len;
      if (r_fire && m_rresp != 2'b00) mv_err_r <= 1'b1;

      // Write bursts: address and data presented together once the
      // burst's data is in the FIFO.
      if (wr_can) begin
        ws_busy   <= 1'b1;
        ws_aw_ok  <= 1'b0;
        ws_len    <= wr_len[8:0];
        ws_left   <= wr_len[8:0];
        wr_issued <= wr_issued + wr_len;
      end else if (ws_busy) begin
        if (m_awvalid && m_awready) ws_aw_ok <= 1'b1;
        if (w_fire) begin
          ws_left <= ws_left - 9'd1;
          popped  <= popped + 32'd1;
        end
        if ((ws_aw_ok || (m_awvalid && m_awready)) &&
            (ws_left == 0 || (ws_left == 9'd1 && w_fire)))
          ws_busy <= 1'b0;
      end

      if (m_bvalid) begin
        b_got <= b_got + 32'd1;
        if (m_bresp != 2'b00) mv_err_r <= 1'b1;
      end

      if (b_got == b_need && wr_issued == mv_total && !ws_busy) mv_run <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Port routing. The controller owns the host port while fetching and
  // completing; the mover owns it (and the card port) while copying.
  wire fetching   = (state == S_FETCH_AR) || (state == S_FETCH_R);
  wire completing = (state == S_CPL) || (state == S_CPL_B);
  wire mv_h_rd = mv_run && !mv_dir;   // H2C reads the host
  wire mv_h_wr = mv_run &&  mv_dir;   // C2H writes the host

  // Host read: command fetch or H2C source.
  assign h_arvalid = (state == S_FETCH_AR) ? 1'b1 : (mv_h_rd && m_arvalid);
  assign h_araddr  = (state == S_FETCH_AR) ? host_axi(cfg_sq_base[31:0] + {14'd0, sq_head, 6'd0}) : m_araddr;
  assign h_arlen   = (state == S_FETCH_AR) ? 8'd7 : m_arlen;
  assign h_arsize  = 3'd3;
  assign h_arburst = 2'b01;
  assign h_rready  = (state == S_FETCH_R) || mv_h_rd;

  // Host write: completion record or C2H destination.
  assign h_awvalid = (state == S_CPL) ? !cpl_aw_ok : (mv_h_wr && m_awvalid);
  assign h_awaddr  = (state == S_CPL) ? host_axi(cfg_cq_base[31:0] + {16'd0, cq_tail, 4'd0}) : m_awaddr;
  assign h_awlen   = (state == S_CPL) ? 8'd1 : m_awlen;
  assign h_awsize  = 3'd3;
  assign h_awburst = 2'b01;
  assign h_wvalid  = (state == S_CPL) ? (cpl_wbeat != 2'd2) : (mv_h_wr && m_wvalid);
  assign h_wdata   = (state == S_CPL) ? (cpl_wbeat == 2'd0 ? cpl_beat0 : cpl_beat1) : f_dout;
  assign h_wlast   = (state == S_CPL) ? (cpl_wbeat == 2'd1) : m_wlast;
  assign h_wstrb   = 8'hFF;
  assign h_bready  = completing || mv_h_wr;

  // Matrix engine, on the card port while a GEMM runs.
  wire        gemm = (state == S_GEMM);
  wire [31:0] mm_awaddr, mm_araddr;
  wire [7:0]  mm_awlen, mm_arlen;
  wire        mm_awvalid, mm_wlast, mm_wvalid, mm_bready, mm_arvalid, mm_rready;
  wire [63:0] mm_wdata;

  npu_mm mm (
    .clk (clk), .rst_n (rst_n), .start (mm_start),
    .a_addr (cmd1[31:0]), .b_addr (cmd1[63:32]), .c_addr (cmd2[31:0]), .bias_addr (cmd2[63:32]),
    .m_rows (g_m), .k_len (g_k), .n_len (g_n),
    .shift (cmd3[36:32]), .relu (cmd3[40]), .out32 (g_out32), .mult (cmd3[63:48]),
    .done (mm_done), .err (mm_err),
    .awaddr (mm_awaddr), .awlen (mm_awlen), .awvalid (mm_awvalid), .awready (gemm && c_awready),
    .wdata (mm_wdata), .wlast (mm_wlast), .wvalid (mm_wvalid), .wready (gemm && c_wready),
    .bresp (c_bresp), .bvalid (gemm && c_bvalid), .bready (mm_bready),
    .araddr (mm_araddr), .arlen (mm_arlen), .arvalid (mm_arvalid), .arready (gemm && c_arready),
    .rdata (c_rdata), .rresp (c_rresp), .rvalid (gemm && c_rvalid), .rready (mm_rready)
  );

  // Card port: the mover's other side, or the matrix engine.
  assign c_arvalid = gemm ? mm_arvalid : (mv_run && mv_dir && m_arvalid);
  assign c_araddr  = gemm ? mm_araddr  : m_araddr;
  assign c_arlen   = gemm ? mm_arlen   : m_arlen;
  assign c_arsize  = 3'd3;
  assign c_arburst = 2'b01;
  assign c_rready  = gemm ? mm_rready  : (mv_run && mv_dir);
  assign c_awvalid = gemm ? mm_awvalid : (mv_run && !mv_dir && m_awvalid);
  assign c_awaddr  = gemm ? mm_awaddr  : m_awaddr;
  assign c_awlen   = gemm ? mm_awlen   : m_awlen;
  assign c_awsize  = 3'd3;
  assign c_awburst = 2'b01;
  assign c_wvalid  = gemm ? mm_wvalid  : (mv_run && !mv_dir && m_wvalid);
  assign c_wdata   = gemm ? mm_wdata   : f_dout;
  assign c_wlast   = gemm ? mm_wlast   : m_wlast;
  assign c_wstrb   = 8'hFF;
  assign c_bready  = gemm ? mm_bready  : (mv_run && !mv_dir);

endmodule

`default_nettype wire
