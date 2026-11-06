// Part 1: inference, with the card's real network and real test images.
import { C, MONO, SANS, lerp, clamp, ease, grid, text, arrow, box, divColor, seqColor, fmt } from "./stage.js";

const px28 = (img) => Array.from(img.px, (v) => v);
// Image picker shared by several scenes
function imagePicker(el, api, key = "img") {
  const lab = document.createElement("label");
  lab.innerHTML = `Test image <button data-d="-1">◀</button><span class="val"></span><button data-d="1">▶</button>`;
  const val = lab.querySelector(".val");
  const show = () => { const i = api.state[key]; val.textContent = `#${i} (a ${api.env.D.images[i].label})`; };
  lab.querySelectorAll("button").forEach((b) => b.addEventListener("click", () => {
    api.set(key, (api.state[key] + Number(b.dataset.d) + 40) % 40); show();
  }));
  el.appendChild(lab); show();
}

// The int32 accumulator of neuron j for image i, as the card computes it
function neuronAcc(D, i, j, upto = 784) {
  const r = D.run(i), w = D.w1row(j);
  let s = 0;
  for (let k = 0; k < upto; k++) s += r.x[k] * w[k];
  return s;
}

// ---------------------------------------------------------------------------
const pixels = {
  id: "s-pixels", kicker: "1.1", title: "A picture is a list of 784 numbers", w: 960, h: 540,
  init: () => ({ img: 0, mag: 0, half: 0, u: 0, pad: 0 }),
  steps: [
    { say: `<p>This is test image #0 from the MNIST set: a handwritten digit, 28 by 28 pixels. The card sees it the way any processor sees an image: as numbers.</p><p>Each pixel is a brightness from <span class="n">0</span> (black) to <span class="n">255</span> (white).</p>` },
    { to: { mag: 1 }, say: `<p>Zoom into a corner of the stroke. Each cell is just one byte.</p><p>Nothing here knows it is a "7". It is 784 bytes in a frame buffer.</p>` },
    { to: { half: 1 }, say: `<p>The card works in signed 8-bit integers, which top out at <span class="n">127</span>. So the host shifts every pixel right by one bit: <span class="m">x = pixel ≫ 1</span>, values <span class="n">0</span> to <span class="n">127</span>.</p><p>One bit of brightness lost; no difference to the answer (part 3 shows why).</p>` },
    { to: { mag: 0, u: 1 }, dur: 2600, say: `<p>Now forget the square. Read the pixels out row by row, like a raster scan, into one long column.</p><p>That column is the network's input: a vector <span class="m">x</span> with 784 entries.</p><span class="hw">A frame buffer read out in raster order into a FIFO. The 2D shape is gone; only the order of the bytes remembers it.</span>` },
    { to: { pad: 1 }, say: `<p>The card's engine reads memory in 64-byte bursts and wants the vector length to be a multiple of 64. So <span class="n">48</span> zeros are appended: <span class="n">784 → 832</span>.</p><p>Zeros multiply to nothing, so they change no result. Everything that follows is arithmetic on this one column of numbers.</p>` },
  ],
  draw(ctx, s, { D }) {
    const img = px28(D.images[s.img]);
    const cell = 15, gx = 90, gy = 60;
    const u = s.u;
    // Column target
    const cx = 640, cy = 30, ch = 0.6, cw = 26;
    for (let i = 0; i < 784; i++) {
      const r = Math.floor(i / 28), c = i % 28;
      const ur = ease(clamp(u * 1.7 - (r / 28) * 0.7, 0, 1));
      const x = lerp(gx + c * cell, cx, ur), y = lerp(gy + r * cell, cy + i * ch, ur);
      const w = lerp(cell - 1, cw, ur), h = lerp(cell - 1, Math.max(ch, 0.6), ur);
      const v = lerp(img[i], img[i] >> 1, s.half) / (s.half > 0.5 ? 127 : 255);
      ctx.fillStyle = seqColor(v * (s.half > 0.5 ? 127 : 255), s.half > 0.5 ? 127 : 255, [235, 240, 245]);
      ctx.fillRect(x, y, w, h + (ur > 0.95 ? 0.4 : 0));
    }
    if (u < 0.05) {
      text(ctx, "28 × 28 pixels", gx, gy - 18, { font: MONO, color: C.muted });
    }
    if (u > 0.5) {
      const a = clamp((u - 0.5) * 2, 0, 1);
      text(ctx, "x", cx + cw + 18, cy + 20, { font: 'italic 28px "Source Serif 4", serif', color: C.yellow, alpha: a });
      text(ctx, "x₀  (top-left pixel)", cx + cw + 18, cy + 50, { font: MONO, color: C.muted, alpha: a });
      text(ctx, "x₄₀₅  (row 14, column 13)", cx + cw + 18, cy + 405 * ch + 4, { font: MONO, color: C.muted, alpha: a });
      text(ctx, "x₇₈₃  (bottom-right)", cx + cw + 18, cy + 783 * ch, { font: MONO, color: C.muted, alpha: a });
      text(ctx, "784 numbers", cx - 20, cy + 784 * ch + 26, { font: MONO, color: C.ink, align: "right", alpha: a });
      ctx.globalAlpha = 1;
    }
    if (s.pad > 0) {
      const y0 = cy + 784 * ch;
      ctx.fillStyle = C.faint; ctx.globalAlpha = s.pad;
      ctx.fillRect(cx, y0 + 1, cw, 48 * ch * s.pad);
      ctx.globalAlpha = 1;
      text(ctx, "+ 48 zeros → 832", cx + cw + 18, y0 + 18, { font: MONO, color: C.yellow, alpha: s.pad });
    }
    // Magnifier
    if (s.mag > 0.01) {
      const r0 = 8, c0 = 12, n = 6, mc = 50 * s.mag, mx = 560, my = 70;
      ctx.save(); ctx.globalAlpha = s.mag;
      ctx.strokeStyle = C.yellow; ctx.lineWidth = 2;
      ctx.strokeRect(gx + c0 * cell, gy + r0 * cell, n * cell, n * cell);
      ctx.beginPath(); ctx.moveTo(gx + (c0 + n) * cell, gy + r0 * cell); ctx.lineTo(mx, my);
      ctx.moveTo(gx + (c0 + n) * cell, gy + (r0 + n) * cell); ctx.lineTo(mx, my + n * mc); ctx.stroke();
      for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) {
        const v = img[(r0 + r) * 28 + c0 + c], shown = s.half > 0.5 ? v >> 1 : v;
        ctx.fillStyle = seqColor(v, 255, [235, 240, 245]);
        ctx.fillRect(mx + c * mc, my + r * mc, mc - 2, mc - 2);
        text(ctx, String(shown), mx + c * mc + mc / 2 - 1, my + r * mc + mc / 2 + 5, { font: '500 14px "JetBrains Mono", monospace', color: v > 140 ? "#0b1017" : C.ink, align: "center" });
      }
      ctx.restore();
    }
  },
  controls: (el, api) => imagePicker(el, api),
};

