# Working on fpga-edge-npu as an agent

fpga-edge-npu is an open PCIe neural-processing card: an AMD AC701 FPGA board driven by an NXP FRDM-i.MX95 host. Help with a concrete, scoped change, preserve existing work, and report what you actually verified. Hardware results come only from runs on hardware; never mark a bring-up check as passed from simulation or reasoning.

## Start here

1. Read [README.md](README.md), [ARCHITECTURE.md](ARCHITECTURE.md) and the phase you are working on in [ROADMAP.md](ROADMAP.md).
2. Inspect `git status` before editing. Do not revert unrelated changes.
3. Use Vivado 2025.2. If it runs in a container, pass the prefix through `XRUN` (see the Makefile).

## Commands

```sh
make bitstream   # synthesis to bitstream; fails if timing is not met (about 5 minutes clean)
make sim         # XSim testbenches; each must print RESULT: PASS
make tools       # npu-ctl; add CC=aarch64-linux-gnu-gcc for the i.MX95
make program     # load the bitstream over JTAG
make flash       # write the SPI flash over JTAG
make status      # mode pins and DONE over JTAG; read-only
make ddr-status  # DDR3 calibration over JTAG (VIO); also ddr-reset, jtag-memtest
make project     # Vivado project in build/vivado_project for the GUI; disposable
```

Run one Vivado at a time per directory: Vivado's `.Xil/Vivado-<pid>-<host>` temporary directories collide between containers that reuse PIDs. `build.tcl` works inside `build/` for this reason.

## Where to work

| Change | Files | Keep in step |
| --- | --- | --- |
| Registers | `hw/rtl/npu_regs.v` | `docs/register-map.md`, `hw/sim/tb_npu_regs.v`, `sw/tools/npu-ctl.c` |
| Top level, clocks, LEDs | `hw/rtl/npu_top.v` | `docs/register-map.md` (LEDs), `ARCHITECTURE.md` |
| PCIe or IP settings | `hw/scripts/ip.tcl` | `docs/register-map.md` (PCIe identity), `ARCHITECTURE.md` |
| Memory system, debug cores | `hw/bd/card_mem.tcl` | `docs/debugging.md`, `ARCHITECTURE.md`, `npu_top` port list |
| JTAG debug scripts | `hw/scripts/debug.tcl` | `docs/debugging.md`, `Makefile` |
| Pins, configuration | `hw/constr/ac701.xdc`, `hw/constr/debug.xdc` | `docs/hardware-setup.md` |
| Build flow | `hw/scripts/*.tcl`, `Makefile` | `README.md`, this file |
| Host tool | `sw/tools/npu-ctl.c` | `docs/bringup.md` |
| i.MX95 setup | `sw/scripts/imx95-load-xdma.sh`, `sw/scripts/npu-card.service` | `docs/bringup.md` |

## Rules

- Never commit generated output: `build/`, AMD IP products, bitstreams, logs. The repository holds sources and the Tcl that recreates the IP.
- RTL is Verilog-2001 with `default_nettype none`, one module per file, synchronous active-low resets on the AXI clock, and comments that say why rather than what.
- A register change updates the RTL, the register map, the testbench and `npu-ctl` in the same commit.
- Label numbers as measured (with date and setup), estimated, or from a vendor document.
- Keep documentation current in the same change as the code.
- Commits: a short subject plus a few sentences. No HTML, no agent footers, no pasted PR body.
