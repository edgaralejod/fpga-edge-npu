import { hero, timeLadder, bandwidth, dmaBySize, mnist, doc } from "./data.js";

const SVGNS = "http://www.w3.org/2000/svg";
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const el = (tag, attrs = {}, parent) => {
  const e = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  if (parent) parent.appendChild(e);
  return e;
};
const html = (s) => { const t = document.createElement("template"); t.innerHTML = s.trim(); return t.content.firstElementChild; };
const tagHTML = (kind) => `<span class="tag ${kind}">${kind}</span>`;

// ---------------------------------------------------------------------------
// Hero
document.getElementById("hero-stats").append(...hero.map((h) => html(`
  <div class="stat"><div><span class="v">${h.value}</span><span class="u">${h.unit}</span></div>
  <div class="l">${h.label} ${tagHTML(h.kind)}</div></div>`)));

// ---------------------------------------------------------------------------
// System blocks
const DOMAIN = { host: "var(--host)", link: "var(--link)", card: "var(--card)", mem: "var(--mem)", debug: "var(--debug)" };
const NODES = {
  cpu:  { x: 40,  y: 70,  w: 190, name: "CPU + caches", meta: "6× Cortex-A55, L1/L2/L3", domain: "host" },
  dram: { x: 40,  y: 340, w: 190, name: "Host DRAM", meta: "8 GB LPDDR4X", domain: "mem" },
  smmu: { x: 250, y: 340, w: 170, name: "SMMU (IOMMU)", meta: "Arm SMMUv3", domain: "host" },
  rc:   { x: 250, y: 205, w: 170, name: "PCIe root complex", meta: "i.MX95, Gen3-capable", domain: "host" },
  ep:   { x: 560, y: 205, w: 170, name: "PCIe bridge", meta: "AMD axi_pcie, 10ee:ed10", domain: "card" },
  cq:   { x: 560, y: 340, w: 170, name: "npu_cq", meta: "command queue + DMA", domain: "card" },
  regs: { x: 560, y: 70,  w: 170, name: "npu_regs", meta: "BAR0 control", domain: "card" },
  sc:   { x: 780, y: 205, w: 180, name: "AXI interconnect", meta: "SmartConnect, 3 masters", domain: "card" },
  bw:   { x: 780, y: 70,  w: 180, name: "mem_bw", meta: "512-bit burst engine", domain: "card" },
  dbg:  { x: 780, y: 340, w: 180, name: "Debug cores", meta: "2 ILAs, VIO, JTAG-AXI", domain: "debug" },
  mig:  { x: 1000, y: 205, w: 160, name: "Memory controller", meta: "AMD MIG, 100 MHz", domain: "mem" },
  ddr:  { x: 1000, y: 340, w: 160, name: "DDR3 1 GiB", meta: "800 MT/s, 64-bit", domain: "mem" },
  npu:  { x: 1000, y: 70,  w: 160, name: "npu_mm", meta: "INT8 GEMM engine", domain: "card" },
};
const H = 76;
const center = (id) => { const n = NODES[id]; return [n.x + n.w / 2, n.y + H / 2]; };
const EDGES = [["cpu", "rc"], ["cpu", "dram"], ["dram", "smmu"], ["smmu", "rc"], ["rc", "ep", "link"], ["ep", "regs"], ["ep", "cq"],
  ["regs", "cq"], ["cq", "sc"], ["bw", "sc"], ["dbg", "sc"], ["sc", "mig"], ["mig", "ddr"], ["npu", "sc"], ["regs", "bw"]];
const edgeKey = (a, b) => [a, b].sort().join("-");