// ---------------------------------------------------------------------------
const neuron = {
  id: "s-neuron", kicker: "1.2", title: "One neuron is a weighted sum", w: 960, h: 540,
  init: (D) => {
    // Start with the most structured neuron that fires on image #0 (a 7)
    const h = D.run(0).h; let j = D.training.snapshots.neurons.find((k) => h[k] > 60);
    if (j === undefined) j = h.indexOf(Math.max(...h));
    return { img: 0, j, w: 0, p: 0, scan: 0, bias: 0, relu: 0 };
  },
  steps: [
    { say: `<p>Layer 1 has 128 neurons. Look at one of them. A neuron is not a cell or a wire: it is a list of 784 numbers called <b>weights</b>, one for each pixel, and one extra number called the <b>bias</b>.</p><p>On the left, the input <span class="m">x</span> folded back into its square so we can see it.</p>` },
    { to: { w: 1 }, say: `<p>These are this neuron's 784 weights, drawn in the same 28 × 28 layout: <span class="blue">blue is positive</span>, <span class="red">red is negative</span>, dark is near zero.</p><p>Look at it as a picture: it is a <b>template</b>. It likes ink in the blue regions and dislikes ink in the red ones. Nobody drew it; training found it (part 2).</p>` },
    { to: { p: 1 }, say: `<p>Multiply each pixel by the weight in the same place. Black pixels are zero, so they contribute nothing. Where ink lands on blue, the product is positive; ink on red, negative.</p>` },
    { to: { scan: 1 }, dur: 4200, say: `<p>Now add all 784 products up, one after another. Watch the running total.</p><p class="m">acc = x₀·w₀ + x₁·w₁ + … + x₇₈₃·w₇₈₃</p><span class="hw">This is a multiply-accumulate loop: a 784-tap FIR filter evaluated at one point. In C: <code>for (k = 0; k &lt; 784; k++) acc += x[k] * w[k];</code> Mathematically, a dot product.</span>` },
    { to: { bias: 1 }, say: `<p>Add the bias, a per-neuron offset. A big positive total means "this input matches my template"; negative means "it does not".</p><p>These are the card's integers: 8-bit inputs times 8-bit weights, summed in a 32-bit accumulator.</p>` },
    { to: { relu: 1 }, say: `<p>Last, clamp negatives to zero. This clamp is called <b>ReLU</b>, and it is the only non-linear thing in the network (scene 1.4 shows why it matters).</p><p>The result is this neuron's <b>activation</b>: how strongly its pattern is present. Try other neurons and images below; many neurons answer 0 for a given digit.</p>` },
  ],
  draw(ctx, s, { D }) {
    const r = D.run(s.img), w = D.w1row(s.j), cell = 7, y0 = 92;
    const X = [30, 262, 494];
    text(ctx, "input x", X[0], y0 - 14, { font: MONO, color: C.muted });
    grid(ctx, Array.from(r.x.subarray(0, 784)), 28, X[0], y0, cell, (v) => seqColor(v, 127, [235, 240, 245]));
    if (s.w > 0) {
      ctx.globalAlpha = s.w;
      text(ctx, `weights of neuron ${s.j}`, X[1], y0 - 14, { font: MONO, color: C.muted });
      grid(ctx, Array.from(w), 28, X[1], y0, cell, (v) => divColor(v, 90));
      text(ctx, "×", X[1] - 22, y0 + 118, { font: '28px Inter', color: C.muted, align: "center" });
      ctx.globalAlpha = 1;
    }
    let maxp = 1;
    const prods = Array.from({ length: 784 }, (_, k) => r.x[k] * w[k]);
    for (const v of prods) maxp = Math.max(maxp, Math.abs(v));
    if (s.p > 0) {
      ctx.globalAlpha = s.p;
      text(ctx, "products x·w", X[2], y0 - 14, { font: MONO, color: C.muted });
      text(ctx, "=", X[2] - 22, y0 + 118, { font: '28px Inter', color: C.muted, align: "center" });
      const upto = Math.floor(s.scan * 784);
      grid(ctx, prods, 28, X[2], y0, cell, (v, k) => (s.scan > 0 && s.scan < 1 && k >= upto ? "#141c26" : divColor(v, maxp * 0.6)));
      ctx.globalAlpha = 1;
    }
    // Running sum
    if (s.scan > 0) {
      const upto = Math.floor(s.scan * 784);
      if (s.scan < 1) {
        const k = Math.min(783, upto);
        ctx.strokeStyle = C.yellow; ctx.lineWidth = 2;
        ctx.strokeRect(X[2] + (k % 28) * cell - 1, y0 + Math.floor(k / 28) * cell - 1, cell + 1, cell + 1);
      }
      const acc = neuronAcc(D, s.img, s.j, upto);
      const accF = neuronAcc(D, s.img, s.j);
      const bias = D.model.b1[s.j];
      const total = acc + (s.bias > 0.5 ? bias : 0);
      const bx = 790, by = 90, bh = 300, mid = by + bh / 2;
      const scale = (bh / 2) / Math.max(Math.abs(accF), Math.abs(accF + bias), 1) * 0.9;
      box(ctx, bx - 30, by - 30, 130, bh + 70, { fill: "#0f1620" });
      ctx.strokeStyle = C.faint; ctx.beginPath(); ctx.moveTo(bx - 10, mid); ctx.lineTo(bx + 70, mid); ctx.stroke();
      text(ctx, "0", bx - 18, mid + 4, { font: MONO, color: C.faint, align: "right" });
      const shown = s.relu > 0.5 ? Math.max(0, total) : total;
      const hgt = shown * scale;
      ctx.fillStyle = shown >= 0 ? C.blue : C.red;
      ctx.fillRect(bx + 10, hgt >= 0 ? mid - hgt : mid, 40, Math.abs(hgt));
      text(ctx, s.relu > 0.5 ? "after ReLU" : s.bias > 0.5 ? "acc + bias" : "running sum", bx + 30, by - 10, { font: MONO, color: C.muted, align: "center" });
      text(ctx, fmt(shown), bx + 30, by + bh + 28, { font: '600 18px "JetBrains Mono", monospace', color: C.ink, align: "center" });
      const ty = y0 + 28 * cell + 40;
      text(ctx, `Σ x·w over ${Math.min(upto, 784)} of 784 pixels = ${fmt(acc)}`, X[0], ty, { font: MONO, color: C.ink });
      if (s.bias > 0) text(ctx, `+ bias ${fmt(bias)}  =  ${fmt(accF + bias)}`, X[0], ty + 28, { font: MONO, color: C.yellow, alpha: s.bias });
      if (s.relu > 0) {
        text(ctx, `ReLU: max(0, ${fmt(total)}) = ${fmt(Math.max(0, total))}`, X[0], ty + 56, { font: MONO, color: C.green, alpha: s.relu });
        text(ctx, `the card then rescales it to 8 bits: h[${s.j}] = ${r.h[s.j]}  (part 3)`, X[0], ty + 84, { font: MONO, color: C.muted, alpha: s.relu });
      }
    }
  },
  controls(el, api) {
    imagePicker(el, api);
    const lab = document.createElement("label");
    lab.innerHTML = `Neuron <input type="range" min="0" max="127" value="${api.state.j}"><span class="val">${api.state.j}</span>`;
    lab.querySelector("input").addEventListener("input", (e) => { api.set("j", Number(e.target.value)); lab.querySelector(".val").textContent = e.target.value; });
    el.appendChild(lab);
  },
};

