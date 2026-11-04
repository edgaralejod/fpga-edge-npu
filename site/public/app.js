import { hero, timeLadder, bandwidth, dmaBySize, doc } from "./data.js";

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
  ep:   { x: 560, y: 205, w: 170, name: "PCIe endpoint", meta: "AMD XDMA, 10ee:7021", domain: "card" },
  regs: { x: 560, y: 70,  w: 170, name: "npu_regs", meta: "BAR0 control", domain: "card" },
  sc:   { x: 780, y: 205, w: 180, name: "AXI interconnect", meta: "SmartConnect, 3 masters", domain: "card" },
  bw:   { x: 780, y: 70,  w: 180, name: "mem_bw", meta: "512-bit burst engine", domain: "card" },
  dbg:  { x: 780, y: 340, w: 180, name: "Debug cores", meta: "2 ILAs, VIO, JTAG-AXI", domain: "debug" },
  mig:  { x: 1000, y: 205, w: 160, name: "Memory controller", meta: "AMD MIG, 100 MHz", domain: "mem" },
  ddr:  { x: 1000, y: 340, w: 160, name: "DDR3 1 GiB", meta: "800 MT/s, 64-bit", domain: "mem" },
  npu:  { x: 1000, y: 70,  w: 160, name: "NPU engine", meta: "phase 4, planned", domain: "card", future: true },
};
const H = 76;
const center = (id) => { const n = NODES[id]; return [n.x + n.w / 2, n.y + H / 2]; };
const EDGES = [["cpu", "rc"], ["cpu", "dram"], ["dram", "smmu"], ["smmu", "rc"], ["rc", "ep", "link"], ["ep", "regs"], ["ep", "sc"],
  ["bw", "sc"], ["dbg", "sc"], ["sc", "mig"], ["mig", "ddr"], ["npu", "sc", "future"], ["regs", "bw"]];
const edgeKey = (a, b) => [a, b].sort().join("-");

