// Part 2: training, from the real run that produced the card's weights
// (recorded by sw/mnist/lessons.py) and the float network's real outputs.
import { C, MONO, lerp, clamp, ease, grid, text, arrow, box, divColor, seqColor, fmt } from "./stage.js";

const softmax = (z) => { const m = Math.max(...z), e = z.map((v) => Math.exp(v - m)), s = e.reduce((a, b) => a + b, 0); return e.map((v) => v / s); };

// ---------------------------------------------------------------------------
const loss = {
  id: "s-loss", kicker: "2.1", title: "An error signal: how wrong is the network?", w: 960, h: 520,
  init: () => ({ img: 0, ex: 0, norm: 0, curve: 0, pc: -1 }),
  steps: [
    { say: `<p>To train, we need a single number that says how wrong the network is on an example, like the error signal of a control loop. Start from the float network's ten scores for test image #0, a "7".</p>` },
    { to: { ex: 1 }, dur: 1600, say: `<p>Scores can be negative and have no scale. First make them all positive: raise <span class="m">e</span> to each score. Big scores become enormous, small ones vanish. Order is kept.</p>` },
    { to: { norm: 1 }, say: `<p>Then divide each by their total, so they sum to 1. Now they read as confidences: the network is this sure the digit is a 7. This pair of steps is called <b>softmax</b>.</p><p>The card never computes it: for the answer, the largest score is enough. Softmax exists only for training.</p>` },
    { to: { curve: 1 }, say: `<p>The error, called the <b>loss</b>: <span class="m">L = −ln p<sub>correct</sub></span>, the negative log of the confidence in the right answer (<b>cross-entropy</b>).</p><p>Sure and right: <span class="m">p</span> near 1, loss near 0. Unsure: larger. Sure and wrong: very large. Drag the slider to feel the curve.</p>` },
    { to: { pc: 0.1 }, say: `<p>A network of random weights spreads its confidence evenly: <span class="m">p ≈ 1/10</span> for every digit, so <span class="m">L ≈ −ln 0.1 = 2.30</span>.</p><p>The real training run below started at a loss of <span class="n">2.40</span>, exactly that: chance. It ended near <span class="n">0.03</span>. Training means making this number small, averaged over all 60 000 training images.</p>` },
  ],
  draw(ctx, s, { D }) {
    const q = D.quant.images, label = q.labels[s.img], z = q.logits_float[s.img];
    const p = softmax(z), ez = z.map((v) => Math.exp(v - Math.max(...z)));
    const x0 = 60, top = 50, rowH = 40, w = 300;
    const zmax = Math.max(...z.map(Math.abs));
    text(ctx, s.norm > 0.5 ? "softmax: confidences" : s.ex > 0.5 ? "e^score (scaled)" : "scores (float network)", x0, top - 18, { font: MONO, color: C.muted });
    for (let c = 0; c < 10; c++) {
      const y = top + c * rowH;
      const raw = z[c] / zmax;                // -1..1
      const expd = ez[c];                     // 0..1 (largest is 1)
      const prob = p[c];                      // 0..1
      let v = lerp(raw, expd, ease(s.ex));
      v = lerp(v, prob, ease(s.norm));
      text(ctx, String(c), x0, y + 22, { font: '600 17px "JetBrains Mono", monospace', color: c === label ? C.yellow : C.ink });
      const zx = x0 + 40 + (s.ex > 0.5 ? 0 : w / 2) * (1 - s.ex);
      ctx.fillStyle = c === label ? C.yellow : v >= 0 ? C.blue : C.red;
      const len = v * (s.ex > 0 ? w : w / 2);
      ctx.fillRect(len >= 0 ? zx : zx + len, y + 6, Math.abs(len), 20);
      const lab = s.norm > 0.5 ? `${(prob * 100).toFixed(prob > 0.995 ? 2 : 1)} %` : s.ex > 0.5 ? expd.toExponential(1) : z[c].toFixed(1);
      text(ctx, lab, x0 + 40 + w + 70, y + 22, { font: MONO, color: C.muted, align: "right" });
    }
    if (s.curve > 0) {
      ctx.globalAlpha = s.curve;
      const gx = 560, gy = 440, gw = 340, gh = 360;
      ctx.strokeStyle = C.line; ctx.beginPath(); ctx.moveTo(gx, gy); ctx.lineTo(gx + gw, gy); ctx.moveTo(gx, gy); ctx.lineTo(gx, gy - gh); ctx.stroke();
      text(ctx, "p (confidence in the right digit)", gx + gw, gy + 22, { font: MONO, color: C.muted, align: "right" });
      text(ctx, "loss = −ln p", gx + 8, gy - gh + 8, { font: 'italic 18px "Source Serif 4", serif', color: C.yellow });
      const X = (pp) => gx + pp * gw, Y = (l) => gy - Math.min(l, 5) / 5 * gh;
      ctx.strokeStyle = C.yellow; ctx.lineWidth = 3; ctx.beginPath();
      for (let i = 1; i <= 200; i++) { const pp = i / 200; i > 1 ? ctx.lineTo(X(pp), Y(-Math.log(pp))) : ctx.moveTo(X(pp), Y(-Math.log(pp))); }
      ctx.stroke();
      for (const t of [0, 1, 2, 3, 4, 5]) text(ctx, String(t), gx - 8, Y(t) + 4, { font: MONO, color: C.faint, align: "right" });
      for (const t of [0, 0.5, 1]) text(ctx, String(t), X(t), gy + 40, { font: MONO, color: C.faint, align: "center" });
      const pc = s.pc >= 0 ? s.pc : p[label];
      const L = -Math.log(Math.max(pc, 1e-6));
      ctx.fillStyle = C.ink; ctx.beginPath(); ctx.arc(X(pc), Y(L), 7, 0, 7); ctx.fill();
      text(ctx, `p = ${pc.toFixed(3)}   loss = ${L.toFixed(3)}`, pc > 0.5 ? X(pc) - 12 : X(pc) + 12, Y(L) - 14, { font: MONO, align: pc > 0.5 ? "right" : "left" });
      ctx.globalAlpha = 1;
    }
  },
  controls(el, api) {
    const lab = document.createElement("label");
    lab.innerHTML = `Confidence in the right digit <input type="range" min="1" max="100" value="50"><span class="val">auto</span>`;
    lab.querySelector("input").addEventListener("input", (e) => {
      if (api.step < 3) api.go(3, false);
      const v = Number(e.target.value) / 100; api.set("pc", v); lab.querySelector(".val").textContent = v.toFixed(2);
    });
    el.appendChild(lab);
  },
};

