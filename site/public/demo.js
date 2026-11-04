// "Draw a digit": the card's network, run in the browser with the card's
// arithmetic (mnist.js), shown layer by layer with the commands the host
// would put in the card's submission queue to run it.
import { loadModel, infer } from "./mnist.js";
import { mnist as RESULT } from "./data.js";

const $ = (id) => document.getElementById(id);
const pad = $("pad"), pctx = pad.getContext("2d", { willReadFrequently: true });
const PAD = pad.width;                                    // 280 x 280, drawn at 10x MNIST
let model, samples, sampleIdx = 0, drawing = false, last = null, dirty = false;

// --- Drawing ---------------------------------------------------------------
function clearPad() {
  pctx.fillStyle = "#000"; pctx.fillRect(0, 0, PAD, PAD);
  render(null);
}
function stroke(p) {
  pctx.strokeStyle = "#fff"; pctx.lineWidth = 22; pctx.lineCap = "round"; pctx.lineJoin = "round";
  pctx.beginPath(); pctx.moveTo(...(last || p)); pctx.lineTo(...p); pctx.stroke();
  last = p; dirty = true;
}
const at = (e) => { const r = pad.getBoundingClientRect(); return [(e.clientX - r.left) * PAD / r.width, (e.clientY - r.top) * PAD / r.height]; };
pad.addEventListener("pointerdown", (e) => { drawing = true; last = null; pad.setPointerCapture(e.pointerId); stroke(at(e)); });
pad.addEventListener("pointermove", (e) => { if (drawing) stroke(at(e)); });
const up = () => { drawing = false; last = null; };
pad.addEventListener("pointerup", up); pad.addEventListener("pointercancel", up);
(function tick() { if (dirty && model) { dirty = false; run(toMnist()); } requestAnimationFrame(tick); })();

// MNIST's own preprocessing: the digit's bounding box scaled to fit 20 x 20,
// then placed in 28 x 28 with its center of mass at the center.
function toMnist() {
  const d = pctx.getImageData(0, 0, PAD, PAD).data;
  let x0 = PAD, y0 = PAD, x1 = -1, y1 = -1;
  for (let y = 0; y < PAD; y++) for (let x = 0; x < PAD; x++)
    if (d[(y * PAD + x) * 4] > 20) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
  if (x1 < 0) return null;
  const w = x1 - x0 + 1, h = y1 - y0 + 1, s = 20 / Math.max(w, h);
  const small = document.createElement("canvas"); small.width = small.height = 28;
  const sc = small.getContext("2d", { willReadFrequently: true });
  sc.imageSmoothingEnabled = true; sc.imageSmoothingQuality = "high";
  const dw = w * s, dh = h * s;
  sc.drawImage(pad, x0, y0, w, h, (28 - dw) / 2, (28 - dh) / 2, dw, dh);
  let px = sc.getImageData(0, 0, 28, 28).data, m = 0, mx = 0, my = 0;
  for (let i = 0; i < 784; i++) { const v = px[i * 4]; m += v; mx += v * (i % 28); my += v * Math.floor(i / 28); }
  const dx = Math.round(14 - mx / m), dy = Math.round(14 - my / m);
  sc.fillStyle = "#000"; sc.fillRect(0, 0, 28, 28);
  sc.drawImage(pad, x0, y0, w, h, (28 - dw) / 2 + dx, (28 - dh) / 2 + dy, dw, dh);
  px = sc.getImageData(0, 0, 28, 28).data;
  const out = new Uint8Array(784);
  for (let i = 0; i < 784; i++) out[i] = px[i * 4];
  return out;
}

function showSample() {
  if (!samples) return;
  const n = samples[0].length, i = sampleIdx++ % n;
  const img = samples[1].subarray(i * 784, (i + 1) * 784);
  // Paint it on the pad at 10x, so the pad always shows what was classified
  const c = document.createElement("canvas"); c.width = c.height = 28;
  const cx = c.getContext("2d"), id = cx.createImageData(28, 28);
  for (let p = 0; p < 784; p++) { id.data[p * 4] = id.data[p * 4 + 1] = id.data[p * 4 + 2] = img[p]; id.data[p * 4 + 3] = 255; }
  cx.putImageData(id, 0, 0);
  pctx.imageSmoothingEnabled = false; pctx.drawImage(c, 0, 0, PAD, PAD);
  run(img, `test image ${i}, labelled ${samples[0][i]}`);
}

// --- Inference and its picture ----------------------------------------------
// Sequential ramp, one hue: panel to light blue.
const ramp = (t) => { const a = [0x12, 0x1a, 0x23], b = [0xa8, 0xd4, 0xff]; return `rgb(${a.map((v, k) => Math.round(v + (b[k] - v) * t)).join(",")})`; };
function heat(canvas, values, cols, max) {
  const rows = Math.ceil(values.length / cols), c = canvas.getContext("2d");
  canvas.width = cols; canvas.height = rows;
  for (let i = 0; i < values.length; i++) { c.fillStyle = ramp(Math.max(0, values[i]) / max); c.fillRect(i % cols, Math.floor(i / cols), 1, 1); }
}

function run(pixels, source) {
  if (!pixels) return render(null);
  const t0 = performance.now();
  let r; const reps = 20;
  for (let k = 0; k < reps; k++) r = infer(model, pixels);
  r.us = (performance.now() - t0) * 1000 / reps;
  r.source = source || "your drawing";
  render(r);
}