// ---------------------------------------------------------------------------
const layer = {
  id: "s-layer", kicker: "1.3", title: "128 templates at once: a matrix multiply", w: 960, h: 560,
  init: () => ({ img: 0, lit: 0, mat: 0, batch: 0, hover: -1 }),
  steps: [
    { say: `<p>Here are all 128 neurons of layer 1, each drawn as its 28 × 28 template of weights. These are the card's real weights, exactly as they sit in its memory (as INT8).</p><p>Some look like strokes, some like blobs or edges, some like noise. Together they are the features the network learned to look for.</p>` },
    { to: { lit: 1 }, say: `<p>Show them test image #0. Each tile now shows its neuron's activation: bright tiles are neurons whose template matched, dark ones answered 0 after the ReLU.</p><p>Hover a tile to read its value. The 128 activations together, a vector <span class="m">h</span>, are a new description of the digit: not pixels, but which features are present.</p>` },
    { to: { mat: 1 }, dur: 1800, say: `<p>Now stack the 128 weight lists as the rows of one table: a matrix <span class="m">W₁</span> with 128 rows and 784 columns.</p><p>Each activation is one row times the column <span class="m">x</span>. All of them at once is a <b>matrix-vector multiply</b>: <span class="m">h = ReLU(W₁ x + b₁)</span>.</p>` },
    { to: { batch: 1 }, dur: 1600, say: `<p>Put many images side by side as the columns of a matrix <span class="m">X</span>, and the same multiply does them all: <span class="m">H = W₁ X</span>, a <b>GEMM</b> (general matrix multiply).</p><p>That is the card's <code>GEMM</code> command: 106 496 multiply-adds per image for this layer. The card stores the weights row by row, which is why its commands talk about <span class="m">Bᵀ</span>.</p><span class="hw">One shared input bus feeding 128 filters in parallel, each with its own coefficient memory: a filter bank.</span>` },
  ],
  hover(s, env) {
    const m = env.mouse; s.hover = -1;
    if (m && s.mat < 0.1) { const c = Math.floor((m.x - 24) / 57), r = Math.floor((m.y - 52) / 60); if (c >= 0 && c < 16 && r >= 0 && r < 8) s.hover = r * 16 + c; }
  },
  draw(ctx, s, { D }) {
    const r = D.run(s.img);
    const tileOrder = [...Array(128).keys()];
    const tx = (k) => 24 + (k % 16) * 57, ty = (k) => 52 + Math.floor(k / 16) * 60;
    // Matrix target: row k of W1 drawn as a thin horizontal line at (mx, my + k*2.6)
    const mx = 170, my = 60, mw = 392, rowH = 3.4;
    const u = ease(clamp(s.mat, 0, 1));
    for (const k of tileOrder) {
      const w = D.w1row(k);
      const act = r.h[k];
      const dim = s.lit > 0 ? lerp(1, act > 0 ? 1 : 0.18, s.lit) : 1;
      if (u < 0.999) {
        ctx.globalAlpha = (1 - u) * dim;
        grid(ctx, Array.from(w), 28, tx(k), ty(k), 2, (v) => divColor(v, 90));
        if (s.lit > 0 && act > 0) {
          ctx.globalAlpha = s.lit * (1 - u);
          ctx.strokeStyle = C.yellow; ctx.lineWidth = 1 + 2 * act / 127;
          ctx.strokeRect(tx(k) - 1, ty(k) - 1, 58, 58);
        }
      }
      if (u > 0.001) {
        ctx.globalAlpha = u;
        const y = my + k * rowH;
        for (let c = 0; c < 784; c += 2) {
          ctx.fillStyle = divColor((w[c] + w[c + 1]) / 2, 70);
          ctx.fillRect(mx + (c / 784) * mw, y, mw / 392 + 0.5, rowH - 0.6);
        }
      }
    }
    ctx.globalAlpha = 1;
    if (s.hover >= 0 && s.mat < 0.1) {
      const k = s.hover;
      box(ctx, tx(k) + 30, ty(k) - 34, 200, 30, { fill: "#0d141c", stroke: C.line });
      text(ctx, `neuron ${k}: h = ${r.h[k]}`, tx(k) + 40, ty(k) - 14, { font: MONO });
    }
    if (u > 0.05) {
      ctx.globalAlpha = u;
      text(ctx, "W₁", mx - 46, my + 220, { font: 'italic 30px "Source Serif 4", serif', color: C.yellow });
      text(ctx, "128 rows × 784 columns", mx, my - 14, { font: MONO, color: C.muted });
      // x column
      const xx = 600, xs = 435 / 784;
      text(ctx, "x", xx + 2, my - 14, { font: 'italic 22px "Source Serif 4", serif', color: C.yellow });
      for (let i = 0; i < 784; i++) { ctx.fillStyle = seqColor(r.x[i], 127, [235, 240, 245]); ctx.fillRect(xx, my + i * xs, 16, xs + 0.3); }
      text(ctx, "784", xx + 8, my + 452, { font: MONO, color: C.faint, align: "center" });
      text(ctx, "=", 650, my + 220, { font: '30px Inter', color: C.muted });
      // h column
      const hx = 690;
      text(ctx, "h", hx + 2, my - 14, { font: 'italic 22px "Source Serif 4", serif', color: C.yellow });
      for (let k = 0; k < 128; k++) { ctx.fillStyle = seqColor(r.h[k], 127, [244, 211, 94]); ctx.fillRect(hx, my + k * rowH, 16, rowH - 0.6); }
      text(ctx, "128", hx + 8, my + 128 * rowH + 18, { font: MONO, color: C.faint, align: "center" });
      text(ctx, "·", 580, my + 220, { font: '30px Inter', color: C.muted });
      ctx.globalAlpha = 1;
    }
    if (s.batch > 0.01) {
      ctx.globalAlpha = s.batch;
      const bx = 740, by = 60;
      text(ctx, "Many images: a GEMM", bx, by, { font: '600 15px Inter', color: C.ink });
      const lines = ["W₁  (128 × 784)", "  ·  X  (784 × M images)", "  =  H  (128 × M)", "", "MNIST test set: M = 10 000", "1 065 million MACs", "card: 163 ms (0.5.0)"];
      lines.forEach((l, i) => text(ctx, l, bx, by + 30 + i * 24, { font: MONO, color: i > 3 ? C.muted : C.ink }));
      // Small block diagram
      const gx = bx, gy = by + 210;
      box(ctx, gx, gy, 60, 120, { fill: "#1b2b3a", stroke: C.blue });
      text(ctx, "W₁", gx + 30, gy + 65, { font: 'italic 18px "Source Serif 4", serif', color: C.blue, align: "center" });
      box(ctx, gx + 80, gy, 120, 60, { fill: "#2a2a1a", stroke: C.yellow });
      text(ctx, "X", gx + 140, gy + 36, { font: 'italic 18px "Source Serif 4", serif', color: C.yellow, align: "center" });
      box(ctx, gx + 80, gy + 70, 120, 50, { fill: "#1d2a1d", stroke: C.green });
      text(ctx, "H", gx + 140, gy + 101, { font: 'italic 18px "Source Serif 4", serif', color: C.green, align: "center" });
      ctx.globalAlpha = 1;
    }
  },
  controls: (el, api) => imagePicker(el, api),
};