const INFO = {
  cpu: {
    p: "Six Cortex-A55 cores run Linux, the driver and the runtime. To the CPU the card is a range of physical addresses. A register access is an uncached load or store into that range, and the core stalls until the answer comes back across the link. To give the card work, the runtime writes commands into memory and rings a doorbell; it never waits on a register read.",
    facts: [["Register read, round trip", "1.18 µs", "measured"], ["One command, doorbell to completion seen", "3.83 µs", "measured"], ["Same, sleeping on the interrupt", "13.8 µs", "measured"]],
    found: "Phase 2: the CPU's caches were where the XDMA driver bug showed up: card data was in DRAM, but the CPU kept reading old copies from its cache.",
  },
  dram: {
    p: "Host memory holds the card's queues and buffers: the fpga-npu driver allocates a 32 MiB arena the card can reach and maps it, uncached, into the runtime. The submission queue (64-byte commands), the completion queue (16-byte entries) and every tensor live there. Because the CPU never caches the arena, no cache maintenance is needed: the trap the XDMA driver fell into cannot happen.",
    facts: [["Size", "8 GB LPDDR4X", "spec"], ["DMA arena", "32 MiB, uncached", "measured"]],
  },
  smmu: {
    p: "The IOMMU translates the addresses the card uses (I/O virtual addresses) into physical ones, so the card can only reach buffers the driver mapped for it. It also lets the kernel present scattered 4 KiB pages as one contiguous range to the card.",
    facts: [["Card's stream ID", "0x11", "measured"], ["Arena, as the card sees it", "bus 0x7e000000, contiguous", "measured"]],
    found: "Phase 2: merging 16 pages into one range exposed a bug in AMD's XDMA driver: it released buffers using the merged count, so the CPU cache was refreshed for the first page only. Fixed with a two-line patch. Since phase 3 the project's own driver keeps the IOMMU translating.",
  },
  rc: {
    p: "The i.MX95's PCIe controller turns CPU loads and stores into PCIe requests, and the card's DMA requests into memory accesses. The M.2 slot is wired for one lane; the controller can run Gen3, but the Artix-7 tops out at Gen2.",
    facts: [["Link trained at", "5 GT/s × 1", "measured"], ["Controller capability", "8 GT/s", "measured"]],
  },
  ep: {
    p: "AMD's AXI Memory Mapped to PCI Express bridge is the card's PCIe endpoint, and only a bridge: no DMA engine of its own. Host reads and writes to BAR0 come out as AXI accesses to the card's registers; AXI accesses from the card's npu_cq go out as PCIe reads and writes of host memory. Moving data is the card's own job.",
    facts: [["PCI ID, class", "10ee:ed10, 12 00 00", "measured"], ["Link", "5 GT/s × 1, MSI", "measured"], ["AXI side", "64 bits at 125 MHz", "spec"]],
    found: "Phases 1 and 2 used AMD's XDMA core here, with its own DMA engine and driver; phase 3 replaced it so the card can fetch its own commands.",
  },
  regs: {
    p: "The card's control registers: identity, version, a cycle counter, interrupt control, memory status, DMA counters, the bandwidth engine's controls, and the command queue's: where the rings are, how big, and the two doorbells. Writing SQ_TAIL is the only thing the host does to start work.",
    facts: [["Version on the card", "0.5.0", "measured"], ["Write/read test", "10⁶ writes, 0 errors", "measured"]],
    found: "Version 0.1.0 answered a read in the same clock cycle as its address. AXI forbids it; XDMA dropped the answer and every later read returned 0xFFFFFFFF. Rebuilt on AMD's AXI4-Lite template.",
  },
  sc: {
    p: "AMD's SmartConnect joins three masters to the memory controller: npu_cq's card port (64 bits at 125 MHz, shared by its copies and the GEMM engine), the bandwidth engine (512 bits at 100 MHz) and the JTAG-to-AXI master. It converts widths and crosses clock domains.",
    facts: [["Masters", "3", "spec"], ["Error responses after GBs of DMA", "0", "measured"]],
  },
  bw: {
    p: "A small engine written for this project. It issues 4 KiB, 512-bit bursts straight into the memory controller, up to 16 in flight, checks every 64-byte beat it reads back, and times itself with a cycle counter. Its burst logic is the start of the compute engine's data movement.",
    facts: [["DDR3 write", "5468 MB/s", "measured"], ["DDR3 read", "5921 MB/s", "measured"], ["One burst in flight, read", "3629 MB/s", "measured"]],
    found: "Checked against AMD's AXI4 master template, it held write data until the address was accepted. AXI allows a slave to wait for the data first, so the two could deadlock. Fixed, with a test that deadlocks on the old code.",
  },
  dbg: {
    p: "Two System ILAs (logic analyzers with AXI protocol checkers) watch both sides of the interconnect. A VIO shows memory calibration and resets the controller; a JTAG-to-AXI master reads and writes DDR3 from Vivado. They run on their own 78 MHz clock, so they work with no host attached.",
    facts: [["Capture depth", "2048 and 1024 samples", "spec"], ["DDR3 test over JTAG", "29 addresses × 5 patterns", "measured"]],
  },
  cq: {
    p: "The card's command processor, written for this project. After a doorbell it fetches each 64-byte command from the host's submission queue over PCIe, runs it (NOP, a copy either way between host and card memory, or a GEMM on npu_mm), and writes a 16-byte completion with a phase bit, its status and two timestamps back into host memory, with an MSI if asked. Copies stream through an 8 KiB FIFO in 2 KiB bursts, up to four reads in flight.",
    facts: [["Commands per second (NOPs)", "503 000", "measured"], ["Copy, host to card, 8 MiB", "419 MB/s", "measured"], ["Copy, card to host, 8 MiB", "416 MB/s", "measured"], ["Executing a NOP", "8 ns (1 cycle)", "measured"]],
    found: "Its copy engine first missed timing at 125 MHz: deciding the next read took a chain of 32-bit subtracts and compares in one clock cycle. The decision is now made from registers a cycle early.",
  },
  mig: {
    p: "AMD's Memory Interface Generator drives the DDR3 module: it calibrates the timing of every data line at power-up, refreshes the memory, and schedules reads and writes. Its user side is 512 bits wide at 100 MHz.",
    facts: [["Calibration", "first power-up", "measured"], ["User clock", "100 MHz", "spec"]],
  },
  ddr: {
    p: "A 1 GiB DDR3 SODIMM on the AC701: where weights and activations will live once the card computes. Its peak is 6.4 GB/s; the card reaches 85 to 93 % of it, sixteen times what the PCIe link can deliver.",
    facts: [["Peak", "6400 MB/s", "spec"], ["Read, measured inside the card", "5921 MB/s", "measured"], ["Verified", "1 GiB, every beat", "measured"]],
  },
  npu: {
    p: "The part that computes: C = A · Bᵀ + bias in INT8 with INT32 sums, then scaled, rounded, ReLU'd and clamped back to INT8, or kept as INT32. It works on tiles of 8 rows of A: each 8-byte beat of weights read from DDR3 meets 8 rows at once, 64 multiply-accumulates per clock. Checked bit for bit against a Python model, in simulation and on the card.",
    facts: [["Multipliers", "64 DSP slices of 740", "measured"], ["Peak", "64 MAC × 125 MHz = 8 GMAC/s", "derived"]],
    found: "The first version wrote nothing for N = 1024: it sized the output from N's low 10 bits, which are all zero. Found by npu-test on the card; the testbench now covers the limits.",
  },
};

const DOMAIN_LABEL = { host: "Host · i.MX95", link: "PCIe link", card: "Card · Artix-7", mem: "Memory", debug: "Debug" };

