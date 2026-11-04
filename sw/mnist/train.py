"""Trains, quantizes and exports the MNIST network the card runs.

    python sw/mnist/train.py [outdir]        (needs numpy; about a minute)

Network: 784 -> 128 (ReLU) -> 10, a multilayer perceptron, trained in float
with plain NumPy on the 60 000 training images, then quantized for the card's
GEMM engine (hw/rtl/npu_mm.v):

  input   x_q = pixel >> 1, 0..127; the float network is trained on x_q / 127,
          so the input scale is exactly 1/127. Padded with zeros to K = 832.
  layer 1 GEMM INT8 x INT8 + INT32 bias, requantized to INT8 with ReLU:
          h_q = clamp(relu((acc * mult + 2^(shift-1)) >> shift))
  layer 2 GEMM with INT32 output (N padded from 10 to 64); the class is the
          argmax of the first 10 values.

Weights are quantized per layer, symmetric, to INT8; biases to INT32 at the
accumulator's scale; the hidden layer's scale comes from the 99.99th
percentile of its activations on the training set. Accuracy is evaluated with
npu_ref.gemm, the bit-exact model of the hardware, so the card must produce
the same predictions exactly.

Writes to outdir (default build/mnist):
  model.bin        the card's network (format in sw/mnist/README.md)
  expected.bin     10 000 predicted classes from the bit-exact model
  t10k-images-idx3-ubyte.gz, t10k-labels-idx1-ubyte.gz   the test set
  report.txt       float and quantized accuracy, scales
"""
import gzip
import os
import struct
import sys
import urllib.request

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "npu"))
from npu_ref import gemm  # noqa: E402

MIRROR = "https://storage.googleapis.com/cvdf-datasets/mnist/"
FILES = ["train-images-idx3-ubyte.gz", "train-labels-idx1-ubyte.gz",
         "t10k-images-idx3-ubyte.gz", "t10k-labels-idx1-ubyte.gz"]
K1, N1, N2, CLASSES = 832, 128, 64, 10


def fetch(outdir):
    for f in FILES:
        p = os.path.join(outdir, f)
        if not os.path.exists(p):
            urllib.request.urlretrieve(MIRROR + f, p)


def idx(path):
    with gzip.open(path) as fh:
        data = fh.read()
    magic, n = struct.unpack(">II", data[:8])
    if magic == 2051:
        rows, cols = struct.unpack(">II", data[8:16])
        return np.frombuffer(data, np.uint8, offset=16).reshape(n, rows * cols)
    return np.frombuffer(data, np.uint8, offset=8)


def train(x, y, epochs=10, seed=1):
    rng = np.random.default_rng(seed)
    w1 = rng.normal(0, np.sqrt(2 / 784), (784, N1)).astype(np.float32)
    b1 = np.zeros(N1, np.float32)
    w2 = rng.normal(0, np.sqrt(2 / N1), (N1, CLASSES)).astype(np.float32)
    b2 = np.zeros(CLASSES, np.float32)
    params = [w1, b1, w2, b2]
    m = [np.zeros_like(p) for p in params]
    v = [np.zeros_like(p) for p in params]
    lr, beta1, beta2, step = 1e-3, 0.9, 0.999, 0
    for epoch in range(epochs):
        order = rng.permutation(len(x))
        for i in range(0, len(x), 128):
            xb, yb = x[order[i:i + 128]], y[order[i:i + 128]]
            h = np.maximum(xb @ w1 + b1, 0)
            z = h @ w2 + b2
            z -= z.max(1, keepdims=True)
            p = np.exp(z)
            p /= p.sum(1, keepdims=True)
            p[np.arange(len(yb)), yb] -= 1
            dz = p / len(yb)
            dh = (dz @ w2.T) * (h > 0)
            grads = [xb.T @ dh, dh.sum(0), h.T @ dz, dz.sum(0)]
            step += 1
            for j, (prm, g) in enumerate(zip(params, grads)):
                m[j] = beta1 * m[j] + (1 - beta1) * g
                v[j] = beta2 * v[j] + (1 - beta2) * g * g
                prm -= lr * (m[j] / (1 - beta1 ** step)) / (np.sqrt(v[j] / (1 - beta2 ** step)) + 1e-8)
        lr *= 0.7
    return w1, b1, w2, b2


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "..", "build", "mnist")
    os.makedirs(outdir, exist_ok=True)
    fetch(outdir)
    xtr, ytr = idx(os.path.join(outdir, FILES[0])), idx(os.path.join(outdir, FILES[1]))
    xte, yte = idx(os.path.join(outdir, FILES[2])), idx(os.path.join(outdir, FILES[3]))

    # The card's input: pixel >> 1, so the float network sees exactly x_q / 127.
    qtr, qte = (xtr >> 1).astype(np.int8), (xte >> 1).astype(np.int8)
    w1, b1, w2, b2 = train(qtr.astype(np.float32) / 127, ytr.astype(np.int64))
    float_acc = ((np.maximum(qte / 127 @ w1 + b1, 0) @ w2 + b2).argmax(1) == yte).mean()

    # Quantize
    s_x = 1 / 127
    s_w1 = np.abs(w1).max() / 127
    w1q = np.clip(np.round(w1 / s_w1), -127, 127).astype(np.int8)
    b1q = np.round(b1 / (s_x * s_w1)).astype(np.int32)
    h_cal = np.maximum(qtr / 127 @ w1 + b1, 0)
    s_h = np.percentile(h_cal, 99.99) / 127
    m1 = s_x * s_w1 / s_h
    shift1 = min(31, int(np.floor(np.log2(65535 / m1))))
    mult1 = int(round(m1 * 2 ** shift1))
    s_w2 = np.abs(w2).max() / 127
    w2q = np.clip(np.round(w2 / s_w2), -127, 127).astype(np.int8)
    b2q = np.round(b2 / (s_h * s_w2)).astype(np.int32)

    # The card's layout: Bt = W transposed, rows padded to K, N padded to 64.
    w1t = np.zeros((N1, K1), np.int8); w1t[:, :784] = w1q.T
    w2t = np.zeros((N2, N1), np.int8); w2t[:CLASSES, :] = w2q.T
    b2p = np.zeros(N2, np.int32); b2p[:CLASSES] = b2q
    xq = np.zeros((len(qte), K1), np.int8); xq[:, :784] = qte

    h_q = gemm(xq, w1t, b1q, mult=mult1, shift=shift1, relu=True)
    logits = gemm(h_q, w2t, b2p, out32=True)
    pred = logits[:, :CLASSES].argmax(1).astype(np.uint8)
    quant_acc = (pred == yte).mean()

    with open(os.path.join(outdir, "model.bin"), "wb") as f:
        f.write(b"NPUMLP01")
        f.write(struct.pack("<8I", K1, N1, N1, N2, CLASSES, mult1, shift1, 0))
        f.write(w1t.tobytes()); f.write(b1q.tobytes())
        f.write(w2t.tobytes()); f.write(b2p.tobytes())
    pred.tofile(os.path.join(outdir, "expected.bin"))
    report = (f"float accuracy        {float_acc * 100:.2f} %\n"
              f"INT8 accuracy (card)  {quant_acc * 100:.2f} %  (bit-exact model, 10 000 test images)\n"
              f"scales                s_x 1/127, s_w1 {s_w1:.6g}, s_h {s_h:.6g}, s_w2 {s_w2:.6g}\n"
              f"layer 1 requant       mult {mult1}, shift {shift1} (M = {m1:.6g})\n")
    open(os.path.join(outdir, "report.txt"), "w").write(report)
    print(report, end="")


if __name__ == "__main__":
    main()