const INFO = {
  cpu: {
    p: "Six Cortex-A55 cores run Linux, the driver and the test tools. To the CPU the card is a range of physical addresses. A register access is an uncached load or store into that range, and the core stalls until the answer comes back across the link.",
    facts: [["Register read, round trip", "1.18 µs", "measured"], ["Card clock periods in that time", "≈ 148", "derived"]],
    found: "The CPU's caches were where the XDMA driver bug showed up: card data was in DRAM, but the CPU kept reading old copies from its cache.",
  },
  dram: {
    p: "Host memory holds the buffers the card reads and writes. DMA never touches the CPU's caches here: the CPU has to clean its caches before the card reads a buffer and invalidate them after the card writes one, because this port is not cache-coherent.",
    facts: [["Size", "8 GB LPDDR4X", "spec"]],
  },
  smmu: {
    p: "The IOMMU translates the addresses the card uses (I/O virtual addresses) into physical ones, so the card can only reach buffers the driver mapped for it. It also lets the kernel present scattered 4 KiB pages as one contiguous range to the card.",
    facts: [["Card's stream ID", "0x11", "measured"], ["Pages in a 64 KiB buffer", "16 → 1 range", "measured"]],
    found: "Merging 16 pages into one range exposed a bug in AMD's XDMA driver: it released buffers using the merged count, so the CPU cache was refreshed for the first page only. Fixed with a two-line patch; the IOMMU now stays on.",
  },
  rc: {
    p: "The i.MX95's PCIe controller turns CPU loads and stores into PCIe requests, and the card's DMA requests into memory accesses. The M.2 slot is wired for one lane; the controller can run Gen3, but the Artix-7 tops out at Gen2.",
    facts: [["Link trained at", "5 GT/s × 1", "measured"], ["Controller capability", "8 GT/s", "measured"]],
  },
  ep: {
    p: "AMD's DMA/Bridge Subsystem is the card's PCIe endpoint. BAR0 is turned into AXI-Lite accesses to the card's registers; BAR1 holds a DMA engine that moves data between host memory and card memory over a 64-bit AXI bus at 125 MHz.",
    facts: [["PCI ID, class", "10ee:7021, 12 00 00", "measured"], ["DMA to card, 16 MiB", "371 MB/s", "measured"], ["DMA to host, 4 MiB", "340 MB/s", "measured"]],
    found: "Phase 3 replaces it with AMD's AXI-PCIe bridge and a DMA engine of the project's own, so the card can fetch commands from host memory itself.",
  },
  regs: {
    p: "The card's control registers: identity, version, a scratch register, a cycle counter for latency measurements, interrupt control, memory status, DMA counters, and the controls of the bandwidth engine. Every host-visible bit of the card lives here.",
    facts: [["Version on the card", "0.3.0", "measured"], ["Write/read test", "10⁶ writes, 0 errors", "measured"]],
    found: "Version 0.1.0 answered a read in the same clock cycle as its address. AXI forbids it; XDMA dropped the answer and every later read returned 0xFFFFFFFF. Rebuilt on AMD's AXI4-Lite template.",
  },
  sc: {
    p: "AMD's SmartConnect joins three masters to the memory controller: the PCIe DMA engine (64 bits at 125 MHz), the bandwidth engine (512 bits at 100 MHz) and the JTAG-to-AXI master. It converts widths and crosses clock domains.",
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
  mig: {
    p: "AMD's Memory Interface Generator drives the DDR3 module: it calibrates the timing of every data line at power-up, refreshes the memory, and schedules reads and writes. Its user side is 512 bits wide at 100 MHz.",
    facts: [["Calibration", "first power-up", "measured"], ["User clock", "100 MHz", "spec"]],
  },
  ddr: {
    p: "A 1 GiB DDR3 SODIMM on the AC701: where weights and activations will live once the card computes. Its peak is 6.4 GB/s; the card reaches 85 to 93 % of it, sixteen times what the PCIe link can deliver.",
    facts: [["Peak", "6400 MB/s", "spec"], ["Read, measured inside the card", "5921 MB/s", "measured"], ["Verified", "1 GiB, every beat", "measured"]],
  },
  npu: {
    p: "Phase 4 adds the part that computes: an INT8 matrix-multiply engine on the FPGA's 740 DSP slices, fed from DDR3 and driven by commands from the queue built in phase 3, checked bit for bit against a Python model.",
    facts: [["DSP slices available", "740", "spec"]],
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
    id: "h2c", name: "DMA: host to card", total: "371 MB/s at 16 MiB, measured; ~40 µs fixed cost per transfer, derived",
    steps: [
      { path: ["cpu", "dram"], text: "The driver pins the user buffer's pages and maps them for the card. Mapping cleans the CPU's caches, so DRAM holds the latest data.", t: "Part of the ~40 µs fixed cost per transfer" },
      { path: ["dram", "smmu"], text: "The IOMMU maps the buffer's scattered 4 KiB pages to one contiguous I/O address range for the card." },
      { path: ["cpu", "rc"], text: "The driver writes the DMA descriptors' location and starts the engine with register writes over PCIe." },
      { path: ["ep", "rc"], text: "The card's DMA engine sends Memory Read requests for the buffer." },
      { path: ["smmu", "dram"], text: "The root complex fetches the data from DRAM through the IOMMU's translation." },
      { path: ["rc", "ep"], text: "Completions carry the data across the link.", t: "The link carries at most 500 MB/s; the DMA reaches 371 MB/s" },
      { path: ["ep", "sc"], text: "The endpoint writes the data into the interconnect, which widens it from 64 to 512 bits and moves it to the memory clock." },
      { path: ["sc", "mig"], text: "The memory controller schedules the writes." },
      { path: ["mig", "ddr"], text: "The data lands in DDR3. The engine signals completion with an interrupt." },
    ],
  },
  {
    id: "c2h", name: "DMA: card to host", total: "340 MB/s at 4 MiB, measured, IOMMU on",
    steps: [
      { path: ["cpu", "smmu"], text: "The driver maps the destination buffer: 16 pages become one I/O range in the IOMMU." },
      { path: ["ddr", "mig"], text: "The card's DMA engine reads card memory through the memory controller." },
      { path: ["mig", "sc"], text: "The interconnect narrows the data to the endpoint's 64-bit bus." },
      { path: ["sc", "ep"], text: "The endpoint packs the data into Memory Write requests." },
      { path: ["ep", "rc"], text: "The writes cross the link to the root complex.", t: "340 MB/s measured at 4 MiB" },
      { path: ["rc", "smmu"], text: "The root complex translates each address through the IOMMU." },
      { path: ["smmu", "dram"], text: "The data lands in DRAM, bypassing the CPU's caches." },
      { path: ["dram", "cpu"], text: "The driver must invalidate the CPU's cached copies of every page before the program reads them. AMD's driver did it for the first page only; this project's patch fixes it.", t: "Found on this bench; upstream issue #386" },
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
// Deep links: ?flow=c2h&step=8 opens a journey at a step.
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
timeChart(); bandwidthChart(); sizeChart();
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
  { name: "This card", tag: "Artix-7 on the bench, both roles at small scale", ours: true, rows: [["Weights", "1 GiB DDR3 at 5.9 GB/s, or block RAM"], ["Execution", "Phase 4: INT8 engine on 740 DSP slices"], ["Host link", "PCIe Gen2 ×1, 371 MB/s measured"], ["Strength", "Every step open and measurable"]] },
];
document.getElementById("compare-cards").append(...CMP.map((c) => html(`
  <div class="cmp${c.ours ? " ours" : ""}"><h3>${c.name}</h3><p class="tagline">${c.tag}</p>
  <ul>${c.rows.map(([k, v]) => `<li><span class="k">${k}</span><span>${v}</span></li>`).join("")}</ul></div>`)));

// ---------------------------------------------------------------------------
// Roadmap
const PHASES = [
  ["PCIe link", "Endpoint, registers, DMA, interrupt, flash boot", "done"],
  ["Card memory", "1 GiB DDR3, debug cores, card-side bandwidth", "done"],
  ["Command queue", "Own DMA engine, rings in host memory, own driver", "current"],
  ["Compute engine", "INT8 matrix engine, bit-exact Python model", "next"],
  ["Compiler", "Quantized model to a card program, runtime", "next"],
  ["Comparison", "Cortex-A55 vs i.MX95 NPU vs this card", "next"],
];
const STATUS = { done: "done", current: "in progress", next: "planned" };
document.getElementById("roadmap-list").append(...PHASES.map(([t, d, s], i) => html(`
  <li class="${s}"><span class="n">${String(i + 1).padStart(2, "0")}</span><span class="t"><b>${t}</b><span>${d}</span></span><span class="s">${STATUS[s]}</span></li>`)));
