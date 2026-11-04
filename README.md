# fpga-edge-npu

An open neural-processing card built on an FPGA. The card plugs into an embedded Linux host over PCIe, the way a Hailo-8 or an NXP Ara-2 module does, and every layer is open to read: the PCIe endpoint, the DMA path, the register map, the host driver and tools, and (in later phases) the inference engine and the model compiler.

The reference pair is an AMD **AC701** (Artix-7 200T) as the card and an NXP **FRDM-i.MX95** as the host, joined through the i.MX95 board's M.2 Key-M slot. The goal is to learn and show, by building one, how a discrete edge-AI accelerator works from the bus up.

**Status: phase 1 done; phase 2 (card memory on DDR3) is next.** On the FRDM-i.MX95, the card enumerates at PCIe Gen2 x1, a register read takes 1.18 µs, 10⁶ register writes check out, DMA moves 64 KiB blocks at about 290 MB/s each way, and the card's interrupt reaches the driver. [Bring-up](docs/bringup.md) has the measurements and the problems found on the way, including an i.MX95 IOMMU issue that needs a workaround. There is no inference engine yet; the [roadmap](ROADMAP.md) says what comes next and when each step counts as done.

Created by **Edgar Duarte**. Published by **Virtu Services LLC**. Engineering consulting through **[Virtu Services](https://virtu-services.us)**. Apache-2.0 licensed.

[Architecture](ARCHITECTURE.md) · [Roadmap](ROADMAP.md) · [How edge-AI cards work](docs/edge-ai-accelerators.md) · [Hardware setup](docs/hardware-setup.md) · [Bring-up](docs/bringup.md) · [Register map](docs/register-map.md) · [Contribute](CONTRIBUTING.md)

## What it is today

```
 FRDM-i.MX95 (host)                          AC701 (card)
 ┌────────────────────────┐   PCIe Gen2 x1   ┌──────────────────────────────────┐
 │ Linux                  │   M.2 Key-M to   │ XDMA PCIe endpoint (10ee:7021)   │
 │  npu-ctl, XDMA driver  │◄────────────────►│  BAR0 ─► npu_regs (control)      │
 │                        │   x4 slot riser  │  BAR1 ─► DMA engine ─► 64 KiB    │
 └────────────────────────┘                  │                       card memory│
                                             └──────────────────────────────────┘
```

- **PCIe endpoint.** AMD's DMA/Bridge Subsystem (XDMA), Gen2 x1, class code `12 00 00` (processing accelerator). The i.MX95 slot is a single PCIe 3.0 lane and the Artix-7 tops out at Gen2, so the link trains at 5 GT/s x1.
- **Control plane (BAR0).** `npu_regs`, an AXI-Lite register block written for this project: identity, version and build ID, a scratch register, a 64-bit cycle counter for latency measurements, software LEDs, and a software-raised interrupt to exercise MSI. See the [register map](docs/register-map.md).
- **Data plane (BAR1).** XDMA's scatter-gather DMA engine moves buffers between host memory and 64 KiB of on-card memory, the place where weights and tensors will later live.
- **Host tool.** `npu-ctl` reads and writes registers, tests the scratch register, measures BAR0 read latency, and runs a DMA loopback with throughput figures. It cross-compiles for the i.MX95 (aarch64).

## Build

You need Vivado 2025.2 (the free Standard edition covers the Artix-7 200T). From the repository root:

```sh
make bitstream      # build/npu_top.bit and build/npu_top.mcs (SPI flash image)
make sim            # register-block testbench in XSim; prints RESULT: PASS
make tools          # npu-ctl for this machine
make tools CC=aarch64-linux-gnu-gcc   # npu-ctl for the i.MX95
```

From a clean clone `make bitstream` takes about 5 minutes on an 8-core machine, 2 once the IP cores are cached in `build/ip/`. It stops with an error if timing is not met; reports land in `build/reports/`. If Vivado runs in a container on your machine, set `XRUN` to the command prefix that runs a program inside it (see the [Makefile](Makefile)).

Then follow [hardware setup](docs/hardware-setup.md) to connect the boards and [bring-up](docs/bringup.md) to flash the card and test the link from the i.MX95.

## Repository layout

| Path | Contents |
| --- | --- |
| `hw/rtl/` | Verilog written for this project: `npu_top` (AC701 top level), `npu_regs` (BAR0 registers). |
| `hw/constr/` | AC701 pin, clock and configuration constraints. |
| `hw/scripts/` | `ip.tcl` creates the AMD IP cores from settings; `build.tcl` runs synthesis to bitstream; `program.tcl` loads and flashes over JTAG; `axil_template.tcl` regenerates the AXI4-Lite template `npu_regs` is based on. |
| `hw/sim/` | Self-checking XSim testbenches. |
| `sw/tools/` | `npu-ctl`, the bring-up tool for the host; `cacheprobe`, the check for the i.MX95 IOMMU DMA problem. |
| `sw/scripts/` | `imx95-load-xdma.sh`: IOMMU pass-through and driver load on the FRDM-i.MX95. |
| `docs/` | Background, hardware setup, bring-up, register map. |

The repository holds only source and settings. AMD IP (XDMA, BRAM controller) is generated at build time from `hw/scripts/ip.tcl`, never committed.

## Limits

This is a learning and portfolio project, not a product. It is not certified for any use, and it is not affiliated with AMD, NXP, Hailo or Kinara; their product names describe what this project compares itself with. Performance figures in these docs are labelled as measured, estimated, or from vendor documents. The DMA path currently needs the i.MX95's IOMMU in pass-through mode for the card, which removes the IOMMU's protection against a misbehaving device.