function buildDiagram(svg, { interactive }) {
  const regions = el("g", { class: "region" }, svg);
  el("rect", { x: 20, y: 30, width: 420, height: 410, rx: 16 }, regions);
  el("text", { x: 36, y: 56 }, regions).textContent = "FRDM-i.MX95 · host";
  el("rect", { x: 540, y: 30, width: 640, height: 410, rx: 16 }, regions);
  el("text", { x: 556, y: 56 }, regions).textContent = "AC701 · Artix-7 200T · card";
  const edges = el("g", {}, svg);
  const edgeEls = {};
  for (const [a, b, kind] of EDGES) {
    const [x1, y1] = center(a), [x2, y2] = center(b);
    edgeEls[edgeKey(a, b)] = el("line", { x1, y1, x2, y2, class: `edge${kind ? " " + kind : ""}` }, edges);
  }
  const lbl = el("text", { x: 490, y: 196, "text-anchor": "middle", class: "link-label" }, svg);
  lbl.textContent = "PCIe Gen2 ×1";
  el("text", { x: 490, y: 282, "text-anchor": "middle", class: "link-label", opacity: 0.75 }, svg).textContent = "500 MB/s max";
  // The packet is drawn under the blocks: it travels along the connections and
  // disappears into a block when it arrives, which then lights up.
  const packet = el("circle", { r: 7, class: "packet", cx: -20, cy: -20 }, svg);
  const nodeEls = {};
  for (const [id, n] of Object.entries(NODES)) {
    const g = el("g", { class: `node${n.future ? " future" : ""}`, "data-id": id }, svg);
    el("rect", { class: "box", x: n.x, y: n.y, width: n.w, height: H, rx: 12 }, g);
    el("rect", { class: "stripe", x: n.x + 12, y: n.y + 12, width: 22, height: 4, rx: 2, fill: DOMAIN[n.domain] }, g);
    el("text", { class: "name", x: n.x + 12, y: n.y + 40 }, g).textContent = n.name;
    el("text", { class: "meta", x: n.x + 12, y: n.y + 60 }, g).textContent = n.meta;
    if (interactive) {
      g.setAttribute("tabindex", "0");
      g.setAttribute("role", "button");
      g.setAttribute("aria-label", `${n.name}: ${n.meta}`);
    }
    nodeEls[id] = g;
  }
  return { nodeEls, edgeEls, packet };
}

// Interactive map
const sys = buildDiagram(document.getElementById("diagram"), { interactive: true });
const detail = document.getElementById("detail");
function showInfo(id) {
  const n = NODES[id], info = INFO[id];
  for (const [k, g] of Object.entries(sys.nodeEls)) g.classList.toggle("selected", k === id);
  detail.innerHTML = `
    <div class="head"><div class="kicker" style="color:${DOMAIN[n.domain]}">${DOMAIN_LABEL[n.domain]}</div><h3>${n.name}</h3></div>
    <div><p>${info.p}</p>${info.found ? `<div class="found"><b>Found here.</b> ${info.found}</div>` : ""}</div>
    <div><ul class="facts">${info.facts.map(([k, v, kind]) => `<li><span class="k">${k}</span><span class="val">${v} ${tagHTML(kind)}</span></li>`).join("")}</ul></div>`;
}
for (const [id, g] of Object.entries(sys.nodeEls)) {
  g.addEventListener("click", () => showInfo(id));
  g.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); showInfo(id); } });
}
showInfo("smmu");