// ---------------------------------------------------------------------------
const relu = {
  id: "s-relu", kicker: "1.4", title: "Why the clamp at zero matters", w: 960, h: 500,
  init: () => ({ n: 0, fit: 0, lin: 0 }),
  steps: [
    { say: `<p>The ReLU, <span class="m">max(0, z)</span>: zero for negative inputs, the input itself for positive ones. A half-wave rectifier. It looks too simple to matter.</p>` },
    { to: { lin: 1 }, say: `<p>Without it, layer 2 would multiply layer 1's output by another matrix: <span class="m">W₂ (W₁ x) = (W₂ W₁) x</span>. Two matrices multiply into one. Any stack of linear layers collapses into a single matrix, a single linear filter.</p><p>And a linear filter cannot express "a loop at the top <i>and</i> a stem at the bottom", only weighted sums.</p>` },
    { to: { lin: 0, n: 1 }, say: `<p>With the clamp, each neuron becomes a <b>hinge</b>: flat, then a ramp, with the bend wherever its weighted sum crosses zero. Shift it with the bias, tilt it with the weights.</p>` },
    { to: { n: 3 }, dur: 1500, say: `<p>Add a few hinges with different positions and slopes, and you get a piecewise-linear curve.</p><span class="hw">A piecewise-linear lookup table, the kind used to linearize a sensor or approximate a transfer function: each breakpoint is one ReLU.</span>` },
    { to: { n: 10, fit: 1 }, dur: 2200, say: `<p>With enough hinges, any shape. That is what 128 ReLUs give layer 1: the freedom to carve the space of all possible images into regions, so the next layer can tell a 7 from a 1.</p><p>The non-linearity is what makes depth worth anything.</p>` },
  ],
  draw(ctx, s) {
    // Left: ReLU; right: hinge sum approximating a target curve
    const ox = 60, oy = 380, sx = 34, sy = 34;
    ctx.strokeStyle = C.line; ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(ox - 10, oy); ctx.lineTo(ox + 300, oy); ctx.moveTo(ox + 150, oy + 20); ctx.lineTo(ox + 150, oy - 300); ctx.stroke();
    text(ctx, "z", ox + 305, oy + 4, { font: 'italic 16px "Source Serif 4", serif', color: C.muted });
    ctx.strokeStyle = C.green; ctx.lineWidth = 3; ctx.beginPath();
    ctx.moveTo(ox, oy); ctx.lineTo(ox + 150, oy); ctx.lineTo(ox + 300, oy - 150 * 1.0); ctx.stroke();
    text(ctx, "ReLU(z) = max(0, z)", ox + 20, oy - 260, { font: 'italic 18px "Source Serif 4", serif', color: C.green });
    if (s.lin > 0) {
      ctx.globalAlpha = s.lin;
      box(ctx, ox, oy - 230, 280, 120, { fill: "#1a1416", stroke: C.red });
      text(ctx, "without it:", ox + 16, oy - 200, { font: MONO, color: C.red });
      text(ctx, "W₂ · (W₁ · x)", ox + 16, oy - 170, { font: 'italic 20px "Source Serif 4", serif' });
      text(ctx, "= (W₂W₁) · x   one matrix", ox + 16, oy - 138, { font: 'italic 18px "Source Serif 4", serif', color: C.muted });
      ctx.globalAlpha = 1;
    }
    // Hinge sum
    const px0 = 430, py0 = 400, pw = 480, ph = 300;
    ctx.strokeStyle = C.line; ctx.lineWidth = 1; ctx.beginPath(); ctx.moveTo(px0, py0); ctx.lineTo(px0 + pw, py0); ctx.stroke();
    const target = (x) => 0.55 + 0.35 * Math.sin(x * 2.2) + 0.12 * Math.cos(x * 5.1);   // x in [0, 3]
    const X = (x) => px0 + (x / 3) * pw, Y = (y) => py0 - y * ph * 0.8;
    // Fitted hinges: breakpoints evenly spaced, slopes chosen to interpolate the target
    const nmax = Math.max(1, Math.round(s.n));
    const knots = Array.from({ length: nmax + 1 }, (_, i) => (3 * i) / nmax);
    const vals = knots.map(target);
    const f = (x) => { // piecewise linear through knots
      for (let i = 0; i < nmax; i++) if (x <= knots[i + 1]) return lerp(vals[i], vals[i + 1], (x - knots[i]) / (knots[i + 1] - knots[i]));
      return vals[nmax];
    };
    if (s.fit > 0) {
      ctx.globalAlpha = s.fit * 0.6; ctx.strokeStyle = C.faint; ctx.lineWidth = 2; ctx.setLineDash([5, 5]); ctx.beginPath();
      for (let i = 0; i <= 200; i++) { const x = 3 * i / 200; i ? ctx.lineTo(X(x), Y(target(x))) : ctx.moveTo(X(x), Y(target(x))); }
      ctx.stroke(); ctx.setLineDash([]); ctx.globalAlpha = 1;
    }
    if (s.n > 0.01) {
      // individual hinges (faint), then their sum
      const slopes = []; for (let i = 0; i < nmax; i++) slopes.push((vals[i + 1] - vals[i]) / (knots[i + 1] - knots[i]));
      ctx.globalAlpha = Math.min(1, s.n) * 0.5;
      for (let i = 0; i < nmax && nmax <= 4; i++) {
        const ds = i === 0 ? slopes[0] : slopes[i] - slopes[i - 1];
        ctx.strokeStyle = [C.blue, C.yellow, C.purple, C.teal][i % 4]; ctx.lineWidth = 1.5; ctx.beginPath();
        ctx.moveTo(X(0), Y(0.1)); ctx.lineTo(X(knots[i]), Y(0.1)); ctx.lineTo(X(3), Y(0.1 + ds * (3 - knots[i]) * 0.3)); ctx.stroke();
      }
      ctx.globalAlpha = Math.min(1, s.n);
      ctx.strokeStyle = C.green; ctx.lineWidth = 3; ctx.beginPath();
      for (let i = 0; i <= 300; i++) { const x = 3 * i / 300; i ? ctx.lineTo(X(x), Y(f(x))) : ctx.moveTo(X(x), Y(f(x))); }
      ctx.stroke();
      for (const k of knots.slice(1, -1)) { ctx.fillStyle = C.yellow; ctx.beginPath(); ctx.arc(X(k), Y(f(k)), 4, 0, 7); ctx.fill(); }
      text(ctx, `${nmax} hinge${nmax > 1 ? "s" : ""} (ReLUs)`, px0, py0 - ph - 4, { font: MONO, color: C.ink });
      ctx.globalAlpha = 1;
    }
  },
};

