// Part 4: the engine in hardware (hw/rtl/npu_mm.v on DSP48E1 slices) and
// the measured results (docs/bringup.md, phase 4).
import { C, MONO, lerp, clamp, ease, text, arrow, box, fmt } from "./stage.js";

const SMALL = '500 11px "JetBrains Mono", monospace';

// ---------------------------------------------------------------------------
const dsp = {
  id: "s-dsp", kicker: "4.1", title: "Multipliers: DSP slices, lanes and a pipeline", w: 960, h: 560, ambient: true,
  init: () => ({ slice: 1, one: 0, lanes: 0, tree: 0, pipe: 0 }),
  steps: [
    { say: `<p>The Artix-7 200T has <span class="n">740</span> <b>DSP48E1</b> slices: hard blocks next to the logic fabric, each with a 25 × 18-bit multiplier and a 48-bit adder that can feed back on itself. One multiply and one add per clock.</p><p>Every multiply in this network ends up in one of these.</p>` },
    { to: { one: 1 }, say: `<p>One step of the dot product from scene 1.2: a pixel byte times a weight byte, both signed 8-bit, sign-extended into the multiplier's inputs. A 16-bit product.</p><p>One product per clock at 125 MHz would be 125 million per second, too slow: one image needs 115 712.</p>` },
    { to: { lanes: 1 }, dur: 1500, say: `<p>So the engine reads 64 bits at a time: <b>eight</b> bytes of the image and the matching eight bytes of a weight row, one memory beat per clock. Eight multipliers take one byte pair each: eight products per clock.</p><span class="hw">A 64-bit bus split into byte lanes, a SIMD unit in hardware: <code>pr[i] = a[8i+7:8i] * b[8i+7:8i]</code> for i = 0 to 7.</span>` },
    { to: { tree: 1 }, say: `<p>Eight products must become one number: an adder tree, 4 + 4, then the two halves, then into the 32-bit accumulator that runs over the whole row (K/8 = 104 beats for this network).</p><p>The multiplies live in the DSP slices; the adds in the fabric's carry chains.</p>` },
    { to: { pipe: 1 }, say: `<p>All of that, plus the bias and the requantization of scene 3.2, in one clock is far too slow: the first version tried, needed 12 ns against the 8 ns clock, and failed timing by 4.2 ns.</p><p>The fix is a <b>pipeline</b>: nine stages, each with a register at its end. A beat enters every clock; each stage works on a different beat at once. Latency nine clocks; throughput one beat per clock. Watch the beats march.</p>` },
  ],
  draw(ctx, s, { t }) {
    // A DSP48E1 slice (simplified)
    const sx = 40, sy = 40;
    const drawSlice = (x, y, sc, alpha, label) => {
      ctx.save(); ctx.globalAlpha *= alpha; ctx.translate(x, y); ctx.scale(sc, sc);
      box(ctx, 0, 0, 300, 200, { fill: "#121c27", stroke: C.purple, lw: 2 });
      text(ctx, label, 12, 22, { font: MONO, color: C.purple });
      box(ctx, 30, 50, 60, 40, { fill: "#182532", stroke: C.line }); text(ctx, "pre-add", 60, 75, { font: SMALL, color: C.muted, align: "center" });
      box(ctx, 110, 60, 70, 70, { fill: "#1c2b3a", stroke: C.blue, lw: 2 }); text(ctx, "×", 145, 104, { font: '600 30px Inter', color: C.blue, align: "center" });
      text(ctx, "25×18", 145, 146, { font: SMALL, color: C.faint, align: "center" });
      box(ctx, 200, 70, 70, 60, { fill: "#1c2b3a", stroke: C.green, lw: 2 }); text(ctx, "+", 235, 108, { font: '600 28px Inter', color: C.green, align: "center" });
      text(ctx, "48-bit", 235, 146, { font: SMALL, color: C.faint, align: "center" });
      arrow(ctx, 90, 70, 108, 80, { color: C.muted }); arrow(ctx, 180, 95, 198, 100, { color: C.muted });
      ctx.strokeStyle = C.green; ctx.lineWidth = 1.5; ctx.beginPath(); ctx.moveTo(270, 100); ctx.lineTo(290, 100); ctx.lineTo(290, 178); ctx.lineTo(220, 178); ctx.lineTo(220, 132); ctx.stroke();
      text(ctx, "accumulate", 250, 194, { font: SMALL, color: C.green, align: "center" });
      text(ctx, "A", 8, 70, { font: SMALL, color: C.muted }); text(ctx, "D", 8, 92, { font: SMALL, color: C.muted }); text(ctx, "B", 96, 160, { font: SMALL, color: C.muted });
      ctx.restore();
    };
    const fade = 1 - s.lanes;
    if (fade > 0.01) {
      drawSlice(sx, sy + 40, 1.4, fade, "DSP48E1");
      if (s.one > 0) {
        ctx.globalAlpha = s.one * fade;
        text(ctx, "pixel  x = 0b0101_1101  (93)", 500, 120, { font: MONO });
        text(ctx, "weight w = 0b1110_0110  (−26)", 500, 150, { font: MONO });
        text(ctx, "product  = −2418   (16 bits)", 500, 190, { font: MONO, color: C.yellow });
        arrow(ctx, 495, 135, 260, 180, { color: C.yellow, alpha: s.one * fade });
        text(ctx, "125 MHz × 1 product = 0.125 GMAC/s", 500, 240, { font: MONO, color: C.muted });
        ctx.globalAlpha = 1;
      }
    }
    if (s.lanes > 0.01 && s.pipe < 0.99) {
      const a = s.lanes * (1 - s.pipe);
      ctx.globalAlpha = a;
      // 64-bit beats split into lanes
      const bx = 60, by = 50;
      box(ctx, bx, by, 640, 30, { fill: "#2a2a1a", stroke: C.yellow }); text(ctx, "image word: 8 bytes of A", bx + 650, by + 20, { font: MONO, color: C.yellow });
      box(ctx, bx, by + 40, 640, 30, { fill: "#1b2b3a", stroke: C.blue }); text(ctx, "weight beat: 8 bytes of Bᵀ", bx + 650, by + 60, { font: MONO, color: C.blue });
      for (let i = 0; i < 8; i++) {
        const lx = bx + i * 80;
        ctx.strokeStyle = C.line; ctx.beginPath(); ctx.moveTo(lx + 80, by); ctx.lineTo(lx + 80, by + 70); ctx.stroke();
        text(ctx, `byte ${i}`, lx + 40, by + 20, { font: SMALL, color: C.muted, align: "center" });
        const my = by + 120;
        arrow(ctx, lx + 34, by + 72, lx + 34, my - 4, { color: C.yellow, head: 6 });
        arrow(ctx, lx + 46, by + 72, lx + 46, my - 4, { color: C.blue, head: 6 });
        box(ctx, lx + 14, my, 52, 44, { fill: "#1c2b3a", stroke: C.purple, lw: 1.5 });
        text(ctx, "×", lx + 40, my + 30, { font: '600 22px Inter', color: C.purple, align: "center" });
        text(ctx, `pr[${i}]`, lx + 40, my + 62, { font: SMALL, color: C.faint, align: "center" });
      }
      if (s.tree > 0) {
        ctx.globalAlpha = a * s.tree;
        const ty = by + 220;
        for (let i = 0; i < 8; i++) arrow(ctx, bx + i * 80 + 40, by + 186, bx + (i < 4 ? 160 : 480), ty - 4, { color: C.muted, head: 5, width: 1.2 });
        box(ctx, bx + 120, ty, 80, 36, { fill: "#162418", stroke: C.green }); text(ctx, "sa = Σ4", bx + 160, ty + 23, { font: SMALL, color: C.green, align: "center" });
        box(ctx, bx + 440, ty, 80, 36, { fill: "#162418", stroke: C.green }); text(ctx, "sb = Σ4", bx + 480, ty + 23, { font: SMALL, color: C.green, align: "center" });
        arrow(ctx, bx + 160, ty + 38, bx + 310, ty + 76, { color: C.muted, head: 6 }); arrow(ctx, bx + 480, ty + 38, bx + 330, ty + 76, { color: C.muted, head: 6 });
        box(ctx, bx + 270, ty + 78, 100, 36, { fill: "#162418", stroke: C.green }); text(ctx, "dsum", bx + 320, ty + 101, { font: SMALL, color: C.green, align: "center" });
        arrow(ctx, bx + 320, ty + 116, bx + 320, ty + 150, { color: C.muted, head: 6 });
        box(ctx, bx + 250, ty + 152, 140, 40, { fill: "#162418", stroke: C.green, lw: 2 }); text(ctx, "acc += dsum", bx + 320, ty + 178, { font: MONO, color: C.green, align: "center" });
        text(ctx, "over 104 beats (K = 832)", bx + 400, ty + 178, { font: SMALL, color: C.faint });
      }
      ctx.globalAlpha = 1;
    }
    if (s.pipe > 0.01) {
      ctx.globalAlpha = s.pipe;
      const names = ["operands", "8 × multiply", "add 4 + 4", "add halves", "accumulate", "bias", "× 57505", "+ 2²⁶", "≫ 27, clamp"];
      const px = 40, py = 170, pw = 96, gap = 6;
      text(ctx, "nine pipeline stages, one register (▮) after each; clock 125 MHz", px, 110, { font: MONO, color: C.muted });
      for (let i = 0; i < 9; i++) {
        const x = px + i * (pw + gap);
        box(ctx, x, py, pw, 70, { fill: "#121c27", stroke: i < 5 ? C.purple : C.teal });
        text(ctx, String(i + 1), x + 8, py + 18, { font: SMALL, color: C.faint });
        text(ctx, names[i], x + pw / 2, py + 44, { font: SMALL, color: C.ink, align: "center" });
        ctx.fillStyle = C.yellow; ctx.fillRect(x + pw - 4, py + 6, 4, 58);
      }
      // Beats marching: one per clock, slowed to 2 clocks per second for the eye
      const clk = t * 2, k = Math.floor(clk), frac = ease(clk - k);
      const colors = [C.blue, C.yellow, C.green, C.red, C.purple, C.teal, C.orange];
      for (let b = 0; b < 12; b++) {
        const stage = (k - b) + frac;           // beat b entered at clock b
        if (stage < -0.5 || stage > 9.2) continue;
        const pos = clamp(stage, -0.5, 9.2);
        const x = px + pos * (pw + gap) + pw / 2 - (pw + gap);
        ctx.fillStyle = colors[(k - Math.floor(stage) + b) % colors.length];
        ctx.beginPath(); ctx.arc(x + (pw + gap), py + 100, 9, 0, 7); ctx.fill();
      }
      text(ctx, `clock ${k}`, px, py + 150, { font: '600 15px "JetBrains Mono", monospace' });
      text(ctx, "every clock: a new beat enters stage 1, every beat moves one stage right", px + 120, py + 150, { font: MONO, color: C.muted });
      text(ctx, "latency 9 clocks (72 ns); throughput 1 beat = 8 products per clock", px, py + 180, { font: MONO, color: C.ink });
      text(ctx, "stages 1–5 run every beat; 6–9 once per finished output (every 104 beats)", px, py + 206, { font: MONO, color: C.muted });
      ctx.globalAlpha = 1;
    }
  },
};

