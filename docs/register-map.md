# Register map

The card exposes two memory BARs.

| BAR | Size | Contents |
| --- | --- | --- |
| BAR0 | 64 KiB | `npu_regs`, the control registers below (decoded in the first 4 KiB). |
| BAR1 | 64 KiB | XDMA's DMA engine registers, owned by the XDMA driver. See AMD PG195. |

The DMA engine's AXI4 master sees the card memory at AXI address `0x0`: since phase 2, the AC701's 1 GiB DDR3 SODIMM (`0x0000_0000` to `0x3FFF_FFFF`) through the `card_mem` block design. The file offset on `/dev/xdma0_h2c_0` and `/dev/xdma0_c2h_0` is the card address. Phase 1 used 64 KiB of block RAM at the same address.

## BAR0: `npu_regs`

All registers are 32 bits wide and must be accessed as aligned 32-bit words. Writes to read-only or unmapped offsets are ignored and still complete. Reads of unmapped offsets return `0xDEADBEEF`. The source is `hw/rtl/npu_regs.v`; change both together.

| Offset | Name | Access | Reset | Description |
| --- | --- | --- | --- | --- |
| `0x000` | ID | RO | `0x4E505530` | ASCII `NPU0`. A host tool checks this before trusting anything else. |
| `0x004` | VERSION | RO | `0x00000200` | `[23:16]` major, `[15:8]` minor, `[7:0]` patch. 0.1.x is phase 1 (0.1.1 fixed back-to-back reads; 0.1.0 answered only the first BAR0 read after reset). 0.2.0 is phase 2: DDR3 card memory. |
| `0x008` | BUILD | RO | build ID | Set at build time, by default the build hour as `YYMMDDHH` in hex digits, from the build machine's clock (`0x26110315` = 2026-11-03, hour 15). Pass another value as the second `build.tcl` argument. |
| `0x00C` | CAPS | RO | `0x04000003` | `[31:16]` card memory in MiB (1024). `[1]` card memory is DDR3. `[0]` DMA path present. Before 0.2.0, `[31:16]` counted KiB. |
| `0x010` | SCRATCH | RW | `0x00000000` | Free for read/write tests. Honors byte strobes. |
| `0x014` | CONTROL | RW | `0x00000000` | `[1:0]` drive GPIO_LED_2 and GPIO_LED_3. |
| `0x018` | STATUS | RO | — | `[0]` PCIe link up (always 1 when the host can read it). `[1]` DDR3 calibrated (MIG `init_calib_complete`). `[2]` DDR3 controller clock locked (MIG `mmcm_locked`). Bits 1 and 2 are synchronized from the MIG clock. |
| `0x020` | CYCLE_LO | RO | — | Low word of a 64-bit counter of the 125 MHz card clock, counting from reset. Reading it latches CYCLE_HI. |
| `0x024` | CYCLE_HI | RO | — | High word, as latched by the last CYCLE_LO read. Read LO then HI for one coherent sample. |
| `0x028` | IRQ | RW | `0x00000000` | `[0]` interrupt request: software holds it at 1 to raise user interrupt 0 (an MSI through XDMA) and writes 0 when serviced. `[1]` (read) XDMA acknowledged the request; write 1 to clear it. |
| `0x030` | DMA_WRITES | RO | `0x00000000` | Write bursts the DMA engine issued to card memory (AXI AW handshakes). Wraps; take differences. |
| `0x034` | DMA_READS | RO | `0x00000000` | Read bursts the DMA engine issued to card memory (AXI AR handshakes). Wraps. |
| `0x038` | DMA_ERRORS | RO | `0x00000000` | Responses to the DMA engine other than OKAY: one per write response, one per read beat. Wraps. |

## LEDs

| LED | Meaning |
| --- | --- |
| GPIO_LED_0 | PCIe link up. |
| GPIO_LED_1 | Heartbeat from the PCIe user clock, about 1 Hz. Blinking means the reference clock from the host arrives and XDMA is out of reset. |
| GPIO_LED_2, 3 | CONTROL `[1:0]`. `npu-ctl led 3` turns both on. |

## PCIe identity

| Field | Value | Why |
| --- | --- | --- |
| Vendor : device | `10ee:7021` | AMD's default for XDMA at Gen2 x1. The Xilinx XDMA Linux driver already lists it, so no driver change is needed in phase 1. A project ID will replace it when the project has its own driver. |
| Subsystem | `10ee:0007` | XDMA default. |
| Class code | `12 00 00` | Processing accelerator, what an NPU card reports. |
| Link | Gen2 (5 GT/s) x1 | Narrowest of the two ends: the i.MX95 M.2 slot is one lane, the Artix-7 GTP is Gen2. |
