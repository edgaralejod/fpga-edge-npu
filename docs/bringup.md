# Bring-up

Phase 1 (PCIe link) is sections 1 to 4 and its checklist; phase 2 (DDR3 card memory), phase 3 (command queue and the project's own driver) and phase 4 (the GEMM engine and MNIST on the card) follow. Sections 2 to 4 describe the XDMA-era cards (0.1 to 0.3); from 0.4.0 the card is `10ee:ed10`, has one BAR, and is driven by `fpga_npu.ko` (phase 3 below). Raw logs of the phase 3 and 4 runs are in [results](results/).

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

## Phase 3: command queue and the fpga-npu driver

From 0.4.0 the card's endpoint is AMD's `axi_pcie` bridge and the card fetches its own commands ([command queue](command-queue.md)). Build and flash as in section 1, power-cycle or reset the i.MX95, then check enumeration:

```sh
lspci -nn -s 01:00.0      # Processing accelerators [1200]: Xilinx Corporation Device [10ee:ed10]
lspci -vv -s 01:00.0      # LnkSta: Speed 5GT/s, Width x1; Region 0 64K; MSI: Enable+; driver fpga-npu
```

Build the driver against the board's kernel on the build machine (`make -C sw/driver KDIR=<build dir> KSRC=<source dir> ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION=-1.0.0`; `sw/driver/Makefile` has the details), and the runtime and tools on the i.MX95 itself (`make -C sw/npu`, the board has gcc). Then on the i.MX95:

```sh
insmod fpga_npu.ko        # dmesg: BAR0 ... (65536 bytes), arena 32 MiB at bus 0x7e000000, MSI irq 284
npu-test info             # version, caps, link up, DDR calibrated, ring addresses
npu-test all              # the acceptance run: NOPs, latency, copies, GEMMs against the CPU
```

To load the driver at every boot, install `sw/driver/fpga-npu.service` (instructions in the file) and disable the old `npu-card.service`, which loads XDMA for 0.3.x cards.

Measured 2026-11-04 (FRDM-i.MX95, NXP BSP 6.18-whinlatter, kernel 6.18.2, IOMMU translating, card 0.4.0 build `26110421` and 0.5.0 build `26110421`; the numbers below agree between the two):

| Test | Result |
| --- | --- |
| `NOP` × 100 000 in batches of 63 | 0 out of order or failed; 505 000 commands/s, 1.98 µs each |
| One `NOP` at a time, polling the CQ, 2000 runs | Round trip median 3.79 to 3.83 µs, p99 4.00 µs, minimum 3.62 µs |
| One `NOP` at a time, sleeping on the MSI, 2000 runs | Median 12.1 µs, p99 14.0 µs (0.5.0); 13.8 µs on the first 0.4.0 run. One boot measured 107 µs median with the same binaries; not understood yet, not seen again |
| The card's own time for a `NOP` (`t_done − t_fetch`) | 8 ns: one cycle |
| `COPY_H2C` then `COPY_C2H`, 4 KiB × 200 | 0 mismatches; 262 MB/s to the card, 388 MB/s back (card timestamps) |
| Same, 1 MiB × 20 and 8 MiB × 4 | 0 mismatches; 418 to 419 MB/s to the card, 416 to 417 MB/s back |

Copies reach 84 % of the 500 MB/s Gen2 x1 carries, against 74 % for XDMA in phase 2 (371 and 325 MB/s at 16 MiB). Small host-to-card copies are slower than card-to-host ones because every read of host memory waits for a PCIe completion, while writes are posted. A `NOP`'s round trip is the link's: the posted doorbell write, the card's read of the command from host memory through the IOMMU, and the completion write the CPU polls for.

### Phase 3 checklist

| Check | Expected | Result |
| --- | --- | --- |
| Bitstream with the bridge, `npu_cq` and `npu_mm` meets timing | WNS ≥ 0, WHS ≥ 0 | Pass, 2026-11-04 (0.4.0 build `26110421`: WNS +0.135 ns, WHS +0.015 ns, after registering the copy engine's read decisions; see "Problems found") |
| `tb_npu_cq`, `tb_npu_regs`, `tb_mem_bw` | `RESULT: PASS` | Pass, 2026-11-04 |
| Enumeration as `10ee:ed10`, class 1200, Gen2 x1, MSI | Present | Pass, 2026-11-04 |
| `fpga_npu.ko` probes | BAR0, 32 MiB arena, MSI | Pass, 2026-11-04 (arena at bus `0x7e000000`, IOMMU translating) |
| 10 000 or more `NOP`s, each completed once, in order | PASS | Pass, 2026-11-04 (100 000; failed first on a runtime bug, see "Problems found") |
| Copy round trips byte for byte | PASS | Pass, 2026-11-04, up to 8 MiB |
| Per-command latency distributions | Recorded | Pass, 2026-11-04 (table above) |
| Same after `rmmod` and `insmod` | PASS | Pass, 2026-11-04 (`npu-test nop 20000`, `copy 1048576 10`, `gemm`) |
| Same after the host reboots with the card powered | PASS | Pass, 2026-11-04 (driver loaded by `fpga-npu.service`) |

## Phase 4: the GEMM engine and MNIST on the card

`npu-test gemm M K N` fills A, Bᵀ and the bias with random values, runs the product twice on the card (INT8 output with ReLU and scaling, and INT32 output), and compares every output with the CPU (`npu_gemm_ref`, the same arithmetic as `sw/npu/npu_ref.py`). `npu-test all` runs three shapes. The CPU times are one Cortex-A55 core, scalar C compiled with `-O2`, on cached copies of the inputs.

Measured 2026-11-04:

| Product | Outputs differing from the CPU | Card 0.4.0 | Card 0.5.0 | CPU |
| --- | --- | --- | --- | --- |
| 64 × 832 · 832 × 128 | 0 of 8192 INT8, 0 of 8192 INT32 | 7.83 ms, 870 MMAC/s | 1.05 ms, 6523 MMAC/s | 4.41 ms, 1547 MMAC/s |
| 7 × 2048 · 2048 × 1024 | 0 of 7168, 0 of 7168 | 16.6 ms, 887 MMAC/s | 2.39 ms, 6137 MMAC/s | 9.63 ms, 1525 MMAC/s |
| 203 × 512 · 512 × 256 | 0 of 51 968, 0 of 51 968 | 30.4 ms, 875 MMAC/s | 4.07 ms, 6539 MMAC/s | 17.6 ms, 1515 MMAC/s |

0.4.0 multiplied one row of A at a time, 8 MACs per cycle (peak 1 GMAC/s); 0.5.0 holds 8 rows and each weight beat feeds 64 MACs (peak 8 GMAC/s, 6.5 reached, 82 %). With 7 rows, one tile is not full and the rate drops accordingly.

### MNIST

`sw/mnist/train.py` trains a 784 → 128 → 10 network with NumPy and quantizes it for the engine ([sw/mnist](../sw/mnist/README.md)); its bit-exact model scores 97.11 % on the 10 000 test images, the same as the float network. Copy `build/mnist/` (`model.bin`, `expected.bin` and the two `t10k` files, unzipped) to the i.MX95, then:

```sh
npu-mnist model.bin t10k-images-idx3-ubyte t10k-labels-idx1-ubyte expected.bin
```

It uploads the weights and all 10 000 images, runs the two layers as two GEMM commands, downloads the logits, compares every logit with the CPU and every prediction with `expected.bin`, then times 200 single images (upload, two layers, download, argmax) the way an application would, and prints one of them as a `TRACE` line of card timestamps (the [site](https://edgaralejod.github.io/fpga-edge-npu/) draws it).

Measured 2026-11-04:

| | Card 0.4.0 | Card 0.5.0 | CPU, one Cortex-A55 core |
| --- | --- | --- | --- |
| Accuracy, 10 000 test images | 97.11 % | 97.11 % | 97.11 % |
| Logits differing from the CPU | 0 of 100 000 | 0 of 100 000 | |
| Predictions differing from `train.py` | 0 | 0 | |
| Layer 1 + layer 2, all 10 000 images | 1224.0 + 111.9 ms | 163.1 + 18.7 ms | 735.6 ms |
| Throughput | 7 486 images/s (859 MMAC/s) | 55 032 images/s (6 311 MMAC/s) | 13 595 images/s (1 559 MMAC/s) |
| Images up, logits down (PCIe) | 19.8 ms, 6.1 ms | 19.8 ms, 6.1 ms | |
| End to end, 10 000 images | 1362 ms | 208 ms | 736 ms |
| One image, host round trip, median of 200 | 155.3 µs | 155.3 µs | |

MAC rates count the padded work (K = 832, N = 64 for layer 2). One image runs at 8 MACs per cycle on both versions, because a tile of one row reuses nothing; its 148 µs on the card are 5.5 µs uploading the image, 123.6 µs for layer 1, 12.1 µs for layer 2, 1.4 µs downloading the logits, and about 1.9 µs between commands (a completion write and the next fetch). Batches are where the card wins: 4 times one A55 core end to end.

### Phase 4 checklist (GEMM)

| Check | Expected | Result |
| --- | --- | --- |
| `tb_npu_cq` GEMM cases and `check_gemm.py` | 0 mismatches | Pass, 2026-11-04 (including K = 2048 with N = 1024, and 19 rows in tiles of 8, 8 and 3) |
| 0.5.0 bitstream meets timing | WNS ≥ 0, WHS ≥ 0 | Pass, 2026-11-04 (WNS +0.055 ns, WHS +0.010 ns; 40 % of LUTs, 24 % of block RAM, 72 of 740 DSP slices) |
| Random GEMMs on the card match the CPU bit for bit | 0 differing outputs | Pass, 2026-11-04 (table above) |
| Achieved MAC/s against the peak | Recorded | 6.5 of 8 GMAC/s (0.5.0) |
| MNIST on the card | Same predictions as the bit-exact model | Pass, 2026-11-04: 97.11 %, 0 differing logits or predictions |

## Problems found

| Date | Symptom | Cause | Fix |
| --- | --- | --- | --- |
| 2026-11-04 | The first BAR0 read after reset returned the right value; every later BAR0 read returned `0xFFFFFFFF`. BAR1 reads and BAR0 writes still worked. Long `npu-ctl` loops stalled the i.MX95. | `npu_regs` 0.1.0 raised RVALID in the same cycle as the read-address handshake. XDMA holds RREADY high between reads, so the block counted the response as delivered while XDMA had dropped it, and XDMA's AXI-Lite master waited forever. | 0.1.1 rebuilds `npu_regs` on AMD's AXI4-Lite template, which raises RVALID one cycle later. The testbench now holds RREADY high between reads and has a protocol monitor; it reports 19 errors against the old behavior. |
| 2026-11-04 | With the XDMA driver loaded, `dmatest` passed at 4 KiB and failed at every larger size: card-to-host transfers returned stale data (mostly the zeros the buffer was cleared to) in every 4 KiB page after the first. Host-to-card transfers, card memory and single-page transfers at any card offset were all correct. | A bug in AMD's XDMA driver (`dma_ip_drivers` `a918c51`), exposed by the i.MX95's IOMMU. `xdma_xfer_submit()` maps the user buffer with `dma_map_sg(..., sgt->orig_nents, ...)` and keeps the returned count in `sgt->nents`; `transfer_destroy()` then unmaps with `dma_unmap_sg(..., sgt->nents, ...)` and zeroes `nents`, so the correct unmap is skipped. The DMA API requires the count given to `dma_map_sg()`, not the one it returned. Without an IOMMU the two counts match; with the IOMMU translating, the kernel merges the buffer's pages into one DMA segment, the unmap covers only the first entry, and on this non-coherent Arm host only the first page's CPU cache lines are invalidated. How it was narrowed down: flushing the buffer's cache lines from user space (`DC CIVAC`, `sw/tools/cacheprobe`) made the data correct, so it was in memory; waiting up to 10 ms without touching the buffer did not, so the data was not arriving late; relaxed ordering, No Snoop and `poll_mode=1` made no difference; IOMMU pass-through hid the bug by preventing the merge. | `sw/patches/xdma-unmap-orig-nents.patch` unmaps with `orig_nents`. The same bug and fix were already reported upstream in [Xilinx/dma_ip_drivers#386](https://github.com/Xilinx/dma_ip_drivers/issues/386) (2026-05-15, still open); this project found it independently and applies the fix locally. With it, and the IOMMU translating, `cacheprobe` passes, `dmatest` passes up to 4 MiB (377 MB/s to the card, 340 MB/s back) and `memtest` passes over 1 GiB (2026-11-04). Until 2026-11-04 the workaround was IOMMU pass-through, still available as `imx95-load-xdma.sh <ko> passthrough` for the unpatched driver. |
| 2026-11-04 | First full build of 0.4.0 failed timing by 4.2 ns, 38 000 endpoints. | `npu_mm` computed a whole 8-byte dot product, accumulation and bias in one cycle (21 logic levels), and wrote its bias buffer twice per cycle, which turned it into 32 000 flip-flops. | A nine-stage pipeline, a 64-bit bias buffer written once per beat, addresses advanced by addition instead of multiplication. |
| 2026-11-04 | The next build still failed by 0.574 ns, 97 endpoints, every path starting at `npu_cq`'s `rd_issued` register. | The copy engine decided each read request in the same cycle as it raised ARVALID, through 32-bit subtract, compare and add chains (up to 24 logic levels). | The request is decided from registers one cycle ahead and held until accepted; countdown registers replace the subtractions. Costs one cycle per 2 KiB burst (4415 instead of 4414 cycles per 32 KiB). |
| 2026-11-04 | `npu-test nop`: from the second batch on, every completion's command ID was one ahead of the expected one. | The runtime's submit functions took a command ID before checking for room, so the call that found the SQ full used one up. A host bug; the card was right. | Check for room first (`sw/npu/npu.c`). |
| 2026-11-04 | `npu-test gemm 7 2048 1024`: every output wrong, INT8 and INT32; 64 × 832 · 832 × 128 exact. | `npu_mm` sized the C row and its write bursts from `N[9:0]`. N = 1024 is bit 10 alone, so the engine computed everything and wrote nothing. The testbench never went past N = 128. | Sizes from all 11 bits, wider counters; `tb_npu_cq` now runs K = 2048 with N = 1024 and fails on the old code. |
| 2026-11-04 | `npu-test`'s CPU reference reported 53 MMAC/s. | It read its inputs from the DMA arena, which is mapped uncached. | The reference works on cached copies: 1.5 GMAC/s, the same as `npu-mnist`'s CPU figure. |
| 2026-11-04 | With `fpga_npu.ko` loaded, the i.MX95's serial console (ttyLP0) delayed its output, releasing a little only when it received input; unloading the driver brought it back. | Not found yet, and possibly not the driver's: the same console trickled once during phase 1, before this driver existed, and a USB replug fixed it then. No interrupt storm (`/proc/interrupts`), the card's MSI does not fire while idle, and the driver does not touch the UART. | Open. Workaround on this bench: write results to files, unload the driver, then read them; or pump the console with newlines (`pull2.py` style). The i.MX95's System Manager monitor (second WCH port) can reset the SoC with `reset` when the console is unusable. |

Record each hardware result with the date, the i.MX95 BSP version, and the exact command.