// ---------------------------------------------------------------------------
const reuse = {
  id: "s-reuse", kicker: "4.2", title: "Reuse: why 8 rows made it 7.5 times faster", w: 960, h: 560, ambient: true,
  init: () => ({ rows: 1, bars: 0, ai: 0 }),
  steps: [
    { say: `<p>Version 0.4.0 of the engine: weight beats stream out of DDR3 at one per clock, the most the card's 64-bit port delivers. Each beat meets <b>one</b> image's 8 bytes. 8 multiplies per clock.</p><p>Measured: <span class="n">0.87</span> GMAC/s. One Cortex-A55 core does <span class="n">1.55</span>. The "accelerator" was slower than the CPU.</p>` },
    { say: `<p>The multipliers were not the problem: 740 are available, 8 were used. The problem was data. Every weight was fetched once per image and used once. To do more work, we would need more bytes per clock, and the port has no more to give.</p>` },
    { to: { rows: 8 }, dur: 1800, say: `<p>Version 0.5.0: load <b>8 images</b> into block RAM first. Now each weight beat, fetched once, is offered to all 8 images in the same clock: 8 rows × 8 bytes = <b>64 multiplies per clock</b>, from exactly the same memory traffic.</p><span class="hw">A broadcast bus: one source, eight listeners. The memory sees no difference; only the work per byte went up.</span>` },
    { to: { bars: 1 }, say: `<p>Measured on the card: <span class="n">6.5</span> GMAC/s, 7.5 times 0.4.0 and 4.2 times one CPU core, 82 % of the 8 GMAC/s peak. MNIST: 55 032 images per second.</p>` },
    { to: { ai: 1 }, say: `<p>The quantity that changed is <b>arithmetic intensity</b>: work per byte fetched. 1 multiply per weight byte before, 8 after. When the memory port is the bottleneck, it is the only lever.</p><p>It is also why one image alone gains nothing (still 155 µs): there is nothing to share a weight with. And it is the design of every NPU: Hailo keeps all weights on chip; Ara and GPUs use large on-chip buffers to reuse each fetched byte as many times as possible. Accelerators are mostly memory and data movement, with multipliers attached.</p>` },
  ],
  draw(ctx, s, { t }) {
    const rows = s.rows, R = Math.round(rows);
    // DDR3
    box(ctx, 30, 160, 120, 200, { fill: "#1e1830", stroke: C.purple, lw: 2 });
    text(ctx, "DDR3", 90, 250, { font: '600 18px Inter', color: C.purple, align: "center" });
    text(ctx, "weights", 90, 274, { font: SMALL, color: C.muted, align: "center" });
    // Weight beats on the bus
    const busY = 260, x0 = 160, x1 = 320;
    ctx.strokeStyle = C.blue; ctx.lineWidth = 3; ctx.beginPath(); ctx.moveTo(x0, busY); ctx.lineTo(x1, busY); ctx.stroke();
    const ph = (t * 1.2) % 1;
    for (let b = 0; b < 4; b++) {
      const x = x0 + ((b + ph) / 4) * (x1 - x0);
      ctx.fillStyle = C.blue; ctx.fillRect(x - 10, busY - 9, 20, 18);
    }
    text(ctx, "1 beat (8 bytes) per clock", x0, busY - 24, { font: SMALL, color: C.blue });
    // Rows of image registers and multiplier groups
    const gy0 = 90, gh = 46;
    const shown = lerp(1, 8, ease(clamp((rows - 1) / 7, 0, 1)));
    for (let r = 0; r < 8; r++) {
      const a = clamp(shown - r, 0, 1);
      if (a <= 0) continue;
      ctx.globalAlpha = a;
      const y = gy0 + r * gh;
      ctx.strokeStyle = C.blue; ctx.lineWidth = 1.5; ctx.beginPath(); ctx.moveTo(x1, busY); ctx.lineTo(x1 + 40, y + 16); ctx.lineTo(x1 + 60, y + 16); ctx.stroke();
      box(ctx, x1 + 60, y, 90, 32, { fill: "#2a2a1a", stroke: C.yellow }); text(ctx, `image ${r}`, x1 + 105, y + 21, { font: SMALL, color: C.yellow, align: "center" });
      for (let m = 0; m < 8; m++) {
        const on = ((t * 4 + m * 0.13) % 1) < 0.5;
        box(ctx, x1 + 160 + m * 22, y + 4, 18, 24, { fill: on ? "#3a2f55" : "#1c2433", stroke: C.purple, r: 4, lw: 1 });
      }
      ctx.globalAlpha = 1;
    }
    const macs = Math.round(8 * shown);
    text(ctx, `${R === 8 ? 8 : 1} row${R === 8 ? "s" : ""} × 8 multipliers = ${macs} MACs per clock`, x1 + 60, 470, { font: '600 16px "JetBrains Mono", monospace', color: C.ink });
    text(ctx, `${(macs * 0.125).toFixed(2)} GMAC/s peak at 125 MHz`, x1 + 60, 496, { font: MONO, color: C.muted });
    if (s.bars > 0) {
      ctx.globalAlpha = s.bars;
      const bx = 690, by = 100, bw = 230;
      text(ctx, "measured, GMAC/s", bx, by - 20, { font: MONO, color: C.muted });
      const data = [["card 0.5.0", 6.5, C.green], ["one A55 core", 1.55, C.muted], ["card 0.4.0", 0.87, C.red]];
      data.forEach(([n, v, col], i) => {
        const y = by + i * 64;
        text(ctx, n, bx, y + 14, { font: MONO });
        ctx.fillStyle = col; ctx.fillRect(bx, y + 22, (v / 8) * bw, 18);
        text(ctx, v.toFixed(2), bx + (v / 8) * bw + 8, y + 37, { font: MONO, color: C.ink });
      });
      ctx.strokeStyle = C.faint; ctx.setLineDash([3, 3]); ctx.beginPath(); ctx.moveTo(bx + bw, by); ctx.lineTo(bx + bw, by + 190); ctx.stroke(); ctx.setLineDash([]);
      text(ctx, "peak 8", bx + bw, by + 206, { font: SMALL, color: C.faint, align: "center" });
      ctx.globalAlpha = 1;
    }
    if (s.ai > 0) {
      ctx.globalAlpha = s.ai;
      box(ctx, 690, 340, 240, 110, { fill: "#141d27", stroke: C.yellow });
      text(ctx, "MACs per weight byte", 706, 366, { font: MONO, color: C.muted });
      text(ctx, "0.4.0:  1", 706, 396, { font: '600 16px "JetBrains Mono", monospace', color: C.red });
      text(ctx, "0.5.0:  8", 706, 426, { font: '600 16px "JetBrains Mono", monospace', color: C.green });
      ctx.globalAlpha = 1;
    }
  },
};

export const hardwareScenes = [dsp, reuse];