// ---------------------------------------------------------------------------
// Data-flow journeys
const FLOWS = [
  {
    id: "reg", name: "CPU reads a register", total: "1.18 µs round trip, measured",
    steps: [
      { path: ["cpu", "rc"], text: "The CPU executes a load from the card's BAR0 address range. The mapping is uncached, so the core waits for the real answer." },
      { path: ["rc", "ep"], text: "The root complex turns the load into a PCIe Memory Read request and sends it over the single 5 GT/s lane." },
      { path: ["ep", "regs"], text: "The endpoint turns the request into an AXI-Lite read of npu_regs, which answers one clock cycle after the address handshake." },
      { path: ["regs", "ep"], text: "The value returns to the endpoint, which builds a Completion with Data." },
      { path: ["ep", "rc"], text: "The completion crosses the link back to the root complex." },
      { path: ["rc", "cpu"], text: "The load retires with the value.", t: "Whole trip: 1.18 µs, about 148 periods of the card's 125 MHz clock." },
    ],
  },
  {
    id: "cmd", name: "One command, start to finish", total: "3.83 µs round trip, median of 2000, measured; 503 000 commands/s in batches",
    steps: [
      { path: ["cpu", "dram"], text: "The runtime writes a 64-byte command into the next slot of the submission queue, in the uncached DMA arena, and makes sure the write has landed (dsb st)." },
      { path: ["cpu", "rc"], text: "One store to the SQ_TAIL doorbell in BAR0 becomes a posted PCIe write: the CPU does not wait for it." },
      { path: ["rc", "ep"], text: "The write crosses the link to the bridge." },
      { path: ["ep", "regs"], text: "The bridge turns it into an AXI-Lite write; npu_regs passes the new tail to npu_cq." },
      { path: ["regs", "cq"], text: "npu_cq sees the submission queue is not empty and starts a fetch." },
      { path: ["cq", "ep"], text: "It reads the 64-byte command as one 8-beat AXI burst; the bridge sends a PCIe Memory Read." },
      { path: ["rc", "dram"], text: "The root complex reads the slot from DRAM through the IOMMU, and a completion carries the command back.", t: "A full PCIe read round trip: the largest part of the 3.83 µs" },
      { path: ["ep", "cq"], text: "npu_cq decodes and runs the command. A NOP takes one cycle; copies and GEMMs take longer." },
      { path: ["cq", "rc"], text: "It writes a 16-byte completion into the completion queue: status, two timestamps, and a phase bit that flips each time round the ring." },
      { path: ["dram", "cpu"], text: "The CPU, polling that entry, sees the phase bit change, reads the result, and writes CQ_HEAD to free the slot.", t: "Sleeping on the MSI instead: 13.8 µs" },
    ],
  },
  {
    id: "copy", name: "Copy: host to card", total: "419 MB/s at 8 MiB, card timestamps, measured",
    steps: [
      { path: ["cpu", "dram"], text: "The data is already in the DMA arena; the CPU writes one COPY_H2C command (length, host bus address, card address) and rings the doorbell." },
      { path: ["cq", "ep"], text: "npu_cq fetches the command, then issues 2 KiB reads of the source, up to four in flight." },
      { path: ["ep", "rc"], text: "The bridge turns them into PCIe Memory Reads." },
      { path: ["smmu", "dram"], text: "The IOMMU translates each address into the arena's physical pages." },
      { path: ["rc", "ep"], text: "Completions carry the data back across the link.", t: "Gen2 ×1 carries at most 500 MB/s; the copy reaches 419" },
      { path: ["ep", "cq"], text: "The data streams into an 8 KiB FIFO; as soon as a burst's worth is in, npu_cq writes it out." },
      { path: ["cq", "sc"], text: "The interconnect widens it from 64 to 512 bits and moves it to the memory clock." },
      { path: ["mig", "ddr"], text: "The data lands in DDR3; npu_cq writes the completion." },
    ],
  },
  {
    id: "gemm", name: "GEMM inside the card", total: "64 multiply-accumulates per clock at 125 MHz, from card memory",
    steps: [
      { path: ["cpu", "rc"], text: "The host submits a GEMM command: M, K, N, four card addresses (A, weights, bias, C) and the scale. Nothing else crosses the link." },
      { path: ["ep", "cq"], text: "npu_cq fetches it and hands it to npu_mm, which takes over the card port." },
      { path: ["npu", "sc"], text: "npu_mm reads the bias, then 8 rows of A into block RAM." },
      { path: ["sc", "npu"], text: "It streams all the weights past those 8 rows: every 8-byte beat meets 8 bytes of each row, 64 products per clock.", t: "Weights read once per 8 rows, not once per row" },
      { path: ["npu", "sc"], text: "Each finished column of 8 sums is scaled, rounded and clamped, and the 8 rows of C are written back; then the next 8 rows." },
      { path: ["cq", "rc"], text: "When all rows are done, npu_cq writes the completion with the card's start and end timestamps." },
    ],
  },
  {
    id: "bw", name: "Card reads its own memory", total: "5.9 GB/s read, 5.5 GB/s write, measured",
    steps: [
      { path: ["cpu", "rc"], text: "The host starts a run with a few register writes: address, length, bursts in flight, start." },
      { path: ["rc", "regs"], text: "One PCIe write reaches npu_regs, which starts mem_bw." },
      { path: ["regs", "bw"], text: "mem_bw takes the settings across into the memory clock domain." },
      { path: ["bw", "sc"], text: "It issues 4 KiB bursts, 512 bits per beat, up to 16 in flight." },
      { path: ["sc", "mig"], text: "Keeping several bursts in flight hides the controller's latency.", t: "1 in flight: 3.6 GB/s · 2 or more: 5.9 GB/s" },
      { path: ["mig", "ddr"], text: "DDR3 at 800 MT/s, 6.4 GB/s peak." },
      { path: ["ddr", "bw"], text: "Every 64-byte beat read back is compared with the pattern written for its address.", t: "1 GiB in 181 ms: 16× what the PCIe link carries" },
    ],
  },
];

const flowSvg = document.getElementById("flow-diagram");
const flow = buildDiagram(flowSvg, { interactive: false });
const tabs = document.getElementById("flow-tabs");
const stepsEl = document.getElementById("flow-steps");
const totalEl = document.getElementById("flow-total");
const playBtn = document.getElementById("flow-play");
const stepBtn = document.getElementById("flow-step");
let current = FLOWS[0], stepIdx = -1, playing = false, anim = null;

