// stage.js: a small engine for step-by-step animated scenes.
//
// A scene is a canvas and a narration panel. Its definition gives an initial
// state (plain numbers and values), a list of steps, and a draw function.
// Each step says something (the narration) and moves some state values to new
// targets; the engine tweens numbers between steps, so every change animates,
// and remembers the state at the end of each step, so Back is exact.
//
//   mountScene(host, {
//     id, kicker, title, w, h,
//     init: (D) => state,
//     steps: [{ say: "html", to: { k: v }, dur: 1200, run: (s, D) => {} }],
//     draw: (ctx, s, env) => {},          // env: { D, W, H, t, step }
//     controls: (el, api) => {},          // optional widgets under the canvas
//   }, D)

export const C = {
  bg: "#0b1017", panel: "#111923", ink: "#e8eef4", muted: "#93a2b1", faint: "#5d6c7a", line: "#22303d",
  blue: "#58c4dd", yellow: "#f4d35e", red: "#fc6255", green: "#83c167", teal: "#5cd0b3", purple: "#c79bf5", orange: "#f0a83a",
};
export const MONO = '500 13px "JetBrains Mono", ui-monospace, monospace';
export const SANS = '500 14px Inter, system-ui, sans-serif';

export const lerp = (a, b, u) => a + (b - a) * u;
export const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
export const ease = (u) => (u < 0.5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2);
export const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

// Colors for values: weights are diverging (red negative, blue positive),
// activations and pixels sequential.
export function divColor(v, max) {
  const u = clamp(v / max, -1, 1);
  const base = [17, 25, 35];
  const tgt = u >= 0 ? [88, 196, 221] : [252, 98, 85];
  const a = Math.pow(Math.abs(u), 0.8);
  return `rgb(${base.map((b, i) => Math.round(b + (tgt[i] - b) * a)).join(",")})`;
}
export function seqColor(v, max, hue = [168, 212, 255]) {
  const u = clamp(v / max, 0, 1), base = [17, 25, 35];
  return `rgb(${base.map((b, i) => Math.round(b + (hue[i] - b) * u)).join(",")})`;
}

// Draw a grid of values as cells. color(v) -> css color.
export function grid(ctx, vals, cols, x, y, cell, color, gap = 0) {
  for (let i = 0; i < vals.length; i++) {
    ctx.fillStyle = color(vals[i], i);
    ctx.fillRect(x + (i % cols) * cell, y + Math.floor(i / cols) * cell, cell - gap, cell - gap);
  }
}
export function text(ctx, s, x, y, { font = SANS, color = C.ink, align = "left", base = "alphabetic", alpha = 1 } = {}) {
  ctx.save(); ctx.globalAlpha *= alpha; ctx.font = font; ctx.fillStyle = color; ctx.textAlign = align; ctx.textBaseline = base;
  ctx.fillText(s, x, y); ctx.restore();
}
export function arrow(ctx, x1, y1, x2, y2, { color = C.muted, width = 2, head = 9, alpha = 1 } = {}) {
  const a = Math.atan2(y2 - y1, x2 - x1);
  ctx.save(); ctx.globalAlpha *= alpha; ctx.strokeStyle = ctx.fillStyle = color; ctx.lineWidth = width;
  ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2 - Math.cos(a) * head * 0.6, y2 - Math.sin(a) * head * 0.6); ctx.stroke();
  ctx.beginPath(); ctx.moveTo(x2, y2);
  ctx.lineTo(x2 - head * Math.cos(a - 0.4), y2 - head * Math.sin(a - 0.4));
  ctx.lineTo(x2 - head * Math.cos(a + 0.4), y2 - head * Math.sin(a + 0.4)); ctx.closePath(); ctx.fill();
  ctx.restore();
}
export function box(ctx, x, y, w, h, { fill = C.panel, stroke = C.line, r = 10, alpha = 1, lw = 1.5 } = {}) {
  ctx.save(); ctx.globalAlpha *= alpha; ctx.beginPath(); ctx.roundRect(x, y, w, h, r);
  if (fill) { ctx.fillStyle = fill; ctx.fill(); }
  if (stroke) { ctx.strokeStyle = stroke; ctx.lineWidth = lw; ctx.stroke(); }
  ctx.restore();
}
export const fmt = (v, d = 0) => Number(v).toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });

const clone = (o) => {
  const r = {};
  for (const [k, v] of Object.entries(o)) r[k] = Array.isArray(v) ? v.slice() : v;
  return r;
};

