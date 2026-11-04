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
// output every K/8 beats through a nine-stage pipeline (operands, products,
// two adder levels, accumulate, bias, scale, round, shift, clamp), and writes
// the row out. Every stage fits the 125 MHz clock. Reads are 64-byte bursts (never crossing 4 KiB), up to 16 in flight;
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
  reg  [31:0] a_row, c_row;                        // card addresses of the current rows
  reg  [31:0] b_beats;                             // N x K/8

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
  reg  [63:0] biasw [0:511];               // bias vector, two INT32 per word
  reg  [7:0]  ob0 [0:511], ob1 [0:511], ob2 [0:511], ob3 [0:511],   // C row, one array per
              ob4 [0:511], ob5 [0:511], ob6 [0:511], ob7 [0:511];   // byte lane of a 64-bit word

  // ---------------------------------------------------------------------------
  // Dot-product pipeline (ST_B). Valid, first/last-beat and output-index
  // flags travel with the data through every stage.
  reg  [8:0]  j;           // beat within the current Bt row
  reg  [9:0]  n;           // current Bt row
  reg  [63:0] a_q, b_q;                         reg v1, f1, l1; reg [9:0] n1;
  (* use_dsp = "yes" *) reg signed [15:0] pr [0:7];  reg v2, f2, l2; reg [9:0] n2;
  reg  signed [17:0] sa, sb;                    reg v3, f3, l3; reg [9:0] n3;
  reg  signed [18:0] dsum;                      reg v4, f4, l4; reg [9:0] n4;
  reg  signed [31:0] acc;
  reg  signed [31:0] acc5;                      reg v5; reg [9:0] n5;
  reg  [63:0] bias_w;                           // read in stage 5, used in 6
  reg  signed [31:0] sum6;                      reg v6; reg [9:0] n6;
  reg  signed [48:0] prod7;                     reg v7; reg [9:0] n7; reg signed [31:0] sum7;
  reg  signed [48:0] rnd8;                      reg v8; reg [9:0] n8; reg signed [31:0] sum8;
  reg  signed [48:0] shf9;                      reg v9; reg [9:0] n9; reg signed [31:0] sum9;
  wire        pipe_busy = v1 | v2 | v3 | v4 | v5 | v6 | v7 | v8 | v9;

  function [7:0] clamp8(input signed [48:0] r, input rl);
    reg signed [48:0] t;
    begin
      t = (rl && r < 0) ? 49'sd0 : r;
      if (t > 127) t = 127;
      if (t < -128) t = -128;
      clamp8 = t[7:0];
    end
  endfunction
  wire [7:0] q9 = clamp8(shf9, rrelu);

  // ---------------------------------------------------------------------------
  // Write side (ST_C): 8-beat bursts of the C row, address and data together.
  // Addresses and data are counted separately: every burst's address goes out
  // in order and holds until accepted; a burst's data may flow while its
  // address is presented or after, never before.
  reg  [9:0]  w_idx;           // word of the C row being sent
  reg  [9:0]  w_total;         // words in the C row (a multiple of 8, up to 512)
  reg  [6:0]  aw_b;            // write bursts whose address was accepted
  reg         w_primed;
  reg  [31:0] b_need, b_got;
  reg  [63:0] ob_q;
  wire [6:0]  n_bursts = w_total[9:3];
  wire [6:0]  w_b      = w_idx[9:3];
  wire [9:0]  ob_next  = (wvalid && wready) ? w_idx + 10'd1 : w_idx;
  wire [8:0]  ob_addr  = ob_next[8:0];
  assign awvalid = (st == ST_C) && (aw_b < n_bursts);
  assign awaddr  = c_row + {19'd0, aw_b, 6'd0};
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
    if (r_fire && st == ST_BIAS) biasw[r_cnt[8:0]] <= rdata;
    if (r_fire && st == ST_A) abuf[r_cnt[7:0]] <= rdata;
    if (v9) begin
      if (rout32) begin
        if (n9[0]) begin ob4[n9[9:1]] <= sum9[7:0]; ob5[n9[9:1]] <= sum9[15:8]; ob6[n9[9:1]] <= sum9[23:16]; ob7[n9[9:1]] <= sum9[31:24]; end
        else       begin ob0[n9[9:1]] <= sum9[7:0]; ob1[n9[9:1]] <= sum9[15:8]; ob2[n9[9:1]] <= sum9[23:16]; ob3[n9[9:1]] <= sum9[31:24]; end
      end else begin
        case (n9[2:0])
          3'd0: ob0[{2'd0, n9[9:3]}] <= q9;
          3'd1: ob1[{2'd0, n9[9:3]}] <= q9;
          3'd2: ob2[{2'd0, n9[9:3]}] <= q9;
          3'd3: ob3[{2'd0, n9[9:3]}] <= q9;
          3'd4: ob4[{2'd0, n9[9:3]}] <= q9;
          3'd5: ob5[{2'd0, n9[9:3]}] <= q9;
          3'd6: ob6[{2'd0, n9[9:3]}] <= q9;
          default: ob7[{2'd0, n9[9:3]}] <= q9;
        endcase
      end
    end
  end

  // Pipeline
  integer pi;
  always @(posedge clk) begin
    // 1: an A word and a Bt beat
    v1 <= 1'b0;
    if (r_fire && st == ST_B) begin
      a_q <= abuf[j[7:0]];
      b_q <= rdata;
      v1 <= 1'b1; f1 <= (j == 0); l1 <= (j == kw - 9'd1); n1 <= n;
    end
    // 2: eight products
    for (pi = 0; pi < 8; pi = pi + 1)
      pr[pi] <= $signed(a_q[pi*8 +: 8]) * $signed(b_q[pi*8 +: 8]);
    v2 <= v1; f2 <= f1; l2 <= l1; n2 <= n1;
    // 3, 4: adder tree
    sa <= pr[0] + pr[1] + pr[2] + pr[3];
    sb <= pr[4] + pr[5] + pr[6] + pr[7];
    v3 <= v2; f3 <= f2; l3 <= l2; n3 <= n2;
    dsum <= sa + sb;
    v4 <= v3; f4 <= f3; l4 <= l3; n4 <= n3;
    // 5: accumulate; an output is finished at its row's last beat
    v5 <= 1'b0;
    if (v4) begin
      acc <= f4 ? {{13{dsum[18]}}, dsum} : acc + {{13{dsum[18]}}, dsum};
      if (l4) begin
        v5 <= 1'b1; n5 <= n4;
        acc5 <= f4 ? {{13{dsum[18]}}, dsum} : acc + {{13{dsum[18]}}, dsum};
      end
    end
    bias_w <= biasw[n4[9:1]];
    // 6: bias
    v6 <= v5; n6 <= n5;
    sum6 <= acc5 + $signed(n5[0] ? bias_w[63:32] : bias_w[31:0]);
    // 7: scale
    v7 <= v6; n7 <= n6; sum7 <= sum6;
    prod7 <= sum6 * $signed({1'b0, rmult});
    // 8: add the rounding term
    v8 <= v7; n8 <= n7; sum8 <= sum7;
    rnd8 <= (rshift == 0) ? prod7 : prod7 + (49'sd1 <<< (rshift - 5'd1));
    // 9: arithmetic shift; clamp and buffer write follow (q9)
    v9 <= v8; n9 <= n8; sum9 <= sum8;
    shf9 <= rnd8 >>> rshift;
    if (!rst_n) begin v1 <= 0; v2 <= 0; v3 <= 0; v4 <= 0; v5 <= 0; v6 <= 0; v7 <= 0; v8 <= 0; v9 <= 0; end
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
            a_row <= a_addr; c_row <= c_addr;
            b_beats <= {16'd0, n_len} * {23'd0, k_len[11:3]};
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
            start_read(rb, b_beats);                               // all of Bt
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
            // N is up to 1024: 11 bits (rn[9:0] alone is 0 for N = 1024)
            w_total <= rout32 ? rn[10:1] : {2'd0, rn[10:3]};
            b_need <= b_need + (rout32 ? {25'd0, rn[10:4]} : {27'd0, rn[10:6]});   // 64-byte bursts
            st <= ST_C;
          end

        ST_C: begin
          w_primed <= 1'b1;                       // ob_q holds word 0 after one cycle
          if (awvalid && awready) aw_b <= aw_b + 7'd1;
          if (wvalid && wready) w_idx <= w_idx + 10'd1;
          if (w_idx == w_total && aw_b == n_bursts) st <= ST_CB;
        end

        ST_CB:
          if (b_got == b_need) begin
            if (m_idx + 32'd1 == rm) st <= ST_IDLE;
            else begin
              m_idx <= m_idx + 32'd1;
              a_row <= a_row + {16'd0, rk};
              c_row <= c_row + c_row_b;
              start_read(a_row + {16'd0, rk}, {23'd0, kw});
              st <= ST_A;
            end
          end

        default: st <= ST_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
