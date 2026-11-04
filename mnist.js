// The card's MNIST network, in the browser, bit for bit.
//
// Same file the card runs (sw/mnist/README.md has the format) and the same
// arithmetic as the GEMM engine (hw/rtl/npu_mm.v, sw/npu/npu_ref.py):
//   acc = bias + sum(a * b)                      INT8 x INT8, INT32 accumulate
//   y   = clamp(relu((acc * mult + 2^(shift-1)) >> shift), -128, 127)
// acc * mult stays below 2^47, so JavaScript doubles hold it exactly and
// Math.floor of a power-of-two division is the arithmetic right shift.
// Checked against all 10 000 test predictions of the bit-exact model
// (site/check_mnist.mjs).

export async function loadModel(url) {
  const buf = await (await fetch(url)).arrayBuffer();
  return parseModel(buf);
}

export function parseModel(buf) {
  const magic = new TextDecoder().decode(new Uint8Array(buf, 0, 8));
  if (magic !== "NPUMLP01") throw new Error("not an NPUMLP01 model");
  const h = new DataView(buf, 8, 32);
  const u = (i) => h.getUint32(i * 4, true);
  const m = { k1: u(0), n1: u(1), k2: u(2), n2: u(3), classes: u(4), mult1: u(5), shift1: u(6) };
  let off = 40;
  m.w1t = new Int8Array(buf, off, m.n1 * m.k1); off += m.n1 * m.k1;
  m.b1 = new Int32Array(buf.slice(off, off + m.n1 * 4)); off += m.n1 * 4;
  m.w2t = new Int8Array(buf, off, m.n2 * m.k2); off += m.n2 * m.k2;
  m.b2 = new Int32Array(buf.slice(off, off + m.n2 * 4));
  return m;
}

// One row of the engine: out[n] for a single input row a (length k).
export function gemmRow(a, bt, bias, k, n, { mult = 1, shift = 0, relu = false, out32 = false } = {}) {
  const out = out32 ? new Int32Array(n) : new Int8Array(n);
  for (let j = 0; j < n; j++) {
    let acc = bias[j];
    const w = j * k;
    for (let t = 0; t < k; t++) acc += a[t] * bt[w + t];
    acc |= 0;                                   // INT32 accumulator
    if (out32) { out[j] = acc; continue; }
    let p = acc * mult;
    if (shift) p = Math.floor((p + 2 ** (shift - 1)) / 2 ** shift);
    if (relu && p < 0) p = 0;
    out[j] = Math.max(-128, Math.min(127, p));
  }
  return out;
}

// pixels: 784 values 0..255, row-major 28 x 28, white digit on black (as MNIST).
export function infer(m, pixels) {
  const x = new Int8Array(m.k1);
  for (let i = 0; i < 784; i++) x[i] = pixels[i] >> 1;
  const h = gemmRow(x, m.w1t, m.b1, m.k1, m.n1, { mult: m.mult1, shift: m.shift1, relu: true });
  const z = gemmRow(h, m.w2t, m.b2, m.k2, m.n2, { out32: true });
  const logits = Array.from(z.subarray(0, m.classes));
  let pred = 0;
  for (let c = 1; c < m.classes; c++) if (logits[c] > logits[pred]) pred = c;
  return { x, h, logits, pred, macs: m.k1 * m.n1 + m.k2 * m.n2 };
}
