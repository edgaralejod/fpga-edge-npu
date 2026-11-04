# Bring-up

Phase 1 (PCIe link) is sections 1 to 4 and its checklist; phase 2 (DDR3 card memory) follows.

This is the procedure for getting the FRDM-i.MX95 and the AC701 talking, and the record of what has been checked. Connect the boards first ([hardware setup](hardware-setup.md)).

## 1. Build and flash the card

On the build machine:

```sh
make bitstream          # build/npu_top.bit, build/npu_top.mcs
make flash              # write the SPI flash over JTAG, then reboot the FPGA from it
make status             # mode pins and DONE, read over JTAG
```

When Vivado runs in a container, pass the prefix, for example `make flash XRUN="fpga run 2025.2 --"`. Vivado starts its own `hw_server` inside the container; the container needs the host's USB devices and network.

The AC701 boots from flash only when mode switch SW1 is at `001` (master SPI): position 1 (M2) off, position 3 (M0) on, position 2 not connected. At `101` it waits for JTAG, and `make flash` stops after verifying the flash with a message saying so. Power-cycle the board after changing SW1; DONE (DS10) lights and `make status` reports `M[2:0] = 001`, `DONE = 1`.

After a flash boot, GPIO_LED_1 (heartbeat) stays dark until a host supplies the PCIe reference clock; that is expected.

## 2. Boot the host and check enumeration

Power the AC701 first, wait for DONE, then power the FRDM-i.MX95. On the i.MX95:

```sh
lspci -nn
#   0001:01:00.0 Processing accelerators [1200]: Xilinx Corporation Device [10ee:7021]
sudo lspci -vv -s <bdf> | grep -E 'LnkCap:|LnkSta:|Region'
#   LnkSta: Speed 5GT/s, Width x1     <- Gen2 x1 is the expected result
#   Region 0: Memory at ... size=64K  <- BAR0, npu_regs
#   Region 1: Memory at ... size=64K  <- BAR1, XDMA engine
dmesg | grep -i pci                   # link training messages from the i.MX PCIe controller
```

On the card, GPIO_LED_0 lights at link up and GPIO_LED_1 blinks.

## 3. Registers, no driver needed

