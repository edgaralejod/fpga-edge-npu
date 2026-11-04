// axi_dma_mon: counts the DMA engine's AXI traffic toward card memory.
//
// Watches an AXI4 master into card memory without touching it: XDMA's in
// phases 1 and 2, npu_cq's card port (copies and GEMM) since phase 3. The
// counts appear in
// npu_regs (DMA_WRITES, DMA_READS, DMA_ERRORS), so the host can tell whether
// a DMA reached the card's memory system at all, and whether the memory
// system answered with an error, before anyone opens the ILA.
//
// writes, reads: accepted write and read bursts (AW and AR handshakes).
// errors:        responses other than OKAY: one per write response, one per
//                read beat. Counters wrap; the host takes differences.

`timescale 1ns / 1ps
`default_nettype none

module axi_dma_mon (
  input  wire        clk,
  input  wire        rst_n,

  input  wire        awvalid,
  input  wire        awready,
  input  wire        arvalid,
  input  wire        arready,
  input  wire        bvalid,
  input  wire        bready,
  input  wire [1:0]  bresp,
  input  wire        rvalid,
  input  wire        rready,
  input  wire [1:0]  rresp,

  output reg  [31:0] writes,
  output reg  [31:0] reads,
  output reg  [31:0] errors
);

  wire b_err = bvalid && bready && (bresp != 2'b00);
  wire r_err = rvalid && rready && (rresp != 2'b00);

  always @(posedge clk) begin
    if (!rst_n) begin
      writes <= 32'd0;
      reads  <= 32'd0;
      errors <= 32'd0;
    end else begin
      if (awvalid && awready) writes <= writes + 32'd1;
      if (arvalid && arready) reads  <= reads + 32'd1;
      errors <= errors + {31'd0, b_err} + {31'd0, r_err};
    end
  end

endmodule

`default_nettype wire
