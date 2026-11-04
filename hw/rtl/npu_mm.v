// npu_mm: INT8 matrix-multiply engine (roadmap phase 4, first version).
//
// Computes, for every row m of A and every row n of Bt (B stored transposed):
//
//   acc[m][n] = sum_k A[m][k] * Bt[n][k] + bias[n]        INT8 x INT8, INT32
//   C[m][n]   = acc                                         if out32
//             = clamp(relu?((acc * mult + 2^(shift-1)) >> shift))   INT8 otherwise
//
// with an arithmetic shift, rounding half up, ReLU when `relu` is set, and a
// clamp to [-128, 127]. sw/npu/npu_ref.py implements the same arithmetic in
// Python; the two must agree bit for bit.
//
// Data lives in card memory, all addresses 64-byte aligned, rows packed:
// A is M x K bytes, Bt is N x K bytes, bias is N INT32 words, C is M x N bytes
// (or M x N INT32 words with out32). K is a multiple of 64 up to 2048, N a
// multiple of 64 up to 1024. npu_cq checks these before starting.
//
// For each output row the engine loads A's row into block RAM, then streams
// all of Bt past it at one 64-bit beat (8 MACs) per cycle, finishing one
// output every K/8 beats through a five-stage pipeline, and writes the row
// out. Reads are 64-byte bursts (never crossing 4 KiB), up to 16 in flight;
// writes present address and data together, as the AXI rules require.

`timescale 1ns / 1ps
`default_nettype none

