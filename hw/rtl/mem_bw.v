// mem_bw: card-side DDR3 bandwidth engine.
//
// An AXI4 master on the memory side of the interconnect (the MIG's clock and
// full 512-bit width), started and read out from npu_regs on the PCIe side.
// It measures what the memory system delivers without the PCIe link in the
// way, and its read path checks data, so it doubles as a card-side memory
// test. Its burst machinery is the starting point for the compute engine's
// data movement (roadmap phase 4).
//
//   write mode: fills [addr, addr+len) with 4 KiB INCR bursts of a pattern
//               derived from each word's address and a 16-bit seed.
//   read mode:  reads the range back and counts 64-byte beats that differ
//               from the pattern (same addr and seed as the write run).
//
// addr and len are in bytes and must be multiples of 4 KiB (the low 12 bits
// are ignored). Up to `outstanding` bursts (1..16; 0 means 16) are in flight
// at once. Results: memory-clock cycles from start to the last response,
// mismatched beats, and responses other than OKAY.
//
// Clock crossing: the ctl_* side runs on the PCIe user clock. ctl_start flips
// a toggle that the memory side synchronizes; the memory side then captures
// the settings, which the control side holds steady while busy. Completion
// flips a toggle back; the control side then captures the results, which the
// memory side holds steady until the next start. The two capture points are
// constrained as false paths in hw/constr/ac701.xdc.

`timescale 1ns / 1ps
`default_nettype none

