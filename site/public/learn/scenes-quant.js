// Part 3: quantization, with the real scales and the real float and INT8
// networks' outputs (sw/mnist/lessons.py, quant.json).
import { C, MONO, lerp, clamp, ease, text, arrow, box, divColor, fmt } from "./stage.js";

// ---------------------------------------------------------------------------
const adc = {
  id: "s-adc", kicker: "3.1", title: "Floats to 8 bits is an ADC", w: 960, h: 520,
  init: () => ({ grid: 0, zoom: 0, act: 0, bits: 8 }),
  steps: [
    { say: `<p>Training produced layer 1's <span class="n">100 352</span> weights as 32-bit floats. Their histogram: most are near zero, all lie between <span class="n">−0.50</span> and <span class="n">+0.34</span>.</p>` },
    { to: { grid: 1 }, say: `<p>To store them in 8 bits, divide the range into 255 evenly spaced levels, <span class="n">−127</span> to <span class="n">+127</span>, and round each weight to the nearest: <span class="m">q = round(w / s)</span>, with step <span class="m">s = max|w| / 127 = 0.003947</span>.</p><p>The grid is symmetric even though the positive weights stop at 0.34: one scale, no offset, so zero is exactly zero and the hardware needs no correction terms. A few positive levels go unused.</p><span class="hw">An ADC: full scale ±max|w|, 8 bits, LSB = s. Or a Q-format number whose scale is not a power of two. The weight is q × s; the card stores only q.</span>` },
    { to: { zoom: 1 }, dur: 1500, say: `<p>Zoom in: each weight snaps to the nearest level. The error is at most half a step, <span class="n">±0.00197</span>: noise, as in any ADC, here about 1 % of a typical large weight.</p><p>The network was trained with float noise in its data anyway; this much more does not move most answers.</p>` },
    { to: { zoom: 0, act: 1 }, say: `<p>The inputs need no choice: <span class="m">x = pixel ≫ 1</span> already is an integer 0 to 127 with scale <span class="m">s<sub>x</sub> = 1/127</span>.</p><p>The hidden activations have no hard maximum, so their full scale is a choice: too large wastes resolution, too small clips. <code>train.py</code> uses the 99.99th percentile of activations over the training set: <span class="m">s<sub>h</sub> = 0.0725</span>, so values above <span class="n">9.21</span> saturate at 127.</p><span class="hw">Setting an ADC's gain: headroom against quantization noise. One sample in ten thousand clips.</span>` },
    { say: `<p>Fewer bits, coarser steps. Use the slider to see 6, 4 or 2 bits: the levels get so coarse that the weights' detail disappears. 8 bits is the usual sweet spot for inference: the multiplier is small (8 × 8) and accuracy here is unchanged (scene 3.3).</p>` },
  ],
  draw(ctx, s, { D }) {
    const q = D.quant, H = q.w1_hist, n = H.counts.length;
    const lo = H.edges[0], hi = H.edges[n], maxc = Math.max(...H.counts);
    const gx = 60, gy = 380, gw = 840, gh = 300;
    const z = ease(s.zoom);
    // Visible range: full, or zoomed around 0.1
    const vlo = lerp(-0.52, 0.085, z), vhi = lerp(0.52, 0.115, z);
    const X = (w) => gx + ((w - vlo) / (vhi - vlo)) * gw;
    ctx.save(); ctx.beginPath(); ctx.rect(gx, 20, gw, gy + 60); ctx.clip();
    if (z < 0.9) {
      ctx.globalAlpha = 1 - z;
      for (let i = 0; i < n; i++) {
        const x0 = X(H.edges[i]), x1 = X(H.edges[i + 1]), h = Math.sqrt(H.counts[i] / maxc) * gh;
        ctx.fillStyle = C.blue; ctx.fillRect(x0, gy - h, Math.max(1, x1 - x0 - 1), h);
      }
      ctx.globalAlpha = 1;
    }
    // Quantization levels
    const bits = s.bits, levels = 2 ** (bits - 1) - 1, step = q.s_w1 * 127 / levels;
    if (s.grid > 0) {
      ctx.globalAlpha = s.grid * (z > 0.5 ? 0.9 : 0.35);
      ctx.strokeStyle = C.yellow; ctx.lineWidth = 1;
      for (let k = -levels; k <= levels; k++) { const x = X(k * step); if (x < gx - 2 || x > gx + gw + 2) continue; ctx.beginPath(); ctx.moveTo(x, gy + 6); ctx.lineTo(x, gy - (z > 0.5 ? 260 : 16)); ctx.stroke(); }
      ctx.globalAlpha = 1;
    }
    // Zoomed: individual float weights snapping to levels
    if (z > 0.05) {
      const sw = q.s_w1;
      q.w1_zoom.forEach((wf, n) => {            // 60 real float weights of layer 1
        const wq = Math.round(wf / sw) * sw, y = 70 + (n % 12) * 22;
        ctx.globalAlpha = z;
        ctx.fillStyle = C.ink; ctx.beginPath(); ctx.arc(X(wf), y, 4, 0, 7); ctx.fill();
        arrow(ctx, X(wf), y, lerp(X(wf), X(wq), z), y, { color: C.green, width: 1.5, head: 6 });
        ctx.globalAlpha = 1;
      });
      text(ctx, `levels ${q.s_w1.toFixed(6)} apart`, gx + 8, 46, { font: MONO, color: C.yellow, alpha: z });
    }
    ctx.restore();
    ctx.strokeStyle = C.line; ctx.beginPath(); ctx.moveTo(gx, gy + 6); ctx.lineTo(gx + gw, gy + 6); ctx.stroke();
    const ticks = z > 0.5 ? [0.09, 0.1, 0.11] : [-0.5, -0.25, 0, 0.25, 0.5];
    for (const t of ticks) text(ctx, String(t), X(t), gy + 26, { font: MONO, color: C.faint, align: "center" });
    text(ctx, "layer 1 weight value (float)", gx + gw, gy + 48, { font: MONO, color: C.muted, align: "right" });
    if (z < 0.5) text(ctx, "how many weights (square-root scale)", gx, 40, { font: MONO, color: C.muted, alpha: 1 - z });
    if (s.grid > 0 && z < 0.5) text(ctx, `${2 * levels + 1} levels: ${bits}-bit signed, step ${step.toFixed(5)}`, gx + gw, 40, { font: MONO, color: C.yellow, align: "right", alpha: s.grid });
    if (s.act > 0) {
      ctx.globalAlpha = s.act;
      box(ctx, 560, 70, 340, 120, { fill: "#141d27", stroke: C.line });
      text(ctx, "scales the card uses", 576, 96, { font: MONO, color: C.muted });
      text(ctx, `inputs        s_x  = 1/127`, 576, 122, { font: MONO });
      text(ctx, `weights L1    s_w1 = ${q.s_w1.toFixed(6)}`, 576, 144, { font: MONO });
      text(ctx, `activations   s_h  = ${q.s_h.toFixed(6)}`, 576, 166, { font: MONO });
      ctx.globalAlpha = 1;
    }
  },
  controls(el, api) {
    const lab = document.createElement("label");
    lab.innerHTML = `Bits <input type="range" min="2" max="8" value="8"><span class="val">8</span>`;
    lab.querySelector("input").addEventListener("input", (e) => { if (api.step < 1) api.go(1, false); api.set("bits", Number(e.target.value)); lab.querySelector(".val").textContent = e.target.value; });
    el.appendChild(lab);
  },
};