// ---------------------------------------------------------------------------
// A 2-weight landscape: an elongated, tilted bowl, like a badly conditioned
// least-squares problem.
const Lf = (a, b) => { const u = 0.8 * a + 0.6 * b, v = -0.6 * a + 0.8 * b; return 0.5 * (u - 0.6) ** 2 * 8 + 0.5 * (v + 0.3) ** 2 * 0.7; };
const dL = (a, b) => { const u = 0.8 * a + 0.6 * b, v = -0.6 * a + 0.8 * b, gu = (u - 0.6) * 8, gv = (v + 0.3) * 0.7; return [0.8 * gu - 0.6 * gv, 0.6 * gu + 0.8 * gv]; };
function path(start, eta, adam, n) {
  let [a, b] = start; const P = [[a, b]]; let m = [0, 0], v = [0, 0];
  for (let t = 1; t <= n; t++) {
    const g = dL(a, b);
    if (adam) {
      m = m.map((mi, i) => 0.9 * mi + 0.1 * g[i]); v = v.map((vi, i) => 0.999 * vi + 0.001 * g[i] * g[i]);
      const st = m.map((mi, i) => (mi / (1 - 0.9 ** t)) / (Math.sqrt(v[i] / (1 - 0.999 ** t)) + 1e-8));
      a -= eta * st[0]; b -= eta * st[1];
    } else { a -= eta * g[0]; b -= eta * g[1]; }
    if (!isFinite(a) || Math.abs(a) > 50) break;
    P.push([a, b]);
  }
  return P;
}
const descent = {
  id: "s-descent", kicker: "2.2", title: "Gradient descent: walk downhill", w: 960, h: 540,
  init: () => ({ n: 0, eta: 0.12, adam: 0, grad: 0, sx: -1.6, sy: 1.5 }),
  steps: [
    { say: `<p>Pretend the network had only two weights. Every pair of values gives some loss, so the loss is a landscape over the weight plane, drawn here as contour lines. Training is the search for the lowest point.</p>` },
    { to: { grad: 1 }, say: `<p>Standing anywhere, we can compute the slope: the <b>gradient</b>, the vector of partial derivatives <span class="m">∂L/∂w</span>. It says how much the loss rises per unit change of each weight. It points uphill.</p>` },
    { to: { n: 60 }, dur: 2600, say: `<p>So step the other way, a little: <span class="m">w ← w − η · ∇L</span>. Recompute the slope, step again. This is <b>gradient descent</b>; <span class="m">η</span> is the <b>learning rate</b>.</p><span class="hw">An integrating controller driving the gradient to zero: the error is the slope, and η is the loop gain.</span>` },
    { to: { n: 0, eta: 0.23 }, run: (s) => { s.n = 60; }, dur: 300, say: `<p>Raise the gain to 0.23 and it overshoots across the narrow valley, oscillating on the way down. Past 0.25 it diverges. That is the stability limit of a loop with too much gain: η times the curvature (8 across this valley) must stay below 2.</p><p>Try the slider: the valley is steep one way and shallow the other, like a badly conditioned least-squares problem.</p>` },
    { to: { eta: 0.12, adam: 1 }, run: (s) => { s.n = 60; }, dur: 300, say: `<p>The training script uses <b>Adam</b>, gradient descent with two filters. It low-pass filters the gradient (momentum, a one-pole IIR with β = 0.9), and divides each weight's step by the RMS of its recent gradients (β = 0.999).</p><span class="hw">Automatic gain scheduling per weight: steep directions get small steps, shallow ones big steps. Here it walks the valley floor instead of bouncing.</span>` },
    { say: `<p>The real network does this in <span class="n">101 770</span> dimensions instead of 2. And it never sees the whole landscape: each step estimates the slope from a batch of 128 random images, a noisy measurement, so the path jitters (<b>stochastic</b> gradient descent).</p><p>One question is left: how to get the slope for 101 770 weights at once. That is backpropagation, next.</p>` },
  ],
  click(s, env) { if (!env.mouse) return; s.sx = (env.mouse.x - 480) / 140; s.sy = -(env.mouse.y - 270) / 140; s.n = 60; },
  draw(ctx, s) {
    const cx = 480, cy = 270, sc = 140;
    const toX = (a) => cx + a * sc, toY = (b) => cy - b * sc;
    // Contours
    const levels = [0.02, 0.08, 0.2, 0.4, 0.7, 1.1, 1.6, 2.3, 3.2, 4.3, 5.6];
    for (let li = 0; li < levels.length; li++) {
      ctx.strokeStyle = `rgba(88,196,221,${0.15 + 0.4 * (1 - li / levels.length)})`; ctx.lineWidth = 1.2;
      ctx.beginPath();
      // Ellipse in (u, v): 4 u'^2 + 0.35 v'^2 = level
      const L = levels[li];
      for (let i = 0; i <= 120; i++) {
        const th = (i / 120) * Math.PI * 2;
        const u = 0.6 + Math.sqrt(L / 4) * Math.cos(th), v = -0.3 + Math.sqrt(L / 0.35) * Math.sin(th);
        const a = 0.8 * u - 0.6 * v, b = 0.6 * u + 0.8 * v;
        i ? ctx.lineTo(toX(a), toY(b)) : ctx.moveTo(toX(a), toY(b));
      }
      ctx.stroke();
    }
    text(ctx, "weight 1 →", 900, cy + 20, { font: MONO, color: C.faint, align: "right" });
    text(ctx, "↑ weight 2", cx + 8, 24, { font: MONO, color: C.faint });
    // minimum
    const ma = 0.8 * 0.6 - 0.6 * -0.3, mb = 0.6 * 0.6 + 0.8 * -0.3;
    ctx.fillStyle = C.green; ctx.beginPath(); ctx.arc(toX(ma), toY(mb), 5, 0, 7); ctx.fill();
    text(ctx, "lowest loss", toX(ma) + 10, toY(mb) + 18, { font: MONO, color: C.green });
    // Start and gradient
    const start = [s.sx, s.sy];
    if (s.grad > 0) {
      const g = dL(...start), gl = Math.hypot(...g);
      ctx.globalAlpha = s.grad;
      arrow(ctx, toX(start[0]), toY(start[1]), toX(start[0] + g[0] / gl * 0.6), toY(start[1] + g[1] / gl * 0.6), { color: C.red, width: 3 });
      text(ctx, "∇L (uphill)", toX(start[0] + g[0] / gl * 0.6) + 8, toY(start[1] + g[1] / gl * 0.6), { font: MONO, color: C.red });
      ctx.globalAlpha = 1;
    }
    const n = Math.round(s.n);
    if (n > 0) {
      const P = path(start, s.eta, s.adam > 0.5, n);
      ctx.strokeStyle = s.adam > 0.5 ? C.green : C.yellow; ctx.lineWidth = 2.2; ctx.beginPath();
      P.forEach(([a, b], i) => (i ? ctx.lineTo(toX(a), toY(b)) : ctx.moveTo(toX(a), toY(b))));
      ctx.stroke();
      for (const [a, b] of P) { ctx.fillStyle = s.adam > 0.5 ? C.green : C.yellow; ctx.beginPath(); ctx.arc(toX(a), toY(b), 2.6, 0, 7); ctx.fill(); }
      const [la, lb] = P[P.length - 1];
      text(ctx, `${s.adam > 0.5 ? "Adam" : "gradient descent"}, η = ${s.eta.toFixed(2)}: loss ${Math.min(Lf(la, lb), 999).toFixed(3)} after ${P.length - 1} steps${P.length - 1 < n ? " (diverged)" : ""}`, 24, 515, { font: MONO, color: C.ink });
    }
    ctx.fillStyle = C.ink; ctx.beginPath(); ctx.arc(toX(start[0]), toY(start[1]), 7, 0, 7); ctx.fill();
    text(ctx, "click anywhere to start there", 936, 515, { font: MONO, color: C.faint, align: "right" });
  },
  controls(el, api) {
    const lab = document.createElement("label");
    lab.innerHTML = `Learning rate η <input type="range" min="1" max="32" value="12"><span class="val">0.12</span>`;
    lab.querySelector("input").addEventListener("input", (e) => {
      const v = Number(e.target.value) / 100; api.set("eta", v); lab.querySelector(".val").textContent = v.toFixed(2);
      if (api.state.n === 0) api.set("n", 60);
    });
    const b = document.createElement("button"); b.textContent = "Adam on/off";
    b.addEventListener("click", () => { api.set("adam", api.state.adam > 0.5 ? 0 : 1); if (api.state.n === 0) api.set("n", 60); });
    el.append(lab, b);
  },
};

