# fpga-edge-npu

An open neural-processing card built on an FPGA. The card plugs into an embedded Linux host over PCIe, the way a Hailo-8 or an NXP Ara-2 module does, and every layer is open to read: the PCIe endpoint, the DMA path, the register map, the host driver and tools, and (in later phases) the inference engine and the model compiler.

The reference pair is an AMD **AC701** (Artix-7 200T) as the card and an NXP **FRDM-i.MX95** as the host, joined through the i.MX95 board's M.2 Key-M slot. The goal is to learn and show, by building one, how a discrete edge-AI accelerator works from the bus up.

**Status: phases 1 and 2 done; phase 3 (command queue and own driver) is next.** On the FRDM-i.MX95 the card enumerates at PCIe Gen2 x1, DMA reaches about 370 MB/s host to card and 340 MB/s back, and the whole 1 GiB of card DDR3 passes write-then-verify tests from the host and from inside the FPGA. Inside the card, the DDR3 delivers 5.5 GB/s writing and 5.9 GB/s reading, 85 to 93 % of its peak. [Bring-up](docs/bringup.md) has the measurements and the problems found on the way, including a cache-maintenance bug in AMD's XDMA driver that the i.MX95's IOMMU exposed, found and patched; [debugging](docs/debugging.md) covers the ILAs, VIO and JTAG tests built into the card. There is no inference engine yet; the [roadmap](ROADMAP.md) says what comes next and when each step counts as done.

Created by **Edgar Duarte**. Apache-2.0 licensed.

[Architecture](ARCHITECTURE.md) · [Roadmap](ROADMAP.md) · [How edge-AI cards work](docs/edge-ai-accelerators.md) · [Hardware setup](docs/hardware-setup.md) · [Bring-up](docs/bringup.md) · [Debugging](docs/debugging.md) · [Register map](docs/register-map.md) · [Contribute](CONTRIBUTING.md)

![The FRDM-i.MX95 on the left, joined by a flat riser cable to the PCIe edge connector of the AC701 on the right](docs/images/bench-setup.jpg)

*The bench: the FRDM-i.MX95 host (left) drives the AC701 card (right) over PCIe Gen2 x1, through an M.2 Key-M to PCIe x4 riser cable into the AC701's edge connector. Each board runs from its own supply.*

## What it is today

```
 FRDM-i.MX95 (host)                          AC701 (card)
 ┌────────────────────────┐   PCIe Gen2 x1   ┌──────────────────────────────────┐
 │ Linux                  │   M.2 Key-M to   │ XDMA PCIe endpoint (10ee:7021)   │
 │  npu-ctl, XDMA driver  │◄────────────────►│  BAR0 ─► npu_regs (control)      │
 │                        │   x4 slot riser  │  BAR1 ─► DMA engine ─► 1 GiB     │
 └────────────────────────┘                  │                  DDR3 card memory│
                                             └──────────────────────────────────┘
```

- **PCIe endpoint.** AMD's DMA/Bridge Subsystem (XDMA), Gen2 x1, class code `12 00 00` (processing accelerator). The i.MX95 slot is a single PCIe 3.0 lane and the Artix-7 tops out at Gen2, so the link trains at 5 GT/s x1.
- **Control plane (BAR0).** `npu_regs`, an AXI-Lite register block written for this project: identity, version and build ID, a scratch register, a 64-bit cycle counter for latency measurements, software LEDs, a software-raised interrupt to exercise MSI, and the DDR3 status and DMA counters. See the [register map](docs/register-map.md).
- **Data plane (BAR1).** XDMA's scatter-gather DMA engine moves buffers between host memory and the card's 1 GiB DDR3 SODIMM, through AMD's memory controller (MIG), the place where weights and tensors will later live. Phase 1 used 64 KiB of block RAM.
- **Debug.** System ILAs with AXI protocol checkers on both sides of the memory interconnect, a VIO, a JTAG-to-AXI master and DMA counters in BAR0; see [debugging](docs/debugging.md).
- **Host tool.** `npu-ctl` reads and writes registers, tests the scratch register, measures BAR0 read latency, runs a DMA loopback with throughput figures, tests all of card memory, and measures the DDR3's bandwidth from inside the card. It cross-compiles for the i.MX95 (aarch64).

