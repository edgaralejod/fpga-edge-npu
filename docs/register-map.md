# Register map

Since phase 3 (version 0.4.0) the card exposes one memory BAR.

| BAR | Size | Contents |
| --- | --- | --- |
| BAR0 | 64 KiB | `npu_regs`, the control registers below (decoded in the first 4 KiB), through the `axi_pcie` bridge's AXI master and an AXI4-Lite converter. |

The card moves data itself: its command queue engine (`npu_cq`) reads and writes host memory through the bridge's slave window (AXI `0x8000_0000` to `0xFFFF_FFFF` reaches host bus addresses `0` to `0x7FFF_FFFF`) and card memory at AXI address `0x0`: the AC701's 1 GiB DDR3 SODIMM (`0x0000_0000` to `0x3FFF_FFFF`). Commands carry both kinds of address; see the [command queue](command-queue.md).

Phases 1 and 2 (versions 0.1 to 0.3) used AMD's XDMA core instead, with a second BAR (BAR1, 64 KiB) holding XDMA's DMA engine, and the host's XDMA driver moving the data; phase 1 had 64 KiB of block RAM as card memory.

## BAR0: `npu_regs`

All registers are 32 bits wide and must be accessed as aligned 32-bit words. Writes to read-only or unmapped offsets are ignored and still complete. Reads of unmapped offsets return `0xDEADBEEF`. The source is `hw/rtl/npu_regs.v`; change both together.