function render(r) {
  $("demo").classList.toggle("empty", !r);
  if (!r) { $("pred").textContent = "?"; $("pred-note").textContent = "Draw a digit, 0 to 9, or load one from the test set."; return; }
  heat($("viz-x"), r.x.subarray(0, 784), 28, 127);
  heat($("viz-h"), r.h, 16, 127);
  const active = r.h.reduce((s, v) => s + (v > 0), 0);
  $("viz-h-note").textContent = `${active} of 128 neurons fire; the ReLU zeroes the rest.`;
  const lo = Math.min(0, ...r.logits), hi = Math.max(...r.logits), span = hi - lo || 1;
  $("logits").innerHTML = r.logits.map((v, c) => `
    <li class="${c === r.pred ? "win" : ""}"><span class="cls">${c}</span>
      <span class="track"><span class="bar" style="left:${(Math.min(0, v) - lo) / span * 100}%;width:${Math.abs(v) / span * 100}%"></span>
      <span class="zero" style="left:${-lo / span * 100}%"></span></span>
      <span class="val">${v.toLocaleString("en-US")}</span>${c === r.pred ? '<span class="pick">argmax</span>' : ""}</li>`).join("");
  $("pred").textContent = r.pred;
  $("pred-note").textContent = `From ${r.source}. ${r.macs.toLocaleString("en-US")} multiply-accumulates in your browser, ${r.us.toFixed(0)} µs.` +
    (RESULT.cardLatencyUs ? ` The card answers one image in ${RESULT.cardLatencyUs} µs, host round trip, and does 55 032 per second in a batch.` : "");
}

// --- The commands the host submits for one image ----------------------------
// Card addresses as npu-mnist lays them out (sw/npu/npu-mnist.c), word layout
// from docs/command-queue.md. Host addresses depend on the IOMMU, so they are
// shown as the arena buffer they point to.
const hex = (v, n = 16) => v.toString(16).padStart(n, "0");
const word0 = (op, cid, hi) => (BigInt(hi) << 32n) | (BigInt(cid) << 16n) | BigInt(op);
const CMDS = [
  { name: "COPY_H2C", what: "the 832-byte image (784 pixels >> 1, zero padded) into card memory",
    words: [word0(0x01, 0, 832), "host: image buffer", 0x1e000n, 0n],
    fields: ["opcode 0x01, command ID 0, length 832", "host bus address (IOMMU)", "card address 0x1E000", "unused"] },
  { name: "GEMM", what: "layer 1: 1 × 832 · 832 × 128, bias, ×57505 >> 27, ReLU, INT8 out",
    words: [word0(0x10, 1, 1), (0x0n << 32n) | 0x1e000n, (0x1a000n << 32n) | 0x80e000n,
      (57505n << 48n) | (1n << 40n) | (27n << 32n) | (128n << 16n) | 832n],
    fields: ["opcode 0x10, command ID 1, M = 1", "Bᵀ (weights) at 0x0, A (image) at 0x1E000", "bias at 0x1A000, C (hidden) at 0x80E000",
      "mult 57505, ReLU, shift 27, N 128, K 832"] },
  { name: "GEMM", what: "layer 2: 1 × 128 · 128 × 64, bias, INT32 out (10 classes used)",
    words: [word0(0x10, 2, 1), (0x1b000n << 32n) | 0x80e000n, (0x1d000n << 32n) | 0x947000n,
      (1n << 48n) | (1n << 41n) | (64n << 16n) | 128n],
    fields: ["opcode 0x10, command ID 2, M = 1", "Bᵀ at 0x1B000, A (hidden) at 0x80E000", "bias at 0x1D000, C (logits) at 0x947000",
      "mult 1, INT32 out, N 64, K 128"] },
  { name: "COPY_C2H", what: "the 64 INT32 logits back to the host",
    words: [word0(0x02, 3, 256), "host: logits buffer", 0x947000n, 0n],
    fields: ["opcode 0x02, command ID 3, length 256", "host bus address (IOMMU)", "card address 0x947000", "unused"] },
];
$("cmds").innerHTML = CMDS.map((c, i) => `
  <li><div class="cmd-head"><span class="op">${c.name}</span><span class="what">${c.what}</span><span class="slot">SQ slot ${i}</span></div>
    <div class="words">${c.words.map((w, k) => `<span class="w" tabindex="0" title="word ${k}: ${c.fields[k]}"><b>${k}</b>${typeof w === "string" ? `<i>${w}</i>` : hex(w)}<em>${c.fields[k]}</em></span>`).join("")}</div></li>`).join("");

// --- Start ------------------------------------------------------------------
$("pad-clear").addEventListener("click", clearPad);
$("pad-sample").addEventListener("click", showSample);
clearPad();
Promise.all([loadModel("model/mnist.bin"), fetch("model/samples.bin").then((r) => r.arrayBuffer())]).then(([m, s]) => {
  model = m;
  const n = 40;
  samples = [new Uint8Array(s, 0, n), new Uint8Array(s, n, n * 784)];
  $("demo").classList.remove("loading");
  showSample();
}).catch((e) => { $("pred-note").textContent = `Could not load the model: ${e.message}`; });
