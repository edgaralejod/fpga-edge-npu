# Architecture

This document describes the boundaries that exist today and the decisions behind them. Planned work is in the [roadmap](ROADMAP.md); the [background](docs/edge-ai-accelerators.md) explains the products this design learns from.

## Product decision

Build a PCIe accelerator card the way commercial edge-AI modules are built, with an FPGA standing in for the ASIC, and keep every layer open. Reuse AMD's PCIe DMA core (XDMA) and AMD's reference Linux driver for the transport, so effort goes into the parts that make an accelerator: the control interface, the on-card memory system, the compute engine, the compiler and the runtime. Replace a reused part only when it blocks something the project needs to show, and say why.

The host side targets embedded Linux on an NXP i.MX95, the class of host that discrete NPUs are sold for. Nothing in the card is specific to that host; any PCIe Linux machine with the XDMA driver can drive it.

## Implemented layers

| Layer | Implementation | Boundary |
| --- | --- | --- |
| Physical link | AC701 x4 edge connector, M.2 Key-M adapter, FRDM-i.MX95 PCIe 3.0 x1 | Trains at Gen2 x1; the slower end sets the speed. |
| PCIe endpoint | XDMA (AMD PG195), `hw/scripts/ip.tcl` | Configuration space, BARs, MSI, the DMA engine. Generated at build time, never edited. |
| Control plane | `hw/rtl/npu_regs.v` on BAR0 | Every host-visible control and status bit of the card. Single-beat AXI-Lite, 125 MHz, on AMD's AXI4-Lite slave template (`hw/scripts/axil_template.tcl` regenerates it). [Register map](docs/register-map.md). |
| Data plane | XDMA H2C/C2H channels into the `card_mem` block design (`hw/bd/card_mem.tcl`): SmartConnect, MIG, DDR3 SODIMM | Bulk data between host memory and card memory: 1 GiB of DDR3 at AXI address 0 (800 MT/s, 64 bits). SmartConnect converts XDMA's 64-bit, 125 MHz AXI to the MIG's 512-bit, 100 MHz port. Phase 1 used 64 KiB of BRAM. |
| Top level | `hw/rtl/npu_top.v` | Wires the parts; owns clocks, resets and LEDs, including the debug clock. No logic of its own beyond the heartbeat and the DMA counters (`axi_dma_mon`). |
| Card-side memory engine | `hw/rtl/mem_bw.v`, a third master on the SmartConnect, in the MIG clock domain | 512-bit AXI4 bursts (4 KiB, up to 16 in flight) that measure DDR3 bandwidth without the PCIe link and check the data they read back. Controlled from BAR0 (`BW_*`); the start of the compute engine's data movement. |
| Debug | System ILAs, VIO and JTAG-to-AXI in `card_mem`; DMA counters and DDR status in BAR0 | Every memory-system problem can be seen from the host's registers, from Vivado over JTAG, or as AXI waveforms. [Debugging](docs/debugging.md). |
| Host driver | Xilinx `dma_ip_drivers` XDMA, unmodified | Owns BAR1 and the descriptor rings; exposes `/dev/xdma0_*`. |
| Host tool | `sw/tools/npu-ctl.c` | Bring-up and measurement: registers, latency, DMA loopback. Not the runtime. |

```mermaid
flowchart LR
    APP[npu-ctl / later: runtime] --> DRV[XDMA driver]
    APP -->|mmap BAR0| REGS
    DRV -->|PCIe Gen2 x1| XDMA[XDMA endpoint]
    XDMA -->|BAR0 AXI-Lite| REGS[npu_regs]
    XDMA -->|DMA AXI4| MEM[Card memory]
    REGS -.->|later: doorbell, status| ENG[NPU engine]
    MEM -.->|later: weights, tensors| ENG
```

## Decisions

**XDMA instead of a hand-written PCIe transaction layer.** The previous experiment in this workspace drove the 7-series PCIe block directly with the PIO example. That shows TLPs but leaves DMA, descriptor handling and interrupts to write from scratch, and those are not the subject of this project. XDMA provides a scatter-gather engine of the kind real accelerators use, plus a maintained Linux driver.

**Gen2 x1, 64-bit AXI at 125 MHz.** The i.MX95 slot has one lane, so wider configurations would not train wider. At Gen2 x1, a 64-bit datapath at 125 MHz (1 GB/s) is more than the link's 500 MB/s, so the AXI side is never the bottleneck.

**Control and data on separate BARs.** BAR0 is the card's own register map; BAR1 belongs to the DMA engine and its driver. A runtime can map BAR0 into user space without touching the driver's registers, which is how accelerator stacks keep doorbells cheap.

**AMD's IDs and driver for now.** `10ee:7021` makes the stock XDMA driver bind without changes. A project ID comes with the project's own driver (roadmap phase 3).

**Bitstream in SPI flash.** The host enumerates PCIe once at boot, and expects the card ready within about 100 ms of releasing PERST#. The card configures itself from flash at power-on, compressed to shorten configuration time, and is powered before the host.

**Non-project Tcl builds.** `hw/scripts/build.tcl` runs synthesis to bitstream from source and settings alone, so a clean clone builds with one command and the repository holds no generated files. Timing failure stops the build. `hw/scripts/create_project.tcl` makes a Vivado project from the same sources for exploring in the GUI; it is disposable.

**A block design only for the memory system.** The MIG, SmartConnect, System ILA and their board-preset automation work best in IP Integrator, so `card_mem` is a block design, recreated by `hw/bd/card_mem.tcl` whenever that script changes. Everything written for this project stays in Verilog.

**AXI against AMD's templates.** `npu_regs` is built on Vivado's AXI4-Lite slave template and `mem_bw`'s handshakes are checked against its AXI4 master template (`hw/scripts/axil_template.tcl` regenerates both). Each block's testbench drives it the way the real peer does and has a protocol monitor; the two AXI rules that were broken during development (a read response in its address cycle, write data waiting for the address handshake) each have a test that fails against the old code.

**Debug cores on their own clock.** The debug hub and VIO run from the board's Si570 oscillator through an MMCM, not from the PCIe or MIG clocks, so the Hardware Manager can still reach them when there is no host or the memory controller is in reset.

## Verification

| Level | How | Where |
| --- | --- | --- |
| Register block | Self-checking XSim testbench: identity, byte strobes, channel ordering, read-only behavior, counter coherence, interrupt handshake, back-to-back reads with RREADY held high as XDMA does, and an AXI handshake-order monitor. | `hw/sim/tb_npu_regs.v`, `make sim` |
| Full design | Timing closure and DRC on every build. | `build/reports/` |
| Memory system on hardware | JTAG-only DDR3 test (`make jtag-memtest`), host `npu-ctl memtest` over the full 1 GiB, AXI protocol checkers in the System ILAs. | [Debugging](docs/debugging.md), [bring-up](docs/bringup.md) |
| Hardware | Bring-up checklist, filled in with dated results. | [docs/bringup.md](docs/bringup.md) |

The XDMA example simulation is not part of the flow: it exceeds the instance limit of Vivado's free simulator tier. The project's own blocks are kept small enough to test in XSim, and the PCIe path is tested on hardware.