function routeOf(a, b) {
  // Straight line when the blocks are joined, otherwise through the root complex or interconnect.
  if (flow.edgeEls[edgeKey(a, b)]) return [a, b];
  for (const via of ["rc", "sc", "smmu", "ep"]) {
    if (flow.edgeEls[edgeKey(a, via)] && flow.edgeEls[edgeKey(via, b)]) return [a, via, b];
  }
  return [a, b];
}
function clearLit() {
  for (const g of Object.values(flow.nodeEls)) g.classList.remove("lit");
  for (const e of Object.values(flow.edgeEls)) e.classList.remove("lit");
}
function renderSteps() {
  stepsEl.innerHTML = current.steps.map((s) => `<li>${s.text}${s.t ? `<span class="t">${s.t}</span>` : ""}</li>`).join("");
  totalEl.textContent = current.total;
}
function setStep(i, animate) {
  stepIdx = i;
  [...stepsEl.children].forEach((li, k) => { li.classList.toggle("active", k === i); li.classList.toggle("done", k < i); });
  clearLit();
  if (i < 0) { flow.packet.setAttribute("cx", -20); return Promise.resolve(); }
  const route = routeOf(...current.steps[i].path);
  route.forEach((id) => flow.nodeEls[id].classList.add("lit"));
  for (let k = 0; k + 1 < route.length; k++) flow.edgeEls[edgeKey(route[k], route[k + 1])]?.classList.add("lit");
  const pts = route.map(center);
  if (!animate || reduceMotion) {
    const [x, y] = pts[pts.length - 1];
    flow.packet.setAttribute("cx", x); flow.packet.setAttribute("cy", y);
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    const dur = 950 * (pts.length - 1);
    const t0 = performance.now();
    cancelAnimationFrame(anim);
    const tick = (now) => {
      const u = Math.min(1, (now - t0) / dur);
      const e = u < 0.5 ? 2 * u * u : 1 - Math.pow(-2 * u + 2, 2) / 2;
      const seg = Math.min(pts.length - 2, Math.floor(e * (pts.length - 1)));
      const f = e * (pts.length - 1) - seg;
      const [x1, y1] = pts[seg], [x2, y2] = pts[seg + 1];
      flow.packet.setAttribute("cx", x1 + (x2 - x1) * f);
      flow.packet.setAttribute("cy", y1 + (y2 - y1) * f);
      if (u < 1) anim = requestAnimationFrame(tick); else resolve();
    };
    anim = requestAnimationFrame(tick);
  });
}
async function play() {
  if (playing) { playing = false; playBtn.textContent = "Play"; return; }
  playing = true; playBtn.textContent = "Pause";
  if (stepIdx >= current.steps.length - 1) stepIdx = -1;
  while (playing && stepIdx < current.steps.length - 1) {
    await setStep(stepIdx + 1, true);
    if (playing) await new Promise((r) => setTimeout(r, reduceMotion ? 1600 : 650));
  }
  playing = false; playBtn.textContent = "Replay";
}
function selectFlow(f) {
  playing = false; playBtn.textContent = "Play";
  current = f;
  for (const b of tabs.children) b.setAttribute("aria-selected", b.dataset.id === f.id ? "true" : "false");
  renderSteps(); setStep(-1);
}
for (const f of FLOWS) {
  const b = html(`<button class="flow-tab" role="tab" data-id="${f.id}">${f.name}</button>`);
  b.addEventListener("click", () => selectFlow(f));
  tabs.appendChild(b);
}
playBtn.addEventListener("click", play);
stepBtn.addEventListener("click", () => { playing = false; playBtn.textContent = "Play"; setStep((stepIdx + 1) % current.steps.length, true); });
// Deep links: ?flow=cmd&step=7 opens a journey at a step.
{
  const q = new URLSearchParams(location.search);
  const f = FLOWS.find((x) => x.id === q.get("flow")) || FLOWS[0];
  selectFlow(f);
  const n = parseInt(q.get("step"), 10);
  if (n >= 1 && n <= f.steps.length) setStep(n - 1, false);
}

// ---------------------------------------------------------------------------
// Charts (hand-built SVG: hover tooltips, table views)
const fmtTime = (s) => s < 1e-6 ? `${(s * 1e9).toFixed(s < 1e-8 ? 0 : 1)} ns` : s < 1e-3 ? `${(s * 1e6).toFixed(s < 1e-5 ? 2 : 0)} µs` : s < 1 ? `${(s * 1e3).toFixed(0)} ms` : `${s.toFixed(1)} s`;
const fmtMBs = (v) => v >= 1000 ? `${(v / 1000).toFixed(2)} GB/s` : `${v.toFixed(v < 10 ? 1 : 0)} MB/s`;
const fmtSize = (b) => b >= 1048576 ? `${b / 1048576} MiB` : `${b / 1024} KiB`;

function tooltipFor(container) {
  const tip = html(`<div class="tooltip" role="status"></div>`);
  container.appendChild(tip);
  return {
    show(x, y, content) { tip.innerHTML = content; tip.style.opacity = 1;
      const w = container.clientWidth, tw = tip.offsetWidth;
      tip.style.left = `${Math.min(Math.max(8, x + 14), w - tw - 8)}px`; tip.style.top = `${y + 14}px`; },
    hide() { tip.style.opacity = 0; },
  };
}
function localXY(container, evt) { const r = container.getBoundingClientRect(); return [evt.clientX - r.left, evt.clientY - r.top]; }

function timeChart() {
  const card = document.getElementById("chart-time"), box = card.querySelector(".chart");
  const W = 1100, rowH = 46, top = 10, left = 320, right = 120, H = top + timeLadder.length * rowH + 34;
  const svg = el("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": "Horizontal bar chart on a log scale of durations from 8 ns to 2.9 s" }, box);
  const lo = -9, hi = 1;  // 1 ns .. 10 s
  const x = (s) => left + ((Math.log10(s) - lo) / (hi - lo)) * (W - left - right);
  const grid = el("g", { class: "grid" }, svg), axis = el("g", { class: "axis" }, svg);
  const ticks = [[1e-9, "1 ns"], [1e-8, "10 ns"], [1e-7, "100 ns"], [1e-6, "1 µs"], [1e-5, "10 µs"], [1e-4, "100 µs"], [1e-3, "1 ms"], [1e-2, "10 ms"], [1e-1, "100 ms"], [1, "1 s"], [10, "10 s"]];
  for (const [v, t] of ticks) {
    el("line", { x1: x(v), x2: x(v), y1: top, y2: H - 28 }, grid);
    el("text", { x: x(v), y: H - 8, "text-anchor": "middle" }, axis).textContent = t;
  }
  const tip = tooltipFor(box);
  timeLadder.forEach((d, i) => {
    const y = top + i * rowH + 10, bw = x(d.seconds) - x(1e-9);
    el("text", { class: "bar-label", x: left - 16, y: y + 15, "text-anchor": "end" }, svg).textContent = d.label;
    el("rect", { x: x(1e-9), y: y + 2, width: Math.max(4, bw), height: 18, rx: 4, fill: "var(--s1)" }, svg);
    el("text", { class: "bar-value", x: x(1e-9) + bw + 8, y: y + 16 }, svg).textContent = fmtTime(d.seconds);
    const hit = el("rect", { class: "hit", x: 0, y: y - 6, width: W, height: rowH }, svg);
    hit.addEventListener("mousemove", (e) => { const [px, py] = localXY(box, e);
      tip.show(px, py, `<div>${d.label}</div><div class="tv">${fmtTime(d.seconds)}</div><div class="tn">${d.note} · ${d.kind}</div>`); });
    hit.addEventListener("mouseleave", tip.hide);
  });
  card.querySelector(".table-view").innerHTML = `<table><tr><th>Event</th><th>Duration</th><th>Source</th><th>How</th></tr>${timeLadder.map((d) => `<tr><td>${d.label}</td><td class="num">${fmtTime(d.seconds)}</td><td>${tagHTML(d.kind)}</td><td>${d.note}</td></tr>`).join("")}</table>`;
}