module npu_mm (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        start,
  input  wire [31:0] a_addr, b_addr, c_addr, bias_addr,
  input  wire [31:0] m_rows,
  input  wire [15:0] k_len,
  input  wire [15:0] n_len,
  input  wire [4:0]  shift,
  input  wire        relu,
  input  wire        out32,
  input  wire [15:0] mult,
  output wire        done,
  output reg         err,

  output wire [31:0] awaddr,  output wire [7:0] awlen,  output wire        awvalid, input wire awready,
  output wire [63:0] wdata,   output wire       wlast,  output wire        wvalid,  input wire wready,
  input  wire [1:0]  bresp,   input  wire       bvalid, output wire        bready,
  output wire [31:0] araddr,  output wire [7:0] arlen,  output wire        arvalid, input wire arready,
  input  wire [63:0] rdata,   input  wire [1:0] rresp,  input  wire        rvalid,  output wire rready
);

  localparam [2:0] ST_IDLE = 3'd0, ST_BIAS = 3'd1, ST_A = 3'd2, ST_B = 3'd3,
                   ST_DRAIN = 3'd4, ST_C = 3'd5, ST_CB = 3'd6;
  reg [2:0] st;
  assign done = (st == ST_IDLE);

  // Command, captured at start
  reg [31:0] ra, rb, rc, rbias, rm;
  reg [15:0] rk, rn, rmult;
  reg [4:0]  rshift;
  reg        rrelu, rout32;
  wire [8:0]  kw      = rk[11:3];                    // A row in 64-bit words (K/8, up to 256)
  wire [31:0] c_row_b = rout32 ? {14'd0, rn, 2'd0} : {16'd0, rn};   // bytes per C row
  reg  [31:0] m_idx;

  // ---------------------------------------------------------------------------
  // Read side: one region per phase (bias, an A row, all of Bt), 8-beat bursts.
  reg  [31:0] rd_base, rd_total, ar_cnt, r_cnt;
  wire        rd_phase = (st == ST_BIAS) || (st == ST_A) || (st == ST_B);
  assign arvalid = rd_phase && (ar_cnt < rd_total) && (ar_cnt - r_cnt < 32'd128);
  assign araddr  = rd_base + {ar_cnt[28:0], 3'd0};
  assign arlen   = 8'd7;
  assign rready  = rd_phase;
  wire   r_fire  = rvalid && rready;

  // ---------------------------------------------------------------------------
  // Buffers
  reg  [63:0] abuf [0:255];                // A row
  reg  [31:0] biasm [0:1023];              // bias vector
  reg  [7:0]  ob0 [0:511], ob1 [0:511], ob2 [0:511], ob3 [0:511],   // C row, one array per
              ob4 [0:511], ob5 [0:511], ob6 [0:511], ob7 [0:511];   // byte lane of a 64-bit word

  // ---------------------------------------------------------------------------
  // Dot-product pipeline (ST_B)
  reg  [8:0]  j;           // beat within the current Bt row
  reg  [9:0]  n;           // current Bt row
  reg  [63:0] a_q, b_q;
  reg         v1, first1, last1;  reg [9:0] n1;
  reg  signed [19:0] p2;   reg v2, first2, last2;  reg [9:0] n2;
  reg  signed [31:0] acc;
  reg         v3; reg [9:0] n3; reg signed [31:0] acc3;
  reg  signed [31:0] bias_q;
  reg         v4; reg [9:0] n4; reg signed [31:0] sum4;
  reg  signed [48:0] prod5; reg v5; reg [9:0] n5; reg signed [31:0] sum5;
  wire        pipe_busy = v1 | v2 | v3 | v4 | v5;

  function signed [19:0] dot8(input [63:0] a, input [63:0] b);
    integer i;
    reg signed [19:0] s;
    begin
      s = 0;
      for (i = 0; i < 8; i = i + 1)
        s = s + $signed(a[i*8 +: 8]) * $signed(b[i*8 +: 8]);
      dot8 = s;
    end
  endfunction

  // Requantize a scaled product to INT8.
  function [7:0] requant(input signed [48:0] p, input [4:0] sh, input rl);
    reg signed [48:0] r;
    begin
      r = (sh == 0) ? p : ((p + (49'sd1 <<< (sh - 1))) >>> sh);
      if (rl && r < 0) r = 0;
      if (r > 127) r = 127;
      if (r < -128) r = -128;
      requant = r[7:0];
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Write side (ST_C): 8-beat bursts of the C row, address and data together.
  // Addresses and data are counted separately: every burst's address goes out
  // in order and holds until accepted; a burst's data may flow while its
  // address is presented or after, never before.
  reg  [8:0]  w_idx;           // word of the C row being sent
  reg  [8:0]  w_total;         // words in the C row (a multiple of 8)
  reg  [5:0]  aw_b;            // write bursts whose address was accepted
  reg         w_primed;
  reg  [31:0] b_need, b_got;
  reg  [63:0] ob_q;
  wire [5:0]  n_bursts = w_total[8:3];
  wire [5:0]  w_b      = w_idx[8:3];
  wire [8:0]  ob_addr  = (wvalid && wready) ? w_idx + 9'd1 : w_idx;
  assign awvalid = (st == ST_C) && (aw_b < n_bursts);
  assign awaddr  = rc + m_idx * c_row_b + {20'd0, aw_b, 6'd0};
  assign awlen   = 8'd7;
  assign wvalid  = (st == ST_C) && w_primed && (w_idx < w_total) && (w_b <= aw_b);
  assign wdata   = ob_q;
  assign wlast   = (w_idx[2:0] == 3'd7);
  assign bready  = 1'b1;

  always @(posedge clk) begin
    ob_q <= {ob7[ob_addr], ob6[ob_addr], ob5[ob_addr], ob4[ob_addr],
             ob3[ob_addr], ob2[ob_addr], ob1[ob_addr], ob0[ob_addr]};
  end

  // Buffer writes
  always @(posedge clk) begin
    if (r_fire && st == ST_BIAS) begin
      biasm[{r_cnt[8:0], 1'b0}] <= rdata[31:0];
      biasm[{r_cnt[8:0], 1'b1}] <= rdata[63:32];
    end
    if (r_fire && st == ST_A) abuf[r_cnt[7:0]] <= rdata;
    if (v5) begin
      if (rout32) begin
        if (n5[0]) begin ob4[n5[9:1]] <= sum5[7:0]; ob5[n5[9:1]] <= sum5[15:8]; ob6[n5[9:1]] <= sum5[23:16]; ob7[n5[9:1]] <= sum5[31:24]; end
        else       begin ob0[n5[9:1]] <= sum5[7:0]; ob1[n5[9:1]] <= sum5[15:8]; ob2[n5[9:1]] <= sum5[23:16]; ob3[n5[9:1]] <= sum5[31:24]; end
      end else begin
        case (n5[2:0])
          3'd0: ob0[{2'd0, n5[9:3]}] <= requant(prod5, rshift, rrelu);
          3'd1: ob1[{2'd0, n5[9:3]}] <= requant(prod5, rshift, rrelu);
          3'd2: ob2[{2'd0, n5[9:3]}] <= requant(prod5, rshift, rrelu);
          3'd3: ob3[{2'd0, n5[9:3]}] <= requant(prod5, rshift, rrelu);
          3'd4: ob4[{2'd0, n5[9:3]}] <= requant(prod5, rshift, rrelu);
          3'd5: ob5[{2'd0, n5[9:3]}] <= requant(prod5, rshift, rrelu);
          3'd6: ob6[{2'd0, n5[9:3]}] <= requant(prod5, rshift, rrelu);
          default: ob7[{2'd0, n5[9:3]}] <= requant(prod5, rshift, rrelu);
        endcase
      end
    end
  end

  // Pipeline
  always @(posedge clk) begin
    // Stage 1: an A word and a Bt beat
    v1 <= 1'b0;
    if (r_fire && st == ST_B) begin
      a_q <= abuf[j[7:0]];
      b_q <= rdata;
      v1 <= 1'b1; first1 <= (j == 0); last1 <= (j == kw - 9'd1); n1 <= n;
    end
    // Stage 2: eight products, summed
    v2 <= v1; first2 <= first1; last2 <= last1; n2 <= n1;
    p2 <= dot8(a_q, b_q);
    // Stage 3: accumulate; finish an output at the row's last beat
    v3 <= 1'b0;
    if (v2) begin
      acc <= first2 ? {{12{p2[19]}}, p2} : acc + {{12{p2[19]}}, p2};
      if (last2) begin
        v3 <= 1'b1; n3 <= n2;
        acc3 <= first2 ? {{12{p2[19]}}, p2} : acc + {{12{p2[19]}}, p2};
      end
    end
    bias_q <= biasm[n2];
    // Stage 4: bias
    v4 <= v3; n4 <= n3;
    sum4 <= acc3 + bias_q;
    // Stage 5: scale
    v5 <= v4; n5 <= n4; sum5 <= sum4;
    prod5 <= sum4 * $signed({1'b0, rmult});
    if (!rst_n) begin v1 <= 0; v2 <= 0; v3 <= 0; v4 <= 0; v5 <= 0; end
  end

  // ---------------------------------------------------------------------------
  // Sequencer
  task start_read(input [31:0] base, input [31:0] beats);
    begin rd_base <= base; rd_total <= beats; ar_cnt <= 0; r_cnt <= 0; end
  endtask

  always @(posedge clk) begin
    if (!rst_n) begin
      st <= ST_IDLE; err <= 1'b0; m_idx <= 0;
      rd_base <= 0; rd_total <= 0; ar_cnt <= 0; r_cnt <= 0;
      j <= 0; n <= 0; w_idx <= 0; w_total <= 0; w_primed <= 0; aw_b <= 0; b_need <= 0; b_got <= 0;
    end else begin
      if (arvalid && arready) ar_cnt <= ar_cnt + 32'd8;
      if (r_fire) begin
        r_cnt <= r_cnt + 32'd1;
        if (rresp != 2'b00) err <= 1'b1;
      end
      if (bvalid && bready) begin
        b_got <= b_got + 32'd1;
        if (bresp != 2'b00) err <= 1'b1;
      end

      case (st)
        ST_IDLE:
          if (start) begin
            ra <= a_addr; rb <= b_addr; rc <= c_addr; rbias <= bias_addr; rm <= m_rows;
            rk <= k_len; rn <= n_len; rshift <= shift; rrelu <= relu; rout32 <= out32; rmult <= mult;
            err <= 1'b0; m_idx <= 0; b_got <= 0; b_need <= 0;
            start_read(bias_addr, {17'd0, n_len[15:1]});        // N int32 = N/2 beats
            st <= ST_BIAS;
          end

        ST_BIAS:
          if (r_cnt == rd_total) begin
            start_read(ra, {23'd0, kw});
            st <= ST_A;
          end

        ST_A:
          if (r_cnt == rd_total) begin
            start_read(rb, {16'd0, rn} * {23'd0, kw});            // all of Bt
            j <= 0; n <= 0;
            st <= ST_B;
          end

        ST_B: begin
          if (r_fire) begin
            if (j == kw - 9'd1) begin j <= 0; n <= n + 10'd1; end
            else j <= j + 9'd1;
          end
          if (r_cnt == rd_total) st <= ST_DRAIN;
        end

        ST_DRAIN:
          if (!pipe_busy) begin
            w_idx <= 0; w_primed <= 1'b0; aw_b <= 0;
            w_total <= rout32 ? rn[9:1] : {3'd0, rn[9:3]};
            b_need <= b_need + (rout32 ? {26'd0, rn[9:4]} : {28'd0, rn[9:6]});   // 64-byte bursts
            st <= ST_C;
          end

        ST_C: begin
          w_primed <= 1'b1;                       // ob_q holds word 0 after one cycle
          if (awvalid && awready) aw_b <= aw_b + 6'd1;
          if (wvalid && wready) w_idx <= w_idx + 9'd1;
          if (w_idx == w_total && aw_b == n_bursts) st <= ST_CB;
        end

        ST_CB:
          if (b_got == b_need) begin
            if (m_idx + 32'd1 == rm) st <= ST_IDLE;
            else begin
              m_idx <= m_idx + 32'd1;
              start_read(ra + (m_idx + 32'd1) * {16'd0, rk}, {23'd0, kw});
              st <= ST_A;
            end
          end

        default: st <= ST_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
