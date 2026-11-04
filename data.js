// Every number on the site, with where it comes from.
//   measured: read on the bench (FRDM-i.MX95 + AC701), 2026-11-04, see docs/bringup.md
//   derived:  computed from measured numbers; the formula is given
//   spec:     from a standard or a datasheet
// Change a number here and in docs/bringup.md together.

export const REPO = "https://github.com/edgaralejod/fpga-edge-npu";
export const doc = (path) => `${REPO}/blob/main/${path}`;

export const hero = [
  { value: "1.18", unit: "µs", label: "CPU reads one card register over PCIe", kind: "measured" },
  { value: "371", unit: "MB/s", label: "DMA from the i.MX95 into card memory", kind: "measured" },
  { value: "5.9", unit: "GB/s", label: "Card DDR3 read bandwidth, inside the FPGA", kind: "measured" },
  { value: "1", unit: "GiB", label: "Card memory verified, every 64-byte beat", kind: "measured" },
];

// Time ladder: how long things take, from one FPGA clock to moving 1 GiB.
export const timeLadder = [
  { label: "One FPGA clock (125 MHz)", seconds: 8e-9, kind: "spec", note: "PCIe user clock of the card's design" },
  { label: "One 4 KiB DDR3 burst inside the card", seconds: 4096 / 5921e6, kind: "derived", note: "4096 B / 5921 MB/s (measured read bandwidth)" },
  { label: "CPU reads one card register", seconds: 1.183e-6, kind: "measured", note: "npu-ctl latency 100000, Cortex-A55 user space" },
  { label: "Fixed cost of one DMA transfer", seconds: 40e-6, kind: "derived", note: "8-byte dmatest at 0.2 MB/s: driver, descriptors, interrupt" },
  { label: "64 KiB DMA, host to card", seconds: 65536 / 292.9e6, kind: "derived", note: "65536 B / 292.9 MB/s (measured)" },
  { label: "Read all 1 GiB of DDR3 inside the card", seconds: 1073741824 / 5921e6, kind: "derived", note: "1 GiB / 5921 MB/s (measured)" },
  { label: "Move 1 GiB over the PCIe link", seconds: 1073741824 / 371e6, kind: "derived", note: "1 GiB / 371 MB/s (measured DMA)" },
];

// Bandwidth: measured against the limit that applies to each path.
export const bandwidth = [
  { label: "DMA host → card", mbs: 377, limit: 500, kind: "measured", limitNote: "Gen2 x1: 5 GT/s, 8b/10b coding (spec)", note: "4 MiB transfers, IOMMU translating" },
  { label: "DMA card → host", mbs: 340, limit: 500, kind: "measured", limitNote: "Gen2 x1: 5 GT/s, 8b/10b coding (spec)", note: "4 MiB transfers, IOMMU translating" },
  { label: "DDR3 write, inside the card", mbs: 5468, limit: 6400, kind: "measured", limitNote: "800 MT/s × 8 bytes (spec)", note: "mem_bw, 1 GiB, 512-bit bursts" },
  { label: "DDR3 read, inside the card", mbs: 5921, limit: 6400, kind: "measured", limitNote: "800 MT/s × 8 bytes (spec)", note: "mem_bw, 1 GiB, every beat checked" },
];

// DMA throughput against transfer size (DDR3 card memory, docs/bringup.md phase 2).
export const dmaBySize = {
  sizes: [4096, 65536, 1048576, 4194304, 16777216],
  series: [
    { name: "Host → card", key: "h2c", values: [77.5, 292.9, 342.4, 368.8, 371.0] },
    { name: "Card → host", key: "c2h", values: [80.2, 291.4, 339.0, 332.5, 325.4] },
  ],
};

// Card-side bandwidth against bursts in flight (mem_bw).
export const burstsInFlight = [
  { bursts: 1, write: 4227, read: 3629 },
  { bursts: 2, write: 5468, read: 5921 },
  { bursts: 16, write: 5468, read: 5921 },
];