function bandwidthChart() {
  const card = document.getElementById("chart-bw"), box = card.querySelector(".chart");
  const W = 1100, rowH = 58, top = 10, left = 250, right = 150, H = top + bandwidth.length * rowH + 34;
  const max = 7000;
  const svg = el("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": "Bars of measured bandwidth against each path's limit" }, box);
  const x = (v) => left + (v / max) * (W - left - right);
  const grid = el("g", { class: "grid" }, svg), axis = el("g", { class: "axis" }, svg);
  for (let v = 0; v <= max; v += 1000) {
    el("line", { x1: x(v), x2: x(v), y1: top, y2: H - 28 }, grid);
    el("text", { x: x(v), y: H - 8, "text-anchor": "middle" }, axis).textContent = v === 0 ? "0" : `${v / 1000} GB/s`;
  }
  const tip = tooltipFor(box);
  bandwidth.forEach((d, i) => {
    const y = top + i * rowH + 12;
    el("text", { class: "bar-label", x: left - 16, y: y + 15, "text-anchor": "end" }, svg).textContent = d.label;
    el("rect", { x: x(0), y: y + 2, width: x(d.limit) - x(0), height: 18, rx: 4, fill: "var(--track)" }, svg);
    el("rect", { x: x(0), y: y + 2, width: Math.max(4, x(d.mbs) - x(0)), height: 18, rx: 4, fill: "var(--s1)" }, svg);
    el("text", { class: "bar-value", x: x(d.limit) + 10, y: y + 16 }, svg).textContent = `${fmtMBs(d.mbs)} of ${fmtMBs(d.limit)}`;
    el("text", { class: "bar-sub", x: x(0), y: y + 38 }, svg).textContent = `${Math.round((100 * d.mbs) / d.limit)} % of the limit · ${d.note}`;
    const hit = el("rect", { class: "hit", x: 0, y: y - 8, width: W, height: rowH }, svg);
    hit.addEventListener("mousemove", (e) => { const [px, py] = localXY(box, e);
      tip.show(px, py, `<div>${d.label}</div><div class="tv">${fmtMBs(d.mbs)}</div><div class="tn">Limit ${fmtMBs(d.limit)}: ${d.limitNote}<br>${d.note} · measured</div>`); });
    hit.addEventListener("mouseleave", tip.hide);
  });
  card.querySelector(".table-view").innerHTML = `<table><tr><th>Path</th><th>Measured</th><th>Limit</th><th>Share</th><th>Limit from</th></tr>${bandwidth.map((d) => `<tr><td>${d.label}</td><td class="num">${fmtMBs(d.mbs)}</td><td class="num">${fmtMBs(d.limit)}</td><td class="num">${Math.round((100 * d.mbs) / d.limit)} %</td><td>${d.limitNote}</td></tr>`).join("")}</table>`;
}

function mnistChart() {
  const card = document.getElementById("chart-mnist"), box = card.querySelector(".chart");
  const rows = mnist.throughput;
  const W = 1100, rowH = 58, top = 10, left = 250, right = 150, H = top + rows.length * rowH + 34;
  const max = 60000;
  const svg = el("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": "MNIST images per second: card 0.5.0, one Cortex-A55 core, card 0.4.0" }, box);
  const x = (v) => left + (v / max) * (W - left - right);
  const grid = el("g", { class: "grid" }, svg), axis = el("g", { class: "axis" }, svg);
  for (let v = 0; v <= max; v += 10000) {
    el("line", { x1: x(v), x2: x(v), y1: top, y2: H - 28 }, grid);
    el("text", { x: x(v), y: H - 8, "text-anchor": "middle" }, axis).textContent = v === 0 ? "0" : `${v / 1000}k`;
  }
  const tip = tooltipFor(box);
  rows.forEach((d, i) => {
    const y = top + i * rowH + 12;
    el("text", { class: "bar-label", x: left - 16, y: y + 15, "text-anchor": "end" }, svg).textContent = d.label;
    el("rect", { x: x(0), y: y + 2, width: Math.max(4, x(d.ips) - x(0)), height: 18, rx: 4, fill: "var(--s1)" }, svg);
    el("text", { class: "bar-value", x: x(d.ips) + 10, y: y + 16 }, svg).textContent = `${d.ips.toLocaleString("en-US")} images/s`;
    el("text", { class: "bar-sub", x: x(0), y: y + 38 }, svg).textContent = `${(d.mmacs / 1000).toFixed(2)} GMAC/s · ${d.note}`;
    const hit = el("rect", { class: "hit", x: 0, y: y - 8, width: W, height: rowH }, svg);
    hit.addEventListener("mousemove", (e) => { const [px, py] = localXY(box, e);
      tip.show(px, py, `<div>${d.label}</div><div class="tv">${d.ips.toLocaleString("en-US")} images/s</div><div class="tn">${d.mmacs.toLocaleString("en-US")} MMAC/s · ${d.note} · measured</div>`); });
    hit.addEventListener("mouseleave", tip.hide);
  });
  card.querySelector(".table-view").innerHTML = `<table><tr><th>Runs on</th><th>Images/s</th><th>MMAC/s</th><th>Note</th></tr>${rows.map((d) => `<tr><td>${d.label}</td><td class="num">${d.ips.toLocaleString("en-US")}</td><td class="num">${d.mmacs.toLocaleString("en-US")}</td><td>${d.note}</td></tr>`).join("")}</table>`;
}

