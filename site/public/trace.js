// One inference on the card, drawn the way a logic analyzer shows it: one
// lane per agent, time running left to right. Data: the TRACE line of
// npu-mnist (data.js), host times from CLOCK_MONOTONIC, card times from the
// completion records' t_fetch / t_done (125 MHz). The two clocks are not
// related, so the card's timeline is placed after the doorbell by the one
// part it cannot time itself: the first fetch, estimated as the gap between
// later commands (a completion write plus the next fetch). That estimate is
// drawn hatched.
import { trace as T } from "./data.js";

const SVGNS = "http://www.w3.org/2000/svg";
const root = document.getElementById("trace");
const el = (tag, attrs = {}, parent) => {
  const e = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  if (parent) parent.appendChild(e);
  return e;
};
const us = (v) => v < 10 ? `${v.toFixed(2)} µs` : `${v.toFixed(1)} µs`;

function spans() {
  const c = T.card_us, hostDb = T.host_us.doorbell, hostDone = T.host_us.done;
  const gaps = c.slice(1).map((x, i) => x.fetch - c[i].done);
  const gap = gaps.reduce((a, b) => a + b, 0) / gaps.length;
  const off = hostDb + gap;                                   // card time 0, on the host's axis
  const S = [];
  S.push({ lane: 0, a: 0, b: hostDb, label: "write image + 4 SQ entries", kind: "host",
    note: "memcpy the 832-byte image into the DMA arena, write four 64-byte commands, dsb st" });
  S.push({ lane: 0, a: hostDb, b: hostDone, label: "poll the completion queue", kind: "wait",
    note: "the CPU spins on the phase bit of the next completion entry, in uncached memory" });
  S.push({ lane: 1, a: hostDb, b: off, label: "doorbell, fetch", kind: "est",
    note: `posted write to SQ_TAIL, then the card reads the 64-byte command from host memory. Not timed by either clock: estimated as the mean gap between later commands, ${us(gap)}` });
  c.forEach((x, i) => {
    const copy = x.cmd.startsWith("COPY");
    S.push({ lane: copy ? 2 : 3, a: off + x.fetch, b: off + x.done, label: x.cmd, kind: copy ? "copy" : "gemm",
      note: `${x.cmd}: ${us(x.done - x.fetch)} on the card (t_done − t_fetch)` });
    if (i + 1 < c.length)
      S.push({ lane: 1, a: off + x.done, b: off + c[i + 1].fetch, label: "cpl + fetch", kind: "pcie",
        note: `write the 16-byte completion to host memory, then fetch the next command: ${us(c[i + 1].fetch - x.done)} of PCIe round trip, measured by the card` });
  });
  const last = c[c.length - 1];
  S.push({ lane: 1, a: off + last.done, b: hostDone, label: "cpl, CPU sees it", kind: "est",
    note: "the last completion write, until the polling CPU reads it and the argmax: the remainder of the host's time" });
  return { S, end: hostDone };
}

function draw() {
  root.innerHTML = "";
  if (!T) { root.innerHTML = `<p class="pending">Waiting for the card's first trace.</p>`; return; }
  const { S, end } = spans();
  const LANES = ["CPU · Cortex-A55", "PCIe link", "Copy engine", "GEMM engine"];
  const W = 1100, L = 150, R = 20, LH = 46, TOP = 34, H = TOP + LANES.length * LH + 12;
  const x = (t) => L + (t / end) * (W - L - R);
  const svg = el("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": "Timeline of one inference: CPU, PCIe link, copy engine and GEMM engine lanes" }, root);
  // ruler
  const step = [1, 2, 5, 10, 20, 50, 100].find((s) => end / s <= 12);
  for (let t = 0; t <= end; t += step) {
    el("line", { x1: x(t), x2: x(t), y1: TOP - 6, y2: H - 8, class: "tr-grid" }, svg);
    el("text", { x: x(t), y: TOP - 12, class: "tr-tick", "text-anchor": "middle" }, svg).textContent = `${t} µs`;
  }
  LANES.forEach((name, i) => {
    const y = TOP + i * LH;
    el("text", { x: 0, y: y + LH / 2 + 4, class: "tr-lane" }, svg).textContent = name;
    el("line", { x1: L, x2: W - R, y1: y + LH - 1, y2: y + LH - 1, class: "tr-sep" }, svg);
  });
  const tip = document.createElement("div"); tip.className = "tooltip"; root.appendChild(tip);
  for (const s of S) {
    const y = TOP + s.lane * LH + 9, w = Math.max(2, x(s.b) - x(s.a));
    const g = el("g", { class: `tr-span ${s.kind}`, tabindex: 0 }, svg);
    el("rect", { x: x(s.a), y, width: w, height: LH - 20, rx: 4 }, g);
    if (w > s.label.length * 6.6 + 10) el("text", { x: x(s.a) + 7, y: y + (LH - 20) / 2 + 4, class: "tr-label" }, g).textContent = s.label;
    const show = (e) => {
      tip.innerHTML = `<b>${s.label}</b><br>${us(s.b - s.a)}, from ${us(s.a)} to ${us(s.b)}<br><span class="muted">${s.note}</span>`;
      const r = root.getBoundingClientRect(), bx = e.clientX ?? (g.getBoundingClientRect().left + 10), by = e.clientY ?? g.getBoundingClientRect().top;
      tip.style.left = `${Math.min(bx - r.left + 12, r.width - 310)}px`; tip.style.top = `${by - r.top + 14}px`; tip.style.opacity = 1;
    };
    g.addEventListener("pointermove", show); g.addEventListener("focus", show);
    g.addEventListener("pointerleave", () => (tip.style.opacity = 0)); g.addEventListener("blur", () => (tip.style.opacity = 0));
  }
  const busy = T.card_us.reduce((a, c) => a + c.done - c.fetch, 0);
  document.getElementById("trace-note").innerHTML =
    `Test image ${T.image}, labelled ${T.label}, predicted ${T.pred}. ${us(end)} from the first memcpy to the answer; ` +
    `the card's engines are busy for ${us(busy)} of it (${(busy / end * 100).toFixed(0)} %). The rest is PCIe round trips and the CPU. Layer 1 dominates because one image reuses nothing: each weight beat meets one row, 8 MACs per clock; the engine would take the same time for 8 images. Hover a span for what it is.`;
}
draw();