| Offset | Name | Access | Reset | Description |
| --- | --- | --- | --- | --- |
| `0x000` | ID | RO | `0x4E505530` | ASCII `NPU0`. A host tool checks this before trusting anything else. |
| `0x004` | VERSION | RO | `0x00000500` | `[23:16]` major, `[15:8]` minor, `[7:0]` patch. 0.1.x is phase 1 (0.1.1 fixed back-to-back reads; 0.1.0 answered only the first BAR0 read after reset). 0.2.0 is phase 2: DDR3 card memory. 0.3.0 adds the card-side bandwidth engine (`BW_*`). 0.4.0 is phase 3: the command queue (`CQ_*`), the GEMM engine, and the `axi_pcie` bridge in place of XDMA. 0.5.0: the GEMM engine works on tiles of 8 rows of A (64 MACs per cycle instead of 8); no register changes. |
| `0x008` | BUILD | RO | build ID | Set at build time, by default the build hour as `YYMMDDHH` in hex digits, from the build machine's clock (`0x26110315` = 2026-11-03, hour 15). Pass another value as the second `build.tcl` argument. |
| `0x00C` | CAPS | RO | `0x0400000F` | `[31:16]` card memory in MiB (1024). `[3]` GEMM engine. `[2]` command queue. `[1]` card memory is DDR3. `[0]` DMA path present. Before 0.2.0, `[31:16]` counted KiB. |
| `0x010` | SCRATCH | RW | `0x00000000` | Free for read/write tests. Honors byte strobes. |
| `0x014` | CONTROL | RW | `0x00000000` | `[1:0]` drive GPIO_LED_2 and GPIO_LED_3. |
| `0x018` | STATUS | RO | — | `[0]` PCIe link up (always 1 when the host can read it). `[1]` DDR3 calibrated (MIG `init_calib_complete`). `[2]` DDR3 controller clock locked (MIG `mmcm_locked`). Bits 1 and 2 are synchronized from the MIG clock. |
| `0x020` | CYCLE_LO | RO | — | Low word of a 64-bit counter of the 125 MHz card clock, counting from reset. Reading it latches CYCLE_HI. |
| `0x024` | CYCLE_HI | RO | — | High word, as latched by the last CYCLE_LO read. Read LO then HI for one coherent sample. |
| `0x028` | IRQ | RW | `0x00000000` | Interrupt test. `[0]`: a 0 to 1 change raises one MSI (through `npu_cq`'s interrupt requester since 0.4.0; XDMA's user interrupt 0 before); write 0 before raising another. `[1]` (read) the bridge granted an MSI; write 1 to clear it. |
| `0x030` | DMA_WRITES | RO | `0x00000000` | Write bursts into card memory from the DMA path (AXI AW handshakes): `npu_cq`'s card port (copies and GEMM) since 0.4.0, XDMA's AXI master before. Wraps; take differences. |
| `0x034` | DMA_READS | RO | `0x00000000` | Read bursts from card memory on the same path (AXI AR handshakes). Wraps. |
| `0x038` | DMA_ERRORS | RO | `0x00000000` | Responses on that path other than OKAY: one per write response, one per read beat. Wraps. |
| `0x040` | BW_CTRL | RW | `0x00000000` | `mem_bw`, the card-side DDR3 bandwidth engine. Write: `[0]` START (one-cycle pulse), `[1]` mode (0 write the pattern, 1 read and check it), `[12:8]` bursts in flight (1 to 16; 0 means 16), `[31:16]` pattern seed. Read: the same fields, with `[0]` = busy. Writes to `BW_CTRL`, `BW_ADDR` and `BW_LEN` are ignored while busy. |
| `0x044` | BW_ADDR | RW | `0x00000000` | Start address in card memory, bytes. The low 12 bits are ignored (4 KiB bursts). |
| `0x048` | BW_LEN | RW | `0x00000000` | Length in bytes, a multiple of 4 KiB; up to the 1 GiB of card memory. |
| `0x04C` | BW_RUNS | RO | `0x00000000` | Completed runs. It increments when a run's results are in `BW_CYCLES`, `BW_MISMATCH` and `BW_ERRORS`. |
| `0x050` | BW_CYCLES | RO | — | Cycles of the engine's clock from the start of the last run to its last response. Bandwidth = `BW_LEN` / (`BW_CYCLES` / `BW_CLK_KHZ` / 1000). |
| `0x054` | BW_MISMATCH | RO | — | 64-byte beats of the last read run that differed from the pattern for that address and seed. |
| `0x058` | BW_ERRORS | RO | — | AXI responses other than OKAY in the last run: one per write burst, one per read beat. |
| `0x05C` | BW_CLK_KHZ | RO | `100000` | Frequency of the engine's clock, the MIG's 100 MHz `ui_clk`. |
| `0x080` | CQ_CTRL | RW | `0x00000000` | Command queue. `[0]` enable: a 0 to 1 change resets both rings (indices 0, phase 1) and `CQ_COMPLETED`. `[1]` interrupts enabled (commands with `flags[0]` raise an MSI when they complete). |
| `0x084` | CQ_ENTRIES_LOG2 | RW | `0x00000000` | Ring size, 2^n entries, n from 1 to 12, for both rings. Ignores writes while enabled. |
| `0x088` | CQ_SQ_BASE_LO | RW | `0x00000000` | Submission ring bus address, low word (64-byte aligned). Ignores writes while enabled. |
| `0x08C` | CQ_SQ_BASE_HI | RW | `0x00000000` | High word; must be 0, and the ring below 2 GiB (the bridge window). |
| `0x090` | CQ_CQ_BASE_LO | RW | `0x00000000` | Completion ring bus address, low word (16-byte aligned). Ignores writes while enabled. |
| `0x094` | CQ_CQ_BASE_HI | RW | `0x00000000` | High word; as `CQ_SQ_BASE_HI`. |
| `0x098` | CQ_SQ_TAIL | WO | — | Doorbell: the host's new submission-ring tail. Reads 0. |
| `0x09C` | CQ_CQ_HEAD | WO | — | Doorbell: the host's new completion-ring head, releasing slots. Reads 0. |
| `0x0A0` | CQ_STATUS | RO | — | `[0]` busy, `[1]` stalled on a full completion ring, `[2]` AXI error seen (sticky until re-enabled), `[3]` ring settings invalid (the queue does not run). |
| `0x0A4` | CQ_COMPLETED | RO | `0x00000000` | Completions written since the queue was enabled (counted when the write is acknowledged). |

## LEDs

| LED | Meaning |
| --- | --- |
| GPIO_LED_0 | PCIe link up. |
| GPIO_LED_1 | Heartbeat from the PCIe user clock, about 1 Hz. Blinking means the reference clock from the host arrives and XDMA is out of reset. |
| GPIO_LED_2, 3 | CONTROL `[1:0]`. `npu-ctl led 3` turns both on. |

## PCIe identity

| Field | Value | Why |
| --- | --- | --- |
| Vendor : device | `10ee:ed10` | Since 0.4.0. `10ee` is AMD's vendor ID, the bridge core's default on this development board; `ed10` is not an ID AMD has assigned, so AMD's stock drivers do not bind and the project's `fpga-npu` driver does. A product would need its own vendor ID. Phases 1 and 2 used `10ee:7021`, XDMA's default, for AMD's XDMA driver. |
| Subsystem | `10ee:0007` | The core default. |
| Class code | `12 00 00` | Processing accelerator, what an NPU card reports. |
| Link | Gen2 (5 GT/s) x1 | Narrowest of the two ends: the i.MX95 M.2 slot is one lane, the Artix-7 GTP is Gen2. |