function sizeChart() {
  const card = document.getElementById("chart-size"), box = card.querySelector(".chart");
  const colors = { h2c: "var(--s1)", c2h: "var(--s2)" };
  box.appendChild(html(`<div class="legend">${dmaBySize.series.map((s) => `<span><i style="background:${colors[s.key]}"></i>${s.name}</span>`).join("")}</div>`));
  const W = 1100, H = 340, l = 70, r = 140, t = 14, b = 40;
  const svg = el("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": "Line chart of DMA throughput rising with transfer size, flattening near 370 MB/s" }, box);
  const lx0 = Math.log2(4096), lx1 = Math.log2(16777216), ymax = 500;
  const x = (s) => l + ((Math.log2(s) - lx0) / (lx1 - lx0)) * (W - l - r);
  const y = (v) => t + (1 - v / ymax) * (H - t - b);
  const grid = el("g", { class: "grid" }, svg), axis = el("g", { class: "axis" }, svg);
  for (let v = 0; v <= ymax; v += 100) {
    el("line", { x1: l, x2: W - r, y1: y(v), y2: y(v) }, grid);
    el("text", { x: l - 10, y: y(v) + 4, "text-anchor": "end" }, axis).textContent = v === 500 ? "500 MB/s" : `${v}`;
  }
  for (const s of dmaBySize.sizes) el("text", { x: x(s), y: H - 12, "text-anchor": "middle" }, axis).textContent = fmtSize(s);
  el("text", { class: "bar-sub", x: W - r + 8, y: y(500) + 4 }, svg).textContent = "link limit (spec)";
  for (const s of dmaBySize.series) {
    const d = s.values.map((v, i) => `${i ? "L" : "M"}${x(dmaBySize.sizes[i])},${y(v)}`).join(" ");
    el("path", { d, fill: "none", stroke: colors[s.key], "stroke-width": 2, "stroke-linejoin": "round" }, svg);
    s.values.forEach((v, i) => el("circle", { cx: x(dmaBySize.sizes[i]), cy: y(v), r: 4.5, fill: colors[s.key], stroke: "var(--panel)", "stroke-width": 2 }, svg));
    const last = s.values.length - 1;
    el("text", { class: "bar-value", x: W - r + 8, y: y(s.values[last]) + (s.key === "h2c" ? -4 : 14) }, svg).textContent = s.name;
  }
  const cross = el("line", { y1: t, y2: H - b, stroke: "var(--muted)", "stroke-width": 1, opacity: 0 }, svg);
  const tip = tooltipFor(box);
  const hit = el("rect", { class: "hit", x: l, y: t, width: W - l - r, height: H - t - b }, svg);
  hit.addEventListener("mousemove", (e) => {
    const pt = svg.createSVGPoint(); pt.x = e.clientX; pt.y = e.clientY;
    const sx = pt.matrixTransform(svg.getScreenCTM().inverse()).x;
    let best = 0;
    dmaBySize.sizes.forEach((s, i) => { if (Math.abs(x(s) - sx) < Math.abs(x(dmaBySize.sizes[best]) - sx)) best = i; });
    cross.setAttribute("x1", x(dmaBySize.sizes[best])); cross.setAttribute("x2", x(dmaBySize.sizes[best])); cross.setAttribute("opacity", 0.6);
    const [px, py] = localXY(box, e);
    tip.show(px, py, `<div>${fmtSize(dmaBySize.sizes[best])} transfers</div>${dmaBySize.series.map((s) => `<div class="tv">${s.name}: ${fmtMBs(s.values[best])}</div>`).join("")}<div class="tn">measured, DDR3 card memory</div>`);
  });
  hit.addEventListener("mouseleave", () => { tip.hide(); cross.setAttribute("opacity", 0); });
  card.querySelector(".table-view").innerHTML = `<table><tr><th>Transfer</th>${dmaBySize.series.map((s) => `<th>${s.name}</th>`).join("")}</tr>${dmaBySize.sizes.map((sz, i) => `<tr><td>${fmtSize(sz)}</td>${dmaBySize.series.map((s) => `<td class="num">${fmtMBs(s.values[i])}</td>`).join("")}</tr>`).join("")}</table>`;
}
mnistChart(); timeChart(); bandwidthChart(); sizeChart();
for (const btn of document.querySelectorAll(".toggle")) {
  btn.addEventListener("click", () => {
    const card = document.getElementById(btn.dataset.target);
    const tv = card.querySelector(".table-view"), ch = card.querySelector(".chart");
    const showTable = tv.hidden;
    tv.hidden = !showTable; ch.hidden = showTable;
    btn.textContent = showTable ? "Chart" : "Table";
  });
}