![Vivado Hardware Manager showing the MIG-side System ILA: decoded AXI read transactions, 512-bit read data beats with OKAY responses, and a protocol checker count of zero](docs/images/hardware-manager-ila.png)

*Inside the card: the System ILA on the DDR3 controller's AXI port, in Vivado's Hardware Manager. Triggered on `ARVALID`, it shows two read transactions arriving at the memory controller, their 512-bit data beats with `OKAY` responses, and no AXI protocol checker assertions. [Debugging](docs/debugging.md) explains how to capture this.*

## Build

You need Vivado 2025.2 (the free Standard edition covers the Artix-7 200T). From the repository root:

```sh
make bitstream      # build/npu_top.bit and build/npu_top.mcs (SPI flash image)
make sim            # register-block testbench in XSim; prints RESULT: PASS
make tools          # npu-ctl for this machine
make tools CC=aarch64-linux-gnu-gcc   # npu-ctl for the i.MX95
make project        # a Vivado project in build/vivado_project, to explore in the GUI
```

From a clean clone `make bitstream` takes about 5 minutes on an 8-core machine, 2 once the IP cores are cached in `build/ip/`. It stops with an error if timing is not met; reports land in `build/reports/`. If Vivado runs in a container on your machine, set `XRUN` to the command prefix that runs a program inside it (see the [Makefile](Makefile)).

Then follow [hardware setup](docs/hardware-setup.md) to connect the boards and [bring-up](docs/bringup.md) to flash the card and test the link from the i.MX95.

## Repository layout

| Path | Contents |
| --- | --- |
| `hw/rtl/` | Verilog written for this project: `npu_top` (AC701 top level), `npu_regs` (BAR0 registers). |
| `hw/constr/` | AC701 pin, clock and configuration constraints. |
| `hw/bd/` | `card_mem.tcl`: the DDR3 memory system and debug cores as a block design. |
| `hw/scripts/` | `ip.tcl` creates the AMD IP cores from settings; `build.tcl` runs synthesis to bitstream; `create_project.tcl` makes a Vivado project for the GUI; `program.tcl` loads and flashes over JTAG; `debug.tcl` checks DDR3 over JTAG; `axil_template.tcl` regenerates the AXI4-Lite template `npu_regs` is based on. |
| `hw/sim/` | Self-checking XSim testbenches. |
| `sw/tools/` | `npu-ctl`, the bring-up tool for the host; `cacheprobe`, a check for stale CPU cache lines after card-to-host DMA. |
| `sw/scripts/` | `imx95-load-xdma.sh` loads the XDMA driver on the FRDM-i.MX95; `npu-card.service` runs it at boot. |
| `sw/patches/` | `xdma-unmap-orig-nents.patch`: fixes AMD's XDMA driver for hosts with an IOMMU (see [bring-up](docs/bringup.md)). |
| `docs/` | Background, hardware setup, bring-up, debugging, register map. |

The repository holds only source and settings. AMD IP (XDMA, and the MIG, SmartConnect and debug cores in the block design) is generated at build time from `hw/scripts/ip.tcl` and `hw/bd/card_mem.tcl`, never committed.

## Limits

This is a learning and portfolio project, not a product. It is not certified for any use, and it is not affiliated with AMD, NXP, Hailo or Kinara; their product names describe what this project compares itself with. Performance figures in these docs are labelled as measured, estimated, or from vendor documents.

---

<sub>Published by Virtu Services LLC ([virtu-services.us](https://virtu-services.us)).</sub>