// ---------------------------------------------------------------------------
const backprop = {
  id: "s-backprop", kicker: "2.3", title: "Backpropagation: the chain rule, run backwards", w: 960, h: 560,
  init: () => ({ img: 8, fwd: 0, err: 0, g2: 0, back: 0, g1: 0 }),   // #8: a 5 the network calls a 6
  steps: [
    { to: { fwd: 1 }, dur: 1600, say: `<p>The forward pass, as a chain of blocks: pixels <span class="m">x</span>, layer 1, ReLU, activations <span class="m">h</span>, layer 2, scores <span class="m">z</span>, softmax, loss. We need <span class="m">∂L/∂w</span> for every weight in both matrices.</p><p>To see a real error, use test image #8: a 5 that the finished network calls a 6.</p>` },
    { to: { err: 1 }, say: `<p>Start at the end. For softmax with cross-entropy, the derivative of the loss with respect to the scores is beautifully simple:</p><p class="m">∂L/∂z = p − y</p><p>predicted confidences minus the target (1 for the right digit, 0 elsewhere). An error vector: measurement minus setpoint. Here: too much confidence in 6 (positive), too little in 5 (negative). In <code>train.py</code>: <code>p[range, yb] -= 1</code>.</p>` },
    { to: { g2: 1 }, say: `<p>The gradient for layer 2's weights: <span class="m">∂L/∂W₂ = h · (p − y)ᵀ</span>, an outer product. The weight from hidden neuron <span class="m">k</span> to digit <span class="m">c</span> changes in proportion to how active <span class="m">k</span> was times how wrong <span class="m">c</span> was.</p><p>Inactive neurons (zeros) get no blame. Shown here: 128 × 10, red means "this weight should go up".</p>` },
    { to: { back: 1 }, dur: 1500, say: `<p>To reach layer 1, send the error backwards through layer 2's weights, <b>transposed</b>: <span class="m">∂L/∂h = W₂ᵀ (p − y)</span>, then zero it wherever the ReLU was clamped (its slope there is 0).</p><span class="hw">The Jacobian transpose. In a robot arm, joint torques that produce an end-effector force are τ = Jᵀ F. Here, the blame on each hidden neuron for an output error is W₂ᵀ times the error. Same mathematics: backprop is Jᵀ applied layer by layer.</span>` },
    { to: { g1: 1 }, say: `<p>Finally layer 1: <span class="m">∂L/∂W₁ = x · (∂L/∂h)ᵀ</span>. For each neuron, its correction is <b>the input image itself</b>, scaled by that neuron's blame. Shown for the most-blamed neuron: the update literally adds or subtracts a faint copy of the digit to its template.</p><p>That is how templates come to look like strokes: they are sums of the digits they were corrected with.</p>` },
    { say: `<p>Then every weight moves a small step against its gradient (Adam, previous scene). The whole thing, forward, backward, update, is about 20 lines of NumPy in <code>train.py</code>, and it ran 4690 times, on batches of 128 images.</p><p>Each pass costs about three times an inference: one forward, two matrix multiplies backward. That is why training happens on a PC and only inference runs on the card.</p>` },
  ],
  draw(ctx, s, { D }) {
    const q = D.quant, im = q.images, label = im.labels[s.img];
    const z = im.logits_float[s.img], p = softmax(z), y = z.map((_, c) => (c === label ? 1 : 0));
    const dz = p.map((v, c) => v - y[c]);
    const h = im.h_float[s.img];
    const m = D.model, sw2 = q.s_w2;
    const dh = Array.from({ length: 128 }, (_, k) => { let a = 0; for (let c = 0; c < 10; c++) a += m.w2t[c * m.k2 + k] * sw2 * dz[c]; return h[k] > 0 ? a : 0; });
    // Chain of blocks
    const blocks = [["x", "pixels 784"], ["W₁", "layer 1"], ["ReLU", ""], ["h", "128"], ["W₂", "layer 2"], ["z", "scores 10"], ["softmax", ""], ["L", "loss"]];
    const bx = (i) => 30 + i * 117, by = 30;
    blocks.forEach(([n, sub], i) => {
      const lit = s.fwd * 8 > i;
      box(ctx, bx(i), by, 92, 54, { fill: lit ? "#16222e" : "#10171f", stroke: lit ? C.blue : C.line });
      text(ctx, n, bx(i) + 46, by + 28, { font: 'italic 19px "Source Serif 4", serif', align: "center", color: lit ? C.ink : C.faint });
      text(ctx, sub, bx(i) + 46, by + 46, { font: '500 10.5px "JetBrains Mono", monospace', align: "center", color: C.faint });
      if (i < 7) arrow(ctx, bx(i) + 94, by + 20, bx(i + 1) - 4, by + 20, { color: lit ? C.blue : C.line, head: 7 });
    });
    if (s.err > 0 || s.back > 0) {
      const steps = [[7, 5, s.err], [5, 3, s.back], [3, 1, s.g1]];
      for (const [a, b, al] of steps) if (al > 0) arrow(ctx, bx(a) + 10, by + 66, bx(b) + 82, by + 66, { color: C.red, alpha: al, head: 8, width: 2.5 });
      text(ctx, "error flows backwards", bx(4), by + 88, { font: MONO, color: C.red, alpha: s.err, align: "center" });
    }
    // Panels
    const py = 150;
    if (s.err > 0) {
      ctx.globalAlpha = s.err;
      text(ctx, "p − y  (∂L/∂z)", 40, py, { font: MONO, color: C.muted });
      for (let c = 0; c < 10; c++) {
        const yy = py + 14 + c * 30;
        text(ctx, String(c), 40, yy + 16, { font: '600 15px "JetBrains Mono", monospace', color: c === label ? C.yellow : C.ink });
        const w = dz[c] * 120;
        ctx.fillStyle = dz[c] < 0 ? C.green : C.red;
        ctx.fillRect(w >= 0 ? 180 : 180 + w, yy + 3, Math.max(1, Math.abs(w)), 16);
        text(ctx, dz[c].toFixed(3), 340, yy + 16, { font: MONO, color: C.muted, align: "right" });
      }
      ctx.strokeStyle = C.faint; ctx.beginPath(); ctx.moveTo(180, py + 14); ctx.lineTo(180, py + 312); ctx.stroke();
      ctx.globalAlpha = 1;
    }
    if (s.g2 > 0) {
      ctx.globalAlpha = s.g2;
      text(ctx, "∂L/∂W₂ = h(p−y)ᵀ", 380, py, { font: MONO, color: C.muted });
      text(ctx, "128 × 10", 380, py + 340, { font: MONO, color: C.faint });
      let mx = 1e-9; for (let k = 0; k < 128; k++) for (let c = 0; c < 10; c++) mx = Math.max(mx, Math.abs(h[k] * dz[c]));
      for (let k = 0; k < 128; k++) for (let c = 0; c < 10; c++) {
        ctx.fillStyle = divColor(-h[k] * dz[c], mx * 0.7);
        ctx.fillRect(380 + c * 14, py + 12 + k * 2.4, 13, 2.4);
      }
      ctx.globalAlpha = 1;
    }
    if (s.back > 0) {
      ctx.globalAlpha = s.back;
      text(ctx, "∂L/∂h", 570, py, { font: MONO, color: C.muted });
      let mx = 1e-9; for (const v of dh) mx = Math.max(mx, Math.abs(v));
      for (let k = 0; k < 128; k++) { ctx.fillStyle = h[k] > 0 ? divColor(-dh[k], mx * 0.7) : "#0e141b"; ctx.fillRect(570, py + 12 + k * 2.4, 40, 2.4); }
      text(ctx, "= W₂ᵀ(p−y), gated", 540, py + 340, { font: '500 11px "JetBrains Mono", monospace', color: C.faint });
      text(ctx, "dark: ReLU was 0", 540, py + 356, { font: '500 11px "JetBrains Mono", monospace', color: C.faint });
      ctx.globalAlpha = 1;
    }
    if (s.g1 > 0) {
      ctx.globalAlpha = s.g1;
      let jm = 0; for (let k = 1; k < 128; k++) if (Math.abs(dh[k]) > Math.abs(dh[jm])) jm = k;
      const x = D.run(s.img).x;
      text(ctx, `∂L/∂W₁, neuron ${jm}`, 700, py, { font: MONO, color: C.muted });
      text(ctx, `= x × ${(-dh[jm]).toFixed(4)}`, 700, py + 18, { font: MONO, color: C.muted });
      grid(ctx, Array.from({ length: 784 }, (_, i) => -dh[jm] * x[i]), 28, 700, py + 32, 8, (v) => divColor(v, Math.abs(dh[jm]) * 127 * 0.8));
      text(ctx, "the digit itself, as a correction", 700, py + 32 + 28 * 8 + 20, { font: '500 11px "JetBrains Mono", monospace', color: C.faint });
      ctx.globalAlpha = 1;
    }
  },
};

