// Every number on the site, with where it comes from.
//   measured: read on the bench (FRDM-i.MX95 + AC701), 2026-11-04, see docs/bringup.md
//   derived:  computed from measured numbers; the formula is given
//   spec:     from a standard or a datasheet
// Change a number here and in docs/bringup.md together.

export const REPO = "https://github.com/edgaralejod/fpga-edge-npu";
export const doc = (path) => `${REPO}/blob/main/${path}`;

export const hero = [
  { value: "55 032", unit: "images/s", label: "MNIST on the card, 97.11 %, bit-exact with the CPU", kind: "measured" },
  { value: "6.5", unit: "GMAC/s", label: "INT8 matrix multiply on the card, of 8 peak", kind: "measured" },
  { value: "3.8", unit: "µs", label: "One command: doorbell, fetch, run, completion", kind: "measured" },
  { value: "419", unit: "MB/s", label: "Card copies from host memory over PCIe Gen2 ×1", kind: "measured" },
];

// Time ladder: how long things take, from one FPGA clock to moving 1 GiB.
export const timeLadder = [
  { label: "One FPGA clock (125 MHz)", seconds: 8e-9, kind: "spec", note: "PCIe user clock of the card's design" },
  { label: "One 4 KiB DDR3 burst inside the card", seconds: 4096 / 5921e6, kind: "derived", note: "4096 B / 5921 MB/s (measured read bandwidth)" },
  { label: "CPU reads one card register", seconds: 1.183e-6, kind: "measured", note: "npu-ctl latency 100000, Cortex-A55 user space" },
  { label: "One command through the queue, polling", seconds: 3.83e-6, kind: "measured", note: "npu-test latency: doorbell to completion seen, median of 2000" },
  { label: "Same, sleeping on the interrupt", seconds: 12.1e-6, kind: "measured", note: "npu-test latency with the MSI, median of 2000" },
  { label: "Fixed cost of one XDMA transfer (phase 2)", seconds: 40e-6, kind: "derived", note: "8-byte dmatest at 0.2 MB/s: driver, descriptors, interrupt" },
  { label: "One MNIST image on the card, round trip", seconds: 155.3e-6, kind: "measured", note: "npu-mnist: upload, 2 GEMMs, download, argmax; median of 200" },
  { label: "All 10 000 MNIST test images on the card", seconds: 0.2081, kind: "measured", note: "npu-mnist, card 0.5.0: upload, both layers, download" },
  { label: "Read all 1 GiB of DDR3 inside the card", seconds: 1073741824 / 5921e6, kind: "derived", note: "1 GiB / 5921 MB/s (measured)" },
  { label: "Move 1 GiB over the PCIe link", seconds: 1073741824 / 371e6, kind: "derived", note: "1 GiB / 371 MB/s (measured DMA)" },
];

// Bandwidth: measured against the limit that applies to each path.
export const bandwidth = [
  { label: "Copy host → card", mbs: 419.2, limit: 500, kind: "measured", limitNote: "Gen2 x1: 5 GT/s, 8b/10b coding (spec)", note: "npu_cq COPY_H2C, 8 MiB, IOMMU translating" },
  { label: "Copy card → host", mbs: 416.2, limit: 500, kind: "measured", limitNote: "Gen2 x1: 5 GT/s, 8b/10b coding (spec)", note: "npu_cq COPY_C2H, 8 MiB, IOMMU translating" },
  { label: "DDR3 write, inside the card", mbs: 5468, limit: 6400, kind: "measured", limitNote: "800 MT/s × 8 bytes (spec)", note: "mem_bw, 1 GiB, 512-bit bursts" },
  { label: "DDR3 read, inside the card", mbs: 5921, limit: 6400, kind: "measured", limitNote: "800 MT/s × 8 bytes (spec)", note: "mem_bw, 1 GiB, every beat checked" },
];

// XDMA throughput against transfer size (phase 2, DDR3 card memory, docs/bringup.md).
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

// MNIST on the card (docs/bringup.md, phase 4; npu-mnist output). null until measured.
export const mnist = {
  accuracy: 97.11,          // bit-exact model, 10 000 test images (train.py); the card matches it
  cardLatencyUs: 155,       // one image on the card, host round trip, median of 200 (npu-mnist)
  // Throughput over the 10 000 test images, both layers (npu-mnist, 2026-11-04)
  throughput: [
    { label: "Card 0.5.0: 8-row tiles", ips: 55032, mmacs: 6311, note: "64 MACs per clock; weights read once per 8 images" },
    { label: "One Cortex-A55 core", ips: 13595, mmacs: 1559, note: "scalar C, -O2 (the compiler vectorizes with NEON)" },
    { label: "Card 0.4.0: one row at a time", ips: 7486, mmacs: 859, note: "8 MACs per clock; weights read once per image" },
  ],
};

// One inference on the card: the TRACE line of npu-mnist, pasted as is. null until measured.
export const trace = {"image":199,"label":2,"pred":2,"host_us":{"prepare":0.00,"doorbell":0.33,"done":155.33},"card_us":[{"cmd":"COPY_H2C image","fetch":0.000,"done":5.488},{"cmd":"GEMM layer 1","fetch":7.376,"done":130.960},{"cmd":"GEMM layer 2","fetch":132.856,"done":144.936},{"cmd":"COPY_C2H logits","fetch":146.832,"done":148.272}]};   // card 0.5.0, 2026-11-04