module mem_bw (
  // Control, PCIe user clock domain
  input  wire         ctl_clk,
  input  wire         ctl_rst_n,
  input  wire         ctl_start,        // one-cycle pulse; ignored while busy
  input  wire         ctl_read,         // 0: write pattern, 1: read and check
  input  wire [31:0]  ctl_addr,
  input  wire [31:0]  ctl_len,
  input  wire [4:0]   ctl_outstanding,
  input  wire [15:0]  ctl_seed,
  output reg          ctl_busy,
  output reg  [31:0]  ctl_cycles,
  output reg  [31:0]  ctl_mismatches,
  output reg  [31:0]  ctl_errors,
  output reg  [31:0]  ctl_runs,         // completed runs, so the host can tell old results from new

  // AXI4 master, memory clock domain
  input  wire         m_clk,
  input  wire         m_rst_n,
  output wire [31:0]  m_axi_awaddr,
  output wire [7:0]   m_axi_awlen,
  output wire [2:0]   m_axi_awsize,
  output wire [1:0]   m_axi_awburst,
  output wire [3:0]   m_axi_awcache,
  output wire [2:0]   m_axi_awprot,
  output wire         m_axi_awlock,
  output wire         m_axi_awvalid,
  input  wire         m_axi_awready,
  output wire [511:0] m_axi_wdata,
  output wire [63:0]  m_axi_wstrb,
  output wire         m_axi_wlast,
  output wire         m_axi_wvalid,
  input  wire         m_axi_wready,
  input  wire [1:0]   m_axi_bresp,
  input  wire         m_axi_bvalid,
  output wire         m_axi_bready,
  output wire [31:0]  m_axi_araddr,
  output wire [7:0]   m_axi_arlen,
  output wire [2:0]   m_axi_arsize,
  output wire [1:0]   m_axi_arburst,
  output wire [3:0]   m_axi_arcache,
  output wire [2:0]   m_axi_arprot,
  output wire         m_axi_arlock,
  output wire         m_axi_arvalid,
  input  wire         m_axi_arready,
  input  wire [511:0] m_axi_rdata,
  input  wire [1:0]   m_axi_rresp,
  input  wire         m_axi_rlast,
  input  wire         m_axi_rvalid,
  output wire         m_axi_rready
);

  localparam BEATS = 64;   // 64 beats x 64 bytes = one 4 KiB burst

  // Pattern for the 64-byte beat at byte address a: word i holds its own
  // byte address (the low six bits of a are zero, so no adder is needed),
  // mixed with the seed so that a stale earlier run cannot pass the check.
  function [511:0] pattern(input [31:0] a, input [15:0] seed);
    integer i;
    reg [3:0] k;
    begin
      for (i = 0; i < 16; i = i + 1) begin
        k = i;
        pattern[i*32 +: 32] = {a[31:6], k, 2'b00} ^ {seed, ~seed};
      end
    end
  endfunction

  // Crossing points between the two sides.
  reg        ctl_start_tgl;                          // control -> memory
  reg        m_done_tgl;                             // memory -> control
  reg [31:0] m_cycles, m_mismatches, m_errors;       // held while not running

  // ---------------------------------------------------------------------------
  // Control side
  (* ASYNC_REG = "TRUE" *) reg [2:0] ctl_done_sync;

  always @(posedge ctl_clk) begin
    if (!ctl_rst_n) begin
      ctl_start_tgl  <= 1'b0;
      ctl_done_sync  <= 3'd0;
      ctl_busy       <= 1'b0;
      ctl_cycles     <= 32'd0;
      ctl_mismatches <= 32'd0;
      ctl_errors     <= 32'd0;
      ctl_runs       <= 32'd0;
    end else begin
      ctl_done_sync <= {ctl_done_sync[1:0], m_done_tgl};
      if (ctl_start && !ctl_busy) begin
        ctl_start_tgl <= ~ctl_start_tgl;
        ctl_busy      <= 1'b1;
      end
      if (ctl_done_sync[2] != ctl_done_sync[1]) begin
        // m_* results have been stable since before the toggle.
        ctl_cycles     <= m_cycles;
        ctl_mismatches <= m_mismatches;
        ctl_errors     <= m_errors;
        ctl_runs       <= ctl_runs + 32'd1;
        ctl_busy       <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Memory side
  (* ASYNC_REG = "TRUE" *) reg [2:0] m_start_sync;
  reg        m_run, m_read;
  reg [31:0] m_base;
  reg [19:0] m_total;          // bursts in the run (1 GiB / 4 KiB = 2^18)
  reg [4:0]  m_window;         // max bursts in flight
  reg [15:0] m_seed;
  reg [19:0] m_issued;         // AW or AR handshakes
  reg [19:0] m_done_bursts;    // B responses, or R bursts with RLAST
  reg [19:0] m_wburst;         // write bursts whose data has been sent
  reg [5:0]  m_wbeat;
  reg [25:0] m_rbeat;          // read beats received, for the expected address

  wire [19:0] in_flight = m_issued - m_done_bursts;
  wire        can_issue = m_run && (m_issued < m_total) && (in_flight < {15'd0, m_window});

  always @(posedge m_clk) begin
    if (!m_rst_n) begin
      m_start_sync <= 3'd0;
      m_done_tgl   <= 1'b0;
      m_run        <= 1'b0;
      m_read       <= 1'b0;
      m_base       <= 32'd0;
      m_total      <= 20'd0;
      m_window     <= 5'd16;
      m_seed       <= 16'd0;
      m_issued     <= 20'd0;
      m_done_bursts <= 20'd0;
      m_wburst     <= 20'd0;
      m_wbeat      <= 6'd0;
      m_rbeat      <= 26'd0;
      m_cycles     <= 32'd0;
      m_mismatches <= 32'd0;
      m_errors     <= 32'd0;
    end else begin
      m_start_sync <= {m_start_sync[1:0], ctl_start_tgl};

      if (!m_run && (m_start_sync[2] != m_start_sync[1])) begin
        // ctl_* settings are held steady while the control side is busy.
        m_run         <= 1'b1;
        m_read        <= ctl_read;
        m_base        <= {ctl_addr[31:12], 12'd0};
        m_total       <= ctl_len[31:12];
        m_window      <= (ctl_outstanding == 5'd0 || ctl_outstanding > 5'd16) ? 5'd16 : ctl_outstanding;
        m_seed        <= ctl_seed;
        m_issued      <= 20'd0;
        m_done_bursts <= 20'd0;
        m_wburst      <= 20'd0;
        m_wbeat       <= 6'd0;
        m_rbeat       <= 26'd0;
        m_cycles      <= 32'd0;
        m_mismatches  <= 32'd0;
        m_errors      <= 32'd0;
      end else if (m_run) begin
        m_cycles <= m_cycles + 32'd1;

        if ((m_axi_awvalid && m_axi_awready) || (m_axi_arvalid && m_axi_arready))
          m_issued <= m_issued + 20'd1;

        if (m_axi_wvalid && m_axi_wready) begin
          m_wbeat <= m_wbeat + 6'd1;
          if (m_axi_wlast) m_wburst <= m_wburst + 20'd1;
        end

        if (m_axi_bvalid && m_axi_bready) begin
          m_done_bursts <= m_done_bursts + 20'd1;
          if (m_axi_bresp != 2'b00) m_errors <= m_errors + 32'd1;
        end

        if (m_axi_rvalid && m_axi_rready) begin
          m_rbeat <= m_rbeat + 26'd1;
          if (m_axi_rlast) m_done_bursts <= m_done_bursts + 20'd1;
          if (m_axi_rresp != 2'b00) m_errors <= m_errors + 32'd1;
          if (m_axi_rdata != pattern(m_base + {m_rbeat, 6'd0}, m_seed))
            m_mismatches <= m_mismatches + 32'd1;
        end

        // Finished when every burst has its response.
        if (m_done_bursts == m_total) begin
          m_run      <= 1'b0;
          m_done_tgl <= ~m_done_tgl;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // AXI4 master, checked against AMD's AXI4 master template (Vivado 2025.2,
  // regenerated by hw/scripts/axil_template.tcl). VALIDs depend only on
  // counters that move towards keeping them asserted, never on READY, so a
  // VALID once raised stays up, with its payload, until its handshake.
  //
  // Write data for a burst may go out while its address is still waiting:
  // AXI (A3.3.1) forbids a master from waiting for AWREADY before WVALID,
  // because a slave may wait for WVALID before raising AWREADY. Data never
  // runs ahead of the address being presented.
  assign m_axi_awaddr  = m_base + {m_issued[19:0], 12'd0};
  assign m_axi_awlen   = BEATS - 1;
  assign m_axi_awsize  = 3'd6;             // 64 bytes per beat
  assign m_axi_awburst = 2'b01;            // INCR
  assign m_axi_awcache = 4'b0010;          // normal, non-cacheable, modifiable (as the template)
  assign m_axi_awprot  = 3'b000;
  assign m_axi_awlock  = 1'b0;
  assign m_axi_awvalid = can_issue && !m_read;

  assign m_axi_wdata   = pattern(m_base + {m_wburst, m_wbeat, 6'd0}, m_seed);
  assign m_axi_wstrb   = {64{1'b1}};
  assign m_axi_wlast   = (m_wbeat == BEATS - 1);
  assign m_axi_wvalid  = m_run && !m_read &&
                         ((m_wburst < m_issued) || (m_wburst == m_issued && m_axi_awvalid));
  assign m_axi_bready  = 1'b1;

  assign m_axi_araddr  = m_base + {m_issued[19:0], 12'd0};
  assign m_axi_arlen   = BEATS - 1;
  assign m_axi_arsize  = 3'd6;
  assign m_axi_arburst = 2'b01;
  assign m_axi_arcache = 4'b0010;
  assign m_axi_arprot  = 3'b000;
  assign m_axi_arlock  = 1'b0;
  assign m_axi_arvalid = can_issue && m_read;
  assign m_axi_rready  = 1'b1;

endmodule

`default_nettype wire