Copy `npu-ctl` to the i.MX95 (build it with `make tools CC=aarch64-linux-gnu-gcc`, or with the i.MX Yocto SDK's compiler). The NXP BSP image includes `gcc`, so copying `sw/tools/npu-ctl.c` and building it on the board also works. Run `sync` before powering the board off: a file written shortly before a power cut can come back empty. Without a driver bound, `npu-ctl` enables the device through sysfs and maps BAR0 from `resource0`, which needs root:

```sh
sudo ./npu-ctl info
sudo ./npu-ctl regtest 1000000
sudo ./npu-ctl latency 100000
sudo ./npu-ctl led 3            # GPIO_LED_2 and 3 on
```

## 4. DMA with the Xilinx XDMA driver

The DMA engine needs a kernel driver to own its descriptor rings and interrupts. Phase 1 uses AMD's reference driver unchanged ([dma_ip_drivers](https://github.com/Xilinx/dma_ip_drivers), tested at commit `a918c51`, driver v2025.2.0).

NXP's BSP image has no kernel build tree on the board, and the kernel has `CONFIG_MODVERSIONS=y`, so the module is cross-compiled against the matching NXP kernel source, configured with the board's own `/proc/config.gz` and built once to produce `Module.symvers`:

```sh
# on the build machine; kernel 6.18.2-1.0.0-gf49f45233f7b is NXP lf-6.18.2-1.0.0
git clone --depth 1 --branch lf-6.18.2-1.0.0 https://github.com/nxp-imx/linux-imx
mkdir kbuild && cp <config from the board's /proc/config.gz, unzipped> kbuild/.config
K="make -C linux-imx O=$PWD/kbuild ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION=-1.0.0"
$K olddefconfig && $K kernelrelease      # must print the board's uname -r
$K -j$(nproc) Image modules              # about 12 minutes; produces Module.symvers
git clone https://github.com/Xilinx/dma_ip_drivers
git -C dma_ip_drivers apply <repo>/sw/patches/xdma-unmap-orig-nents.patch   # see "Problems found"
cd dma_ip_drivers/XDMA/linux-kernel/xdma
$K M=$PWD ccflags-y=-I$PWD/../include modules
aarch64-linux-gnu-strip --strip-debug xdma.ko
```

The driver's Makefile passes its include path in `EXTRA_CFLAGS`, which Linux 6.18 no longer reads; `ccflags-y` replaces it. Arch Linux's cross compiler is GCC 16.2 and NXP built the kernel with GCC 15.2; the module loads and runs.

On the i.MX95, load it with the script. The i.MX95's IOMMU stays on and translates the card's DMA; with the unpatched driver, add `passthrough` as a second argument (see "Problems found"):

```sh
sudo sw/scripts/imx95-load-xdma.sh ./xdma.ko   # creates /dev/xdma0_user, _h2c_0, _c2h_0, _events_*
sudo ./npu-ctl info                            # now through /dev/xdma0_user
sudo ./npu-ctl dmatest 65536 100
```

The driver is not loaded at boot by itself. To have systemd run the script at boot, install `sw/scripts/npu-card.service` (instructions in the file); with the script and `xdma.ko` in `/root`:

```sh
sudo cp npu-card.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now npu-card.service
```

Installed on the FRDM-i.MX95 on 2026-11-04; after a reboot it loaded the driver on its own and `npu-ctl memtest` passed. If the AC701 was not powered first, the unit fails with "no 10ee:7021 device" and the rest of the boot is unaffected.

To check the interrupt path, wait for user interrupt 0 and raise it from the `IRQ` register:

```sh
dd if=/dev/xdma0_events_0 bs=4 count=1 | od -An -tx4 &   # returns when the MSI arrives
sudo ./npu-ctl write 0x28 1                                # IRQ[0]: request
sudo ./npu-ctl read 0x28                                   # 0x3: requested and acknowledged
sudo ./npu-ctl write 0x28 0; sudo ./npu-ctl write 0x28 2   # release, clear the ack
```

If interrupts do not arrive, load the driver with `poll_mode=1` to separate MSI problems from DMA problems.

## Expected numbers

Gen2 x1 carries 5 GT/s with 8b/10b coding: 500 MB/s per direction before packet overhead. Each DMA transfer through the XDMA character devices also pays a fixed cost for pinning pages, building descriptors and the completion interrupt, so small transfers run far below the link rate.

Measured 2026-11-04 (FRDM-i.MX95, NXP BSP 6.18-whinlatter, IOMMU pass-through, `npu-ctl dmatest <size> 1000`, card memory 64 KiB BRAM):

| Transfer | Host to card | Card to host |
| --- | --- | --- |
| 8 B | 0.2 MB/s | 0.2 MB/s |
| 4 KiB | 90.7 MB/s | 92.9 MB/s |
| 8 KiB | 141.5 MB/s | 144.6 MB/s |
| 32 KiB | 243.6 MB/s | 246.2 MB/s |
| 64 KiB | 291.1 MB/s | 289.3 MB/s |

The 8-byte case puts the fixed cost per transfer at about 40 µs. Larger transfers need more card memory than the phase 1 BRAM; phase 2 moves card memory to DDR3.

## Checklist

| Check | Expected | Result |
| --- | --- | --- |
| Bitstream builds from a clean clone, timing met | WNS ≥ 0, WHS ≥ 0 | Pass, 2026-11-03 (Vivado 2025.2; WNS +0.600 ns, WHS +0.036 ns clean; 8.7 % of LUTs, 10 % of block RAM). 0.1.1 rebuilt 2026-11-04: WNS +0.543 ns, WHS +0.036 ns |
| `npu_regs` testbench | `RESULT: PASS` | Pass, 2026-11-04 (20 checks and the protocol monitor, XSim 2025.2) |
| `npu-ctl` builds for aarch64 | No warnings | Pass, 2026-11-03 (Vivado's bundled aarch64 GCC) |
| JTAG through `hw_server` in the container | `xc7a200t_0` on the chain | Pass, 2026-11-04 (Digilent U26, serial 210203AF54D0A) |
| `make program` | End of startup HIGH | Pass, 2026-11-04 |
| SPI flash programs and the FPGA boots from it | DONE lit after power cycle | Pass, 2026-11-04 (N25Q256, JEDEC ID `20 BA 19`, written as `mt25ql256`; erase, program and verify 73 s; with SW1 at 001, DONE = 1 after power cycle) |
| `lspci` on the i.MX95 shows `10ee:7021`, class 1200 | Present | Pass, 2026-11-04 (NXP BSP 6.18-whinlatter, kernel 6.18.2; `0000:01:00.0`, both 64 KiB BARs assigned) |
| Link speed and width | 5 GT/s, x1 | Pass, 2026-11-04 (`LnkSta: Speed 5GT/s, Width x1`; the i.MX95 port is 8 GT/s capable) |
| `npu-ctl info` | ID `NPU0`, version 0.1.1 | Pass, 2026-11-04 (build `26110415`, caps `0x00400001`, link up) |
| `npu-ctl regtest 1000000` | PASS | Pass, 2026-11-04 (10⁶ writes, 0 errors; no AER errors afterwards, link still Gen2 x1) |
| `npu-ctl latency` | Record value | 1183 ns per BAR0 read, measured 2026-11-04 (`latency 100000`, two runs: 1184 and 1183 ns; Cortex-A55 user space, sysfs `resource0` mapping, Gen2 x1, i.MX95 BSP 6.18-whinlatter) |
| XDMA driver loads on the i.MX95 kernel | Device nodes created | Pass, 2026-11-04 (dma_ip_drivers `a918c51`, cross-compiled; BAR0 user, BAR1 config, 1 H2C + 1 C2H channel, MSI enabled) |
| `npu-ctl dmatest 65536 100` | PASS; record both directions | Pass, 2026-11-04, with IOMMU pass-through (10 000 loops of 64 KiB, 0 errors; 291.8 MB/s host to card, 289.7 MB/s card to host). Fails with the IOMMU translating; see below |
| MSI from `IRQ` register reaches the driver | Interrupt count rises | Pass, 2026-11-04 (`/dev/xdma0_events_0` returned 1; MSI count 30206 to 30207; `IRQ` read `0x3`) |

## Phase 2: DDR3 card memory

The card memory is now the AC701's 1 GiB DDR3 SODIMM behind the MIG, in the `card_mem` block design. Build and flash as in section 1; `make bitstream` also writes `build/npu_top.ltx`, the probe names for the debug cores ([debugging](debugging.md)).

Check the memory over JTAG first, with or without the host:

```sh
make ddr-status   XRUN="fpga run 2025.2 --"   # ddr calibrated 1, ddr mmcm locked 1
make jtag-memtest XRUN="fpga run 2025.2 --"   # every address line, five patterns
make ddr-reset    XRUN="fpga run 2025.2 --"   # MIG reset from the VIO, then recalibration
```

Then from the i.MX95, after a reboot (the FPGA was reconfigured) and `sw/scripts/imx95-load-xdma.sh`:

```sh
sudo ./npu-ctl info                  # version 0.2.0, 1048576 KiB DDR3, ddr calibrated
sudo ./npu-ctl dmatest 4194304 100
sudo ./npu-ctl dmatest 1048576 20 0x3FF00000   # the top MiB of the DDR3
sudo ./npu-ctl memtest               # all 1 GiB: write everything, then read and check
```

`memtest` writes every 64-bit word with a value derived from its address and a per-run seed before reading any back, so a broken address line shows up as data from another address.

Measured 2026-11-04 (same setup as phase 1, bitstream build `26110417`, IOMMU pass-through):

| Transfer | Host to card | Card to host |
| --- | --- | --- |
| 4 KiB | 77.5 MB/s | 80.2 MB/s |
| 64 KiB | 292.9 MB/s | 291.4 MB/s |
| 1 MiB | 342.4 MB/s | 339.0 MB/s |
| 4 MiB | 368.8 MB/s | 332.5 MB/s |
| 16 MiB | 371.0 MB/s | 325.4 MB/s |

Large transfers reach about 74 % of the 500 MB/s Gen2 x1 carries per direction. `memtest` itself reports about 200 MB/s, because generating and checking the pattern on the Cortex-A55 takes about half its time.

### Card-side bandwidth

`mem_bw` writes and then reads the whole 1 GiB in 4 KiB, 512-bit bursts at the MIG's 100 MHz clock, checking every 64-byte beat it reads, and times both passes with the card's own cycle counter:

```sh
sudo ./npu-ctl bwtest                 # all of card memory, 16 bursts in flight
sudo ./npu-ctl bwtest 1073741824 1    # one burst at a time
```

Measured 2026-11-04 (card 0.3.0, build `26110418`; DDR3 peak 800 MT/s x 8 bytes = 6400 MB/s):

| Bursts in flight | Write | Read |
| --- | --- | --- |
| 1 | 4227 MB/s (66 %) | 3629 MB/s (57 %) |
| 2, 4, 8, 16 | 5468 MB/s (85 %) | 5921 MB/s (93 %) |

Every run: 0 mismatched beats, 0 AXI errors. One burst at a time pays the controller's read latency on every 4 KiB; two in flight already hide it, and the identical results from 2 to 16 put the remaining limit in the MIG (refresh, page changes, write-to-read turnaround). The card's memory delivers about 16 times what the PCIe Gen2 x1 link carries (370 MB/s), so whatever the compute engine needs repeatedly has to stay in card memory: the case Ara-class accelerators make for on-card DRAM.

### Phase 2 checklist

| Check | Expected | Result |
| --- | --- | --- |
| Bitstream with MIG, SmartConnect and debug cores meets timing | WNS ≥ 0, WHS ≥ 0 | Pass, 2026-11-04 (WNS +0.251 ns, WHS +0.017 ns; 34 % of LUTs, 21 % of block RAM, 3 of 10 MMCMs) |
| `npu_regs` 0.2.0 testbench | `RESULT: PASS` | Pass, 2026-11-04 |
| DDR3 calibrates | VIO and STATUS: calibrated, locked | Pass, 2026-11-04, first power-up |
| Debug cores reachable over JTAG | 2 ILAs, 1 JTAG-AXI master, VIO | Pass, 2026-11-04 (`hw_ila_1`, `hw_ila_2`, `hw_axi_1`) |
| `make jtag-memtest` | PASS | Pass, 2026-11-04 (29 addresses x 5 patterns, 0 errors) |
| MIG reset from the VIO | Recalibrates | Pass, 2026-11-04 |
| Flash boot, enumeration, link | Gen2 x1, `10ee:7021` | Pass, 2026-11-04 |
| `npu-ctl dmatest` up to 16 MiB, and at the top of the DDR3 | PASS | Pass, 2026-11-04, 0 AXI error responses |
| `npu-ctl memtest` over 1 GiB | PASS | Pass, 2026-11-04, twice (4 MiB and 1 MiB chunks, different seeds) |
| Card-side DDR3 bandwidth (counter-based, from inside the FPGA) | Measured | Pass, 2026-11-04: 5468 MB/s write, 5921 MB/s read over 1 GiB, every beat checked (`npu-ctl bwtest`, card 0.3.0, build `26110418`; table below) |

## Problems found

| Date | Symptom | Cause | Fix |
| --- | --- | --- | --- |
| 2026-11-04 | The first BAR0 read after reset returned the right value; every later BAR0 read returned `0xFFFFFFFF`. BAR1 reads and BAR0 writes still worked. Long `npu-ctl` loops stalled the i.MX95. | `npu_regs` 0.1.0 raised RVALID in the same cycle as the read-address handshake. XDMA holds RREADY high between reads, so the block counted the response as delivered while XDMA had dropped it, and XDMA's AXI-Lite master waited forever. | 0.1.1 rebuilds `npu_regs` on AMD's AXI4-Lite template, which raises RVALID one cycle later. The testbench now holds RREADY high between reads and has a protocol monitor; it reports 19 errors against the old behavior. |
| 2026-11-04 | With the XDMA driver loaded, `dmatest` passed at 4 KiB and failed at every larger size: card-to-host transfers returned stale data (mostly the zeros the buffer was cleared to) in every 4 KiB page after the first. Host-to-card transfers, card memory and single-page transfers at any card offset were all correct. | A bug in AMD's XDMA driver (`dma_ip_drivers` `a918c51`), exposed by the i.MX95's IOMMU. `xdma_xfer_submit()` maps the user buffer with `dma_map_sg(..., sgt->orig_nents, ...)` and keeps the returned count in `sgt->nents`; `transfer_destroy()` then unmaps with `dma_unmap_sg(..., sgt->nents, ...)` and zeroes `nents`, so the correct unmap is skipped. The DMA API requires the count given to `dma_map_sg()`, not the one it returned. Without an IOMMU the two counts match; with the IOMMU translating, the kernel merges the buffer's pages into one DMA segment, the unmap covers only the first entry, and on this non-coherent Arm host only the first page's CPU cache lines are invalidated. How it was narrowed down: flushing the buffer's cache lines from user space (`DC CIVAC`, `sw/tools/cacheprobe`) made the data correct, so it was in memory; waiting up to 10 ms without touching the buffer did not, so the data was not arriving late; relaxed ordering, No Snoop and `poll_mode=1` made no difference; IOMMU pass-through hid the bug by preventing the merge. | `sw/patches/xdma-unmap-orig-nents.patch` unmaps with `orig_nents`. The same bug and fix were already reported upstream in [Xilinx/dma_ip_drivers#386](https://github.com/Xilinx/dma_ip_drivers/issues/386) (2026-05-15, still open); this project found it independently and applies the fix locally. With it, and the IOMMU translating, `cacheprobe` passes, `dmatest` passes up to 4 MiB (377 MB/s to the card, 340 MB/s back) and `memtest` passes over 1 GiB (2026-11-04). Until 2026-11-04 the workaround was IOMMU pass-through, still available as `imx95-load-xdma.sh <ko> passthrough` for the unpatched driver. |

Record each hardware result with the date, the i.MX95 BSP version, and the exact command.