export function mountScene(host, def, D) {
  const W = def.w || 960, H = def.h || 540;
  const el = document.createElement("section");
  el.className = "scene"; el.id = def.id;
  el.innerHTML = `
    <div class="scene-head"><p class="kicker">${def.kicker || ""}</p><h2>${def.title}</h2>${def.video ? `<a class="video" href="${def.video}">▶ Watch as a video (Manim)</a>` : ""}</div>
    <div class="scene-body">
      <div class="stage"><canvas width="${W}" height="${H}" aria-label="${def.title}"></canvas><div class="ctrls"></div></div>
      <aside class="narr">
        <div class="say" aria-live="polite"></div>
        <div class="nav">
          <button class="prev" aria-label="Previous step">◀</button>
          <span class="count"></span>
          <button class="next" aria-label="Next step">Next ▶</button>
          <button class="play" aria-label="Play every step">Play all</button>
        </div>
        <ol class="dots"></ol>
      </aside>
    </div>`;
  host.appendChild(el);
  const canvas = el.querySelector("canvas"), ctx = canvas.getContext("2d");
  const dpr = Math.min(2, window.devicePixelRatio || 1);
  canvas.width = W * dpr; canvas.height = H * dpr; ctx.scale(dpr, dpr);
  const sayEl = el.querySelector(".say"), countEl = el.querySelector(".count"), dotsEl = el.querySelector(".dots");
  dotsEl.innerHTML = def.steps.map((_, i) => `<li><button aria-label="Step ${i + 1}"></button></li>`).join("");

  // State at the end of each step: ends[i]
  const ends = [];
  let s = def.init(D);
  const apply = (st, step) => { const r = { ...clone(st), ...(step.to || {}) }; if (step.run) step.run(r, D); return r; };
  ends[0] = apply(s, def.steps[0]);
  s = clone(ends[0]);
  let cur = 0, anim = null, playing = false, visible = false, t0 = performance.now();

  const env = { D, W, H, t: 0, step: 0, redraw: () => draw() };
  function draw() {
    env.t = (performance.now() - t0) / 1000; env.step = cur;
    ctx.save(); ctx.clearRect(0, 0, W, H); ctx.fillStyle = C.bg; ctx.fillRect(0, 0, W, H);
    def.draw(ctx, s, env);
    ctx.restore();
  }
  function show() {
    sayEl.innerHTML = def.steps[cur].say;
    countEl.textContent = `${cur + 1} / ${def.steps.length}`;
    [...dotsEl.children].forEach((li, i) => li.classList.toggle("on", i <= cur));
    el.querySelector(".prev").disabled = cur === 0;
    el.querySelector(".next").disabled = cur === def.steps.length - 1;
  }
  function go(i, animate = true) {
    i = clamp(i, 0, def.steps.length - 1);
    if (anim) { cancelAnimationFrame(anim.raf); anim = null; }
    for (let k = ends.length; k <= i; k++) ends[k] = apply(ends[k - 1], def.steps[k]);
    const from = clone(s), to = clone(ends[i]);
    const forward = i === cur + 1;
    cur = i; show();
    const dur = reduceMotion || !animate || !forward ? 0 : (def.steps[i].dur ?? 1100);
    if (!dur) { s = to; draw(); return Promise.resolve(); }
    return new Promise((res) => {
      const start = performance.now();
      const tick = (now) => {
        const u = clamp((now - start) / dur, 0, 1), e = ease(u);
        for (const k of Object.keys(to)) {
          const a = from[k], b = to[k];
          if (typeof b === "number" && typeof a === "number") s[k] = lerp(a, b, e);
          else if (Array.isArray(b) && Array.isArray(a) && a.length === b.length && typeof b[0] === "number") s[k] = b.map((v, j) => lerp(a[j], v, e));
          else s[k] = b;
        }
        draw();
        if (u < 1) anim = { raf: requestAnimationFrame(tick) }; else { anim = null; s = to; draw(); res(); }
      };
      anim = { raf: requestAnimationFrame(tick) };
    });
  }
  async function playAll() {
    if (playing) { playing = false; el.querySelector(".play").textContent = "Play all"; return; }
    playing = true; el.querySelector(".play").textContent = "Pause";
    if (cur === def.steps.length - 1) go(0, false);
    while (playing && cur < def.steps.length - 1) {
      await go(cur + 1);
      const words = def.steps[cur].say.replace(/<[^>]+>/g, "").split(/\s+/).length;
      await new Promise((r) => setTimeout(r, reduceMotion ? 2500 : 900 + words * 230));
    }
    playing = false; el.querySelector(".play").textContent = "Replay";
  }
  el.querySelector(".prev").addEventListener("click", () => { playing = false; go(cur - 1); });
  el.querySelector(".next").addEventListener("click", () => { playing = false; go(cur + 1); });
  el.querySelector(".play").addEventListener("click", playAll);
  [...dotsEl.querySelectorAll("button")].forEach((b, i) => b.addEventListener("click", () => { playing = false; go(i, i === cur + 1); }));
  el.tabIndex = -1;
  el.addEventListener("keydown", (e) => {
    if (e.target.closest("input, select, textarea")) return;
    if (e.key === "ArrowRight") { e.preventDefault(); go(cur + 1); }
    if (e.key === "ArrowLeft") { e.preventDefault(); go(cur - 1); }
  });

  // Ambient animation (scenes that use env.t) only while on screen
  if (def.ambient) {
    const io = new IntersectionObserver((es) => { visible = es[0].isIntersecting; if (visible) loop(); });
    io.observe(canvas);
    const loop = () => { if (!visible) return; if (!anim) draw(); requestAnimationFrame(loop); };
  }

  // Pointer position in canvas coordinates, for interactive scenes
  canvas.addEventListener("pointermove", (e) => {
    const r = canvas.getBoundingClientRect();
    env.mouse = { x: (e.clientX - r.left) * W / r.width, y: (e.clientY - r.top) * H / r.height };
    if (def.hover) { def.hover(s, env); draw(); }
  });
  canvas.addEventListener("pointerleave", () => { env.mouse = null; if (def.hover) { def.hover(s, env); draw(); } });
  if (def.click) canvas.addEventListener("click", () => { def.click(s, env); draw(); });

  const api = {
    get state() { return s; }, set: (k, v) => { s[k] = v; for (const e of ends) if (e) e[k] = v; draw(); },
    redraw: draw, go, get step() { return cur; }, env,
  };
  if (def.controls) def.controls(el.querySelector(".ctrls"), api);
  show(); draw();
  return api;
}