// ---------------------------------------------------------------------------
// Bugs found on hardware
const BUGS = [
  {
    where: "Card · npu_regs", title: "Only the first register read worked",
    symptom: "The first read after reset returned the right value; every later read returned 0xFFFFFFFF, and long loops hung the i.MX95.",
    tool: "Single-access reads from the host; LEDs showed writes still arrived, so only the read path was broken.",
    cause: "The register block raised its read response in the same clock cycle as the address handshake. AXI forbids it; XDMA, holding RREADY high, dropped the response and waited forever.",
    fix: "Rebuilt on AMD's AXI4-Lite template. The testbench now holds RREADY high like XDMA and has a protocol monitor that fails the old code.",
    link: doc("docs/bringup.md"),
  },
  {
    where: "Host · XDMA driver", title: "Card-to-host DMA came back stale",
    symptom: "With the IOMMU on, the first 4 KiB of every buffer was right and the other pages held old data. Host-to-card was always right.",
    tool: "A user-space cache flush (DC CIVAC) made the data correct, so it was in memory; waiting 10 ms did not, so it was not arriving late.",
    cause: "AMD's driver released buffers with the IOMMU-merged entry count (1) instead of the original (16), so only page 0's cache lines were invalidated.",
    fix: "A two-line patch; upstream issue Xilinx/dma_ip_drivers#386 reports the same fix. The IOMMU now stays on.",
    link: doc("sw/patches/xdma-unmap-orig-nents.patch"),
  },
  {
    where: "Card · mem_bw", title: "Write data waited for the address",
    symptom: "None on hardware: found before it shipped, by checking the engine against AMD's AXI4 master template.",
    tool: "Template comparison, then a simulated slave that waits for write data before accepting the address, as AXI allows.",
    cause: "The engine raised WVALID only after AWREADY. Against such a slave, each side waits for the other: a deadlock.",
    fix: "Write data now goes out with its address. The new test deadlocks on the old code and passes on the fixed one.",
    link: doc("hw/rtl/mem_bw.v"),
  },
  {
    where: "Card · npu_mm", title: "The widest GEMM wrote nothing",
    symptom: "On the card, every output of a 7 × 2048 · 2048 × 1024 product was wrong, in INT8 and INT32; the 832 × 128 products of the MNIST network were exact.",
    tool: "npu-test, which checks every output against the CPU. All wrong and in both formats pointed at the write side, not the arithmetic.",
    cause: "The output row's size came from bits 9 to 0 of N. N = 1024 is bit 10 alone, so the engine computed every value and wrote none of them. The testbench never went past N = 128.",
    fix: "Sizes from all 11 bits. The testbench now runs K = 2048, N = 1024 and fails on the old code.",
    link: doc("hw/rtl/npu_mm.v"),
  },
];
document.getElementById("bugs").append(...BUGS.map((b) => html(`
  <article class="bug"><div class="where">${b.where}</div><h3>${b.title}</h3>
  <dl><dt>Symptom</dt><dd>${b.symptom}</dd><dt>How it was found</dt><dd>${b.tool}</dd><dt>Cause</dt><dd>${b.cause}</dd><dt>Fix</dt><dd>${b.fix}</dd></dl>
  <a href="${b.link}">Source →</a></article>`)));

// ---------------------------------------------------------------------------
// Compared
const CMP = [
  { name: "Hailo-8", tag: "Weights on chip, layers laid out in space", rows: [["Weights", "On-chip memory, no external DRAM"], ["Execution", "Dataflow pipeline across the die"], ["Host link", "PCIe Gen3 ×2 or ×4 (M.2)"], ["Strength", "Predictable latency for models that fit"]] },
  { name: "Ara-2", tag: "Weights in DRAM, a programmable engine", rows: [["Weights", "16 GB module memory (ARA2-M2-16G-GT)"], ["Execution", "Engine streams weights from DRAM"], ["Host link", "PCIe Gen4 ×4 or USB 3.2"], ["Rated", "Up to 40 TOPS"]] },
  { name: "This card", tag: "Artix-7 on the bench, both roles at small scale", ours: true, rows: [["Weights", "1 GiB DDR3 at 5.9 GB/s, or block RAM"], ["Execution", "INT8 GEMM, 64 MACs per clock from DDR3"], ["Host link", "PCIe Gen2 ×1, 419 MB/s measured"], ["Strength", "Every step open and measurable"]] },
];
document.getElementById("compare-cards").append(...CMP.map((c) => html(`
  <div class="cmp${c.ours ? " ours" : ""}"><h3>${c.name}</h3><p class="tagline">${c.tag}</p>
  <ul>${c.rows.map(([k, v]) => `<li><span class="k">${k}</span><span>${v}</span></li>`).join("")}</ul></div>`)));

// ---------------------------------------------------------------------------
// Roadmap
const PHASES = [
  ["PCIe link", "Endpoint, registers, DMA, interrupt, flash boot", "done"],
  ["Card memory", "1 GiB DDR3, debug cores, card-side bandwidth", "done"],
  ["Command queue", "Own DMA engine, rings in host memory, own driver", "done"],
  ["Compute engine", "INT8 matrix engine, bit-exact model, MNIST on the card", "current"],
  ["Compiler", "Quantized model to a card program, runtime", "next"],
  ["Comparison", "Cortex-A55 vs i.MX95 NPU vs this card", "next"],
];
const STATUS = { done: "done", current: "in progress", next: "planned" };
document.getElementById("roadmap-list").append(...PHASES.map(([t, d, s], i) => html(`
  <li class="${s}"><span class="n">${String(i + 1).padStart(2, "0")}</span><span class="t"><b>${t}</b><span>${d}</span></span><span class="s">${STATUS[s]}</span></li>`)));