// ---------------------------------------------------------------------------
const replay = {
  id: "s-replay", kicker: "2.4", title: "Watch it learn: the real training run, replayed", w: 960, h: 560,
  init: () => ({ step: 0 }),
  steps: [
    { say: `<p>Step 0. The weights are random numbers (scaled so signals neither blow up nor die out). Here are 16 of layer 1's neurons, the 16 with the most structure at the end, as they were at the start: noise.</p>` },
    { to: { step: 10 }, dur: 1500, say: `<p>After 10 steps (1 280 images seen), the loss has dropped from 2.40 to about 1.5. The templates barely changed: big coarse corrections first, mostly in the biases and layer 2.</p>` },
    { to: { step: 100 }, dur: 2000, say: `<p>After 100 steps the loss is below 0.5. Faint strokes appear in the noise: each step added scaled copies of the digits that neuron was blamed for.</p>` },
    { to: { step: 469 }, dur: 2400, say: `<p>One <b>epoch</b>: every one of the 60 000 training images seen once. On the 10 000 test images, which training never sees, the network already scores <span class="n">94.57 %</span>.</p>` },
    { to: { step: 4690 }, dur: 4000, say: `<p>Ten epochs, 4 690 steps, 600 000 image presentations, about a minute on a PC. Test accuracy <span class="n">97.11 %</span>. The learning rate was cut by 0.7 each epoch (gain scheduling again), for finer steps near the bottom.</p><p>These are the weights the card runs. Drag the slider to scrub through the run.</p>` },
  ],
  draw(ctx, s, { D }) {
    const T = D.training, snaps = T.snapshots, step = s.step;
    // Loss curve
    const gx = 50, gy = 470, gw = 420, gh = 380;
    const X = (st) => gx + (st / 4690) * gw, Y = (l) => gy - (Math.log10(Math.max(l, 0.01)) + 2) / 2.5 * gh;
    ctx.strokeStyle = C.line; ctx.beginPath(); ctx.moveTo(gx, gy); ctx.lineTo(gx + gw, gy); ctx.moveTo(gx, gy); ctx.lineTo(gx, gy - gh); ctx.stroke();
    for (const l of [0.01, 0.1, 1]) { text(ctx, String(l), gx - 8, Y(l) + 4, { font: MONO, color: C.faint, align: "right" }); ctx.strokeStyle = "#141c26"; ctx.beginPath(); ctx.moveTo(gx, Y(l)); ctx.lineTo(gx + gw, Y(l)); ctx.stroke(); }
    for (let e = 1; e <= 10; e++) text(ctx, String(e), X(e * 469), gy + 18, { font: MONO, color: C.faint, align: "center" });
    text(ctx, "epoch", gx + gw, gy + 38, { font: MONO, color: C.faint, align: "right" });
    text(ctx, "loss per batch (log scale): measured, and averaged", gx, gy - gh - 10, { font: MONO, color: C.muted });
    // Each point is one batch of 128 images: noisy. Faint: as measured; bright: averaged over 20 points.
    ctx.strokeStyle = "rgba(244,211,94,0.3)"; ctx.lineWidth = 1; ctx.beginPath();
    let first = true, last = null;
    for (const [st, l] of T.loss) { if (st > step) break; first ? ctx.moveTo(X(st), Y(l)) : ctx.lineTo(X(st), Y(l)); first = false; last = [st, l]; }
    ctx.stroke();
    ctx.strokeStyle = C.yellow; ctx.lineWidth = 2.2; ctx.beginPath(); first = true;
    for (let i = 0; i < T.loss.length && T.loss[i][0] <= step; i++) {
      const lo = Math.max(0, i - 10), hi = Math.min(T.loss.length, i + 10); let a = 0; for (let k = lo; k < hi; k++) a += T.loss[k][1];
      const st = T.loss[i][0], l = a / (hi - lo); first ? ctx.moveTo(X(st), Y(l)) : ctx.lineTo(X(st), Y(l)); first = false;
    }
    ctx.stroke();
    for (const [st, a] of T.test_accuracy) if (st <= step) {
      ctx.fillStyle = C.green; ctx.beginPath(); ctx.arc(X(st), gy - gh + 30, 4, 0, 7); ctx.fill();
      if (st === 469 || st === 4690) text(ctx, `${a} %`, X(st), gy - gh + 50, { font: MONO, color: C.green, align: "center" });
    }
    text(ctx, "test accuracy, after each epoch", gx + gw, gy - gh + 12, { font: MONO, color: C.green, align: "right" });
    text(ctx, `step ${Math.round(step)}${last ? `   loss ${last[1].toFixed(3)}` : ""}`, gx, 530, { font: '600 15px "JetBrains Mono", monospace', color: C.ink });
    // Templates: interpolate between recorded snapshots
    const S = snaps.steps; let i = 0; while (i < S.length - 2 && S[i + 1] <= step) i++;
    const u = clamp((step - S[i]) / (S[i + 1] - S[i]), 0, 1);
    const per = 16 * 784;
    const tx = 520, ty = 40, cell = 3, tile = 28 * cell + 12;
    for (let n = 0; n < 16; n++) {
      const a0 = (i * per) + n * 784, a1 = ((i + 1) * per) + n * 784, s0 = snaps.scales[i], s1 = snaps.scales[i + 1];
      let mx = 0; const vals = new Float32Array(784);
      for (let k = 0; k < 784; k++) { vals[k] = lerp(D.snaps[a0 + k] * s0, D.snaps[a1 + k] * s1, u); mx = Math.max(mx, Math.abs(vals[k])); }
      grid(ctx, vals, 28, tx + (n % 4) * tile, ty + Math.floor(n / 4) * tile, cell, (v) => divColor(v, mx * 0.75));
      text(ctx, `#${snaps.neurons[n]}`, tx + (n % 4) * tile, ty + Math.floor(n / 4) * tile + 28 * cell + 10, { font: '500 9.5px "JetBrains Mono", monospace', color: C.faint });
    }
    text(ctx, "16 of layer 1's neurons (weights, each scaled to its own range)", tx, 30, { font: MONO, color: C.muted });
  },
  controls(el, api) {
    const lab = document.createElement("label");
    lab.innerHTML = `Training step <input type="range" min="0" max="4690" value="0" style="width:300px"><span class="val">0</span>`;
    lab.querySelector("input").addEventListener("input", (e) => { const v = Number(e.target.value); api.set("step", v); lab.querySelector(".val").textContent = v; });
    el.appendChild(lab);
  },
};

export const trainingScenes = [loss, descent, backprop, replay];
