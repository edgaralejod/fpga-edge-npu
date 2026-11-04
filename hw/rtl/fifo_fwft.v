// fifo_fwft: synchronous first-word-fall-through FIFO.
//
// The head word is always on dout while valid is high; pop consumes it. The
// storage infers block RAM with a registered read, so one output register
// sits after it; a pop and a refill can happen in the same cycle, which keeps
// a full-speed AXI stream going through it. count includes the output
// register. Pushing when full or popping when empty is the caller's error.

`timescale 1ns / 1ps
`default_nettype none

module fifo_fwft #(
  parameter integer WIDTH = 64,
  parameter integer DEPTH_LOG2 = 10
) (
  input  wire                  clk,
  input  wire                  rst_n,
  input  wire                  push,
  input  wire [WIDTH-1:0]      din,
  input  wire                  pop,
  output reg  [WIDTH-1:0]      dout,
  output reg                   valid,
  output wire [DEPTH_LOG2:0]   count
);

  reg [WIDTH-1:0]      mem [0:(1 << DEPTH_LOG2) - 1];
  reg [DEPTH_LOG2:0]   wptr, rptr;   // one extra bit tells full from empty

  wire stored = (wptr != rptr);
  wire load   = stored && (!valid || pop);

  assign count = (wptr - rptr) + {{DEPTH_LOG2{1'b0}}, valid};

  always @(posedge clk) begin
    if (push) mem[wptr[DEPTH_LOG2-1:0]] <= din;
    if (load) dout <= mem[rptr[DEPTH_LOG2-1:0]];
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      wptr  <= 0;
      rptr  <= 0;
      valid <= 1'b0;
    end else begin
      if (push) wptr <= wptr + 1'b1;
      if (load) begin
        rptr  <= rptr + 1'b1;
        valid <= 1'b1;
      end else if (pop) begin
        valid <= 1'b0;
      end
    end
  end

endmodule

`default_nettype wire