// ---------------------------------------------------------------------------
const requant = {
  id: "s-requant", kicker: "3.2", title: "Requantization: one Q-format multiply", w: 960, h: 560,
  init: (D) => {
    // A neuron with a clear, non-saturated activation on image 0
    const h = D.quant.images.h_int8[0]; let j = 0;
    for (let k = 0; k < 128; k++) if (h[k] > 40 && h[k] < 120) { j = k; break; }
    return { img: 0, j, st: 0 };
  },
  steps: [
    { say: `<p>Why can the card multiply integers and still get the float network's answer? Because the scales factor out. A float input is <span class="m">s<sub>x</sub>·x<sub>q</sub></span>, a float weight <span class="m">s<sub>w</sub>·w<sub>q</sub></span>, so every product is <span class="m">(s<sub>x</sub>s<sub>w</sub>) · x<sub>q</sub>w<sub>q</sub></span>, and the sum of 784 of them is</p><p class="m">Σ x·w = s<sub>x</sub>s<sub>w</sub> · Σ x<sub>q</sub>w<sub>q</sub></p><p>All the arithmetic is integer; one scale multiplies the result.</p>` },
    { to: { st: 1 }, say: `<p>So the card accumulates in pure integers, 8-bit times 8-bit into 32 bits: this neuron's accumulator for image #0. Its bias was stored already in the accumulator's units, <span class="m">b<sub>q</sub> = round(b / s<sub>x</sub>s<sub>w</sub>)</span>.</p>` },
    { to: { st: 2 }, say: `<p>The accumulator's units are <span class="m">s<sub>x</sub>s<sub>w</sub> = 3.108 × 10⁻⁵</span>. The next layer wants 8-bit activations in units of <span class="m">s<sub>h</sub></span>. So multiply by</p><p class="m">M = s<sub>x</sub>s<sub>w</sub> / s<sub>h</sub> = 0.000428443</p><p>A fraction, and the card has no floats.</p>` },
    { to: { st: 3 }, say: `<p>Write <span class="m">M</span> as a fixed-point number: <span class="m">M ≈ 57505 / 2²⁷</span>. Multiply by the integer 57505, then shift right by 27 bits.</p><span class="hw">A Q27 constant. Exactly how a DSP filter's 32-bit accumulator is scaled back to its output width: multiply by a fixed-point gain, then shift.</span>` },
    { to: { st: 4 }, say: `<p>Shifting right truncates, always rounding down. To round to nearest, add half an output LSB first: <span class="m">2²⁶</span>, then shift. Then the ReLU and a clamp to 0 to 127.</p><p>That is <code>(acc × mult + 2^(shift−1)) ≫ shift</code>, the line every GEMM command runs, in <code>npu_mm.v</code> stages 7 to 9.</p>` },
    { to: { st: 5 }, say: `<p>Check against the float network: the INT8 result times <span class="m">s<sub>h</sub></span> lands within one step of the float activation. Try other neurons and images. Most land on the nearest step; about 1 in 10 (320 of 3 183 nonzero activations over 40 images) is one step off, from the weights' own rounding adding up.</p>` },
  ],
  draw(ctx, s, { D }) {
    const q = D.quant, im = q.images, i = s.img, j = s.j;
    const acc = im.acc32[i][j], mult = q.mult, sh = q.shift;
    const prod = acc * mult, rnd = prod + 2 ** (sh - 1), shf = Math.floor(rnd / 2 ** sh);
    const hq = im.h_int8[i][j], hf = im.h_float[i][j];
    const rows = [
      [1, "accumulator (int32)", fmt(acc), "Σ x_q·w_q + b_q", C.ink],
      [2, "in float units", (acc * q.s_x * q.s_w1).toFixed(4), `× s_x·s_w1 (${(q.s_x * q.s_w1).toExponential(4)})`, C.muted],
      [3, "× 57505", fmt(prod), "48-bit product", C.ink],
      [4, "+ 2²⁶", fmt(rnd), "round half up", C.ink],
      [4, "≫ 27", fmt(shf), "arithmetic shift", C.ink],
      [4, "ReLU, clamp 0..127", String(Math.max(0, Math.min(127, shf))), `card's h[${j}] = ${hq}`, C.green],
      [5, "× s_h, back to float", (hq * q.s_h).toFixed(4), `float network: ${hf.toFixed(4)}`, C.yellow],
    ];
    text(ctx, `image #${i}, neuron ${j}`, 40, 40, { font: MONO, color: C.muted });
    // Formula header
    text(ctx, "Σ x·w  =  s_x · s_w  ·  Σ x_q·w_q", 40, 90, { font: 'italic 26px "Source Serif 4", serif', color: C.yellow });
    let y = 150;
    for (const [need, name, val, note, col] of rows) {
      const a = clamp(s.st - need + 1, 0, 1);
      if (a <= 0) { y += 52; continue; }
      ctx.globalAlpha = a;
      box(ctx, 40, y - 30, 880, 44, { fill: "#111923", stroke: C.line });
      text(ctx, name, 60, y - 2, { font: MONO, color: C.muted });
      text(ctx, val, 520, y - 2, { font: '600 18px "JetBrains Mono", monospace', color: col, align: "right" });
      text(ctx, note, 560, y - 2, { font: MONO, color: C.faint });
      ctx.globalAlpha = 1;
      y += 52;
    }
    if (s.st >= 3) {
      const a = clamp(s.st - 2, 0, 1);
      text(ctx, `M = ${q.M.toFixed(9)}   57505 / 2²⁷ = ${(mult / 2 ** sh).toFixed(9)}`, 40, 535, { font: MONO, color: C.muted, alpha: a });
    }
  },
  controls(el, api) {
    const lab = document.createElement("label");
    lab.innerHTML = `Neuron <input type="range" min="0" max="127" value="${api.state.j}"><span class="val">${api.state.j}</span>`;
    lab.querySelector("input").addEventListener("input", (e) => { api.set("j", Number(e.target.value)); lab.querySelector(".val").textContent = e.target.value; });
    const im = document.createElement("label");
    im.innerHTML = `Image <input type="range" min="0" max="39" value="0"><span class="val">#0</span>`;
    im.querySelector("input").addEventListener("input", (e) => { api.set("img", Number(e.target.value)); im.querySelector(".val").textContent = `#${e.target.value}`; });
    el.append(lab, im);
  },
};