// ---------------------------------------------------------------------------
const output = {
  id: "s-output", kicker: "1.5", title: "Layer 2: ten scores, and the biggest wins", w: 960, h: 540,
  init: () => ({ img: 0, one: 0, all: 0, win: 0 }),
  steps: [
    { say: `<p>The 128 activations <span class="m">h</span> from layer 1, as a column. Layer 2 does exactly the same thing again, with a smaller matrix: 10 neurons, one per digit, each with 128 weights.</p>` },
    { to: { one: 1 }, say: `<p>The "7" neuron: lines from each activation, <span class="blue">blue</span> for positive weights, <span class="red">red</span> for negative, thicker for larger. Its score is <span class="m">Σ h·w + b</span>, the same dot product as before.</p>` },
    { to: { all: 1 }, dur: 1400, say: `<p>All ten scores. These are called <b>logits</b>: unbounded 32-bit integers, kept at full precision because nothing comes after them.</p>` },
    { to: { win: 1 }, say: `<p>The answer is simply the largest score: <b>argmax</b>. No probability, no threshold.</p><p>That is all of inference: two matrix multiplies, one clamp, one argmax. <span class="n">101 632</span> multiply-adds per image (115 712 with the card's padding). Use the arrows below to try other digits, including a wrong one (image #8).</p>` },
  ],
  draw(ctx, s, { D }) {
    const r = D.run(s.img), m = D.model;
    const hx = 120, hy = 30, hh = 3.6;
    text(ctx, "h (128)", hx - 8, hy - 8 + 4, { font: MONO, color: C.muted, align: "right" });
    for (let k = 0; k < 128; k++) { ctx.fillStyle = seqColor(r.h[k], 127, [244, 211, 94]); ctx.fillRect(hx, hy + k * hh, 22, hh - 0.6); }
    const ox = 640, oy = (c) => 50 + c * 46;
    const target = 7;
    const lineFor = (c, alpha) => {
      for (let k = 0; k < 128; k++) {
        if (r.h[k] === 0) continue;
        const w = m.w2t[c * m.k2 + k];
        if (Math.abs(w) < 25) continue;
        ctx.globalAlpha = alpha * Math.min(1, (r.h[k] / 127) * 1.5);
        ctx.strokeStyle = w > 0 ? C.blue : C.red; ctx.lineWidth = Math.abs(w) / 40;
        ctx.beginPath(); ctx.moveTo(hx + 22, hy + k * hh + 1.5); ctx.lineTo(ox - 12, oy(c) + 10); ctx.stroke();
      }
      ctx.globalAlpha = 1;
    };
    if (s.one > 0) lineFor(target, s.one * (1 - s.all * 0.7));
    const lo = Math.min(...r.logits, 0), hi = Math.max(...r.logits, 1);
    for (let c = 0; c < 10; c++) {
      const show = c === target ? Math.max(s.one, s.all) : s.all;
      if (show <= 0) { text(ctx, String(c), ox, oy(c) + 16, { font: '600 18px "JetBrains Mono", monospace', color: C.faint }); continue; }
      const v = r.logits[c] * show;
      const win = s.win > 0 && c === r.pred;
      text(ctx, String(c), ox, oy(c) + 16, { font: '600 18px "JetBrains Mono", monospace', color: win ? C.yellow : C.ink });
      const zero = ox + 40 + (-lo / (hi - lo)) * 220;
      const w = (v / (hi - lo)) * 220;
      ctx.fillStyle = win ? C.yellow : v >= 0 ? C.blue : C.red;
      ctx.globalAlpha = win || s.win === 0 ? 1 : 0.55;
      ctx.fillRect(w >= 0 ? zero : zero + w, oy(c) + 2, Math.abs(w), 18);
      ctx.globalAlpha = 1;
      text(ctx, fmt(Math.round(v)), ox + 300, oy(c) + 16, { font: MONO, color: win ? C.yellow : C.muted, align: "right" });
    }
    if (s.win > 0) {
      ctx.globalAlpha = s.win;
      text(ctx, "argmax", 800, oy(r.pred) + 16, { font: MONO, color: C.yellow });
      box(ctx, 350, 200, 170, 150, { fill: "#141d27", stroke: r.pred === D.images[s.img].label ? C.green : C.red });
      text(ctx, String(r.pred), 435, 300, { font: '600 84px "JetBrains Mono", monospace', align: "center", color: C.ink });
      text(ctx, r.pred === D.images[s.img].label ? `correct (label ${D.images[s.img].label})` : `wrong: label is ${D.images[s.img].label}`, 435, 380, { font: MONO, align: "center", color: r.pred === D.images[s.img].label ? C.green : C.red });
      ctx.globalAlpha = 1;
    }
  },
  controls: (el, api) => imagePicker(el, api),
};

export const inferenceScenes = [pixels, neuron, layer, relu, output];