// ---------------------------------------------------------------------------
const cost = {
  id: "s-cost", kicker: "3.3", title: "What did 8 bits cost?", w: 960, h: 520,
  init: () => ({ h: 0, zoom: 0, logit: 0, board: 0 }),
  steps: [
    { to: { h: 1 }, dur: 1400, say: `<p>Every hidden activation for 40 test images, 5 120 points: the float network's value across, the card's INT8 value (times <span class="m">s<sub>h</sub></span>) up. A perfect match would be the diagonal.</p>` },
    { to: { zoom: 1 }, dur: 1500, say: `<p>Closer: a staircase. The card can only express multiples of <span class="m">s<sub>h</sub> = 0.0725</span>, so each float value lands on the nearest step, sometimes one off. Zero stays exactly zero: the ReLU's clamp survives quantization perfectly.</p>` },
    { to: { zoom: 0, logit: 1 }, dur: 1400, say: `<p>The ten scores, float against the card's INT32 (times <span class="m">s<sub>h</sub>s<sub>w2</sub></span>). The small errors of layer 1 pass through layer 2 and stay small. What matters is only which score is largest.</p>` },
    { to: { board: 1 }, say: `<p>Over all 10 000 test images: the float network gets <span class="n">9 711</span> right, the card <span class="n">9 711</span>. They disagree on <span class="n">9</span> images: rounding flipped a few close calls, as many each way.</p><p>For that, the model is 4 times smaller (102 KB instead of 407 KB), and every multiplier is 8 × 8 bits instead of a floating-point unit.</p>` },
  ],
  draw(ctx, s, { D }) {
    const q = D.quant, im = q.images;
    const gx = 70, gy = 470, gs = 420;
    const zmax = s.zoom > 0 ? lerp(10, 2, ease(s.zoom)) : 10;
    const X = (v) => gx + (v / zmax) * gs, Y = (v) => gy - (v / zmax) * gs;
    ctx.strokeStyle = C.line; ctx.beginPath(); ctx.moveTo(gx, gy); ctx.lineTo(gx + gs, gy); ctx.moveTo(gx, gy); ctx.lineTo(gx, gy - gs); ctx.stroke();
    ctx.strokeStyle = C.faint; ctx.setLineDash([4, 4]); ctx.beginPath(); ctx.moveTo(gx, gy); ctx.lineTo(gx + gs, gy - gs); ctx.stroke(); ctx.setLineDash([]);
    text(ctx, "float activation", gx + gs, gy + 26, { font: MONO, color: C.muted, align: "right" });
    text(ctx, "card (INT8 × s_h)", gx - 10, gy - gs - 10, { font: MONO, color: C.muted });
    for (const t of [0, zmax / 2, zmax]) { text(ctx, t.toFixed(t < 3 ? 1 : 0), X(t), gy + 14 + 0, { font: MONO, color: C.faint, align: "center" }); }
    if (s.h > 0) {
      ctx.save(); ctx.beginPath(); ctx.rect(gx, gy - gs, gs, gs); ctx.clip();
      ctx.globalAlpha = s.h * 0.6; ctx.fillStyle = C.blue;
      const n = Math.floor(40 * s.h);
      for (let i = 0; i < n; i++) for (let k = 0; k < 128; k++) {
        const f = im.h_float[i][k], c = im.h_int8[i][k] * q.s_h;
        ctx.fillRect(X(f) - 1.5, Y(c) - 1.5, 3, 3);
      }
      ctx.restore(); ctx.globalAlpha = 1;
    }
    if (s.logit > 0) {
      ctx.globalAlpha = s.logit;
      const lx = 560, ly = 470, ls = 340, sc = q.s_h * q.s_w2;
      let lim = 0; for (let i = 0; i < 40; i++) for (let c = 0; c < 10; c++) lim = Math.max(lim, Math.abs(im.logits_float[i][c]));
      const LX = (v) => lx + ((v + lim) / (2 * lim)) * ls, LY = (v) => ly - ((v + lim) / (2 * lim)) * ls;
      ctx.strokeStyle = C.line; ctx.strokeRect(lx, ly - ls, ls, ls);
      ctx.strokeStyle = C.faint; ctx.setLineDash([4, 4]); ctx.beginPath(); ctx.moveTo(lx, ly); ctx.lineTo(lx + ls, ly - ls); ctx.stroke(); ctx.setLineDash([]);
      ctx.fillStyle = C.yellow;
      for (let i = 0; i < 40; i++) for (let c = 0; c < 10; c++) ctx.fillRect(LX(im.logits_float[i][c]) - 2, LY(im.logits_int[i][c] * sc) - 2, 4, 4);
      text(ctx, "scores: float →, card ↑", lx, ly - ls - 10, { font: MONO, color: C.muted });
      ctx.globalAlpha = 1;
    }
    if (s.board > 0) {
      ctx.globalAlpha = s.board;
      box(ctx, 540, 60, 380, 170, { fill: "#141d27", stroke: C.green });
      const T = q.test_set;
      text(ctx, "10 000 test images", 560, 92, { font: MONO, color: C.muted });
      text(ctx, `float network   ${fmt(T.float_correct)} right`, 560, 124, { font: '600 16px "JetBrains Mono", monospace' });
      text(ctx, `card, INT8      ${fmt(T.int8_correct)} right`, 560, 152, { font: '600 16px "JetBrains Mono", monospace', color: C.green });
      text(ctx, `answers that differ: ${T.predictions_differing}`, 560, 184, { font: MONO, color: C.yellow });
      text(ctx, "model: 407 KB float → 102 KB INT8", 560, 212, { font: MONO, color: C.muted });
      ctx.globalAlpha = 1;
    }
  },
};

export const quantScenes = [adc, requant, cost];
