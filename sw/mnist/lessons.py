"""Records the data the site's lessons (site/public/learn/) animate.

    python sw/mnist/lessons.py [mnist dir] [out dir]

Re-runs train.py's training (same seed, so the same weights, checked against
model.bin) and records:

  training.json   the loss after every 5th step, float test accuracy after
                  each epoch, and the learning rate per epoch
  snapshots.bin   16 hidden neurons' 784 weights at 12 moments of training,
                  INT8 with one scale per snapshot (header in training.json)
  quant.json      what quantization does: a histogram of layer 1's float
                  weights with the INT8 step, the scales and the requant
                  constant, and for the first 40 test images the float and
                  INT8 hidden activations and logits, side by side

Defaults: build/mnist (from train.py) and site/public/learn/data.
"""
import json
import os
import struct
import sys

import numpy as np

HERE = os.path.dirname(__file__)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "npu"))
import train as T  # noqa: E402
from npu_ref import gemm  # noqa: E402

SNAP_STEPS = [0, 1, 3, 10, 30, 60, 100, 200, 469, 938, 2345, 4690]
N_SNAP = 16


def main():
    mdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "build", "mnist")
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "..", "..", "site", "public", "learn", "data")
    os.makedirs(out, exist_ok=True)
    xtr, ytr = T.idx(os.path.join(mdir, T.FILES[0])), T.idx(os.path.join(mdir, T.FILES[1]))
    xte, yte = T.idx(os.path.join(mdir, T.FILES[2])), T.idx(os.path.join(mdir, T.FILES[3]))
    qtr, qte = (xtr >> 1).astype(np.int8), (xte >> 1).astype(np.int8)
    xf, xtf = qtr.astype(np.float32) / 127, qte.astype(np.float32) / 127

    # Which 16 neurons to film: decided from the finished network (the ones
    # whose weights have the most structure), then recorded from step 0.
    w1_final = T.train(xf, ytr.astype(np.int64))[0]
    neurons = [int(i) for i in np.argsort(-w1_final.std(0))[:N_SNAP]]

    losses, accs, snaps = [], [], {}

    def hook(step, loss, params):
        if step % 5 == 0 or step == 1:
            losses.append([step, round(float(loss), 4)])
        if step in SNAP_STEPS:
            snaps[step] = params[0][:, neurons].T.copy()
        if step % 469 == 0:
            w1, b1, w2, b2 = params
            pred = (np.maximum(xtf @ w1 + b1, 0) @ w2 + b2).argmax(1)
            accs.append([step, round(float((pred == yte).mean() * 100), 2)])

    # Step 0: the random start, before any update (same seed as train.py)
    rng = np.random.default_rng(1)
    w1_init = rng.normal(0, np.sqrt(2 / 784), (784, T.N1)).astype(np.float32)
    snaps[0] = w1_init[:, neurons].T.copy()
    w1, b1, w2, b2 = T.train(xf, ytr.astype(np.int64), hook=hook)
    assert np.array_equal(w1, w1_final), "training is not deterministic"

    # Same quantization as train.py; check it reproduces model.bin
    s_x = 1 / 127
    s_w1 = np.abs(w1).max() / 127
    w1q = np.clip(np.round(w1 / s_w1), -127, 127).astype(np.int8)
    b1q = np.round(b1 / (s_x * s_w1)).astype(np.int32)
    h_cal = np.maximum(xf @ w1 + b1, 0)
    s_h = np.percentile(h_cal, 99.99) / 127
    m1 = s_x * s_w1 / s_h
    shift1 = min(31, int(np.floor(np.log2(65535 / m1))))
    mult1 = int(round(m1 * 2 ** shift1))
    s_w2 = np.abs(w2).max() / 127
    w2q = np.clip(np.round(w2 / s_w2), -127, 127).astype(np.int8)
    b2q = np.round(b2 / (s_h * s_w2)).astype(np.int32)
    with open(os.path.join(mdir, "model.bin"), "rb") as f:
        f.seek(40)
        card_w1t = np.frombuffer(f.read(T.N1 * T.K1), np.int8).reshape(T.N1, T.K1)
    assert np.array_equal(card_w1t[:, :784], w1q.T), "weights differ from model.bin"

    with open(os.path.join(out, "snapshots.bin"), "wb") as f:
        scales = []
        for st in SNAP_STEPS:
            w = snaps[st]
            sc = float(np.abs(w).max() / 127)
            scales.append(sc)
            f.write(np.clip(np.round(w / sc), -127, 127).astype(np.int8).tobytes())
    json.dump({
        "steps_per_epoch": 469, "batch": 128, "epochs": 10, "optimizer": "Adam, lr 1e-3 x 0.7 per epoch",
        "loss": losses, "test_accuracy": accs,
        "snapshots": {"steps": SNAP_STEPS, "neurons": neurons, "scales": scales, "layout": "int8 [snapshot][neuron][784]"},
    }, open(os.path.join(out, "training.json"), "w"), separators=(",", ":"))

    # Quantization: float network against the card's, first 40 test images
    n = 40
    xq = np.zeros((n, T.K1), np.int8); xq[:, :784] = qte[:n]
    w1t = np.zeros((T.N1, T.K1), np.int8); w1t[:, :784] = w1q.T
    w2t = np.zeros((T.N2, T.N1), np.int8); w2t[:T.CLASSES] = w2q.T
    b2p = np.zeros(T.N2, np.int32); b2p[:T.CLASSES] = b2q
    acc1 = gemm(xq, w1t, b1q, out32=True)
    hq = gemm(xq, w1t, b1q, mult=mult1, shift=shift1, relu=True)
    lq = gemm(hq, w2t, b2p, out32=True)[:, :T.CLASSES]
    hf = np.maximum(xtf[:n] @ w1 + b1, 0)
    lf = hf @ w2 + b2
    fpred_all = (np.maximum(xtf @ w1 + b1, 0) @ w2 + b2).argmax(1)
    xq_all = np.zeros((10000, T.K1), np.int8); xq_all[:, :784] = qte
    qpred_all = gemm(gemm(xq_all, w1t, b1q, mult=mult1, shift=shift1, relu=True), w2t, b2p, out32=True)[:, :T.CLASSES].argmax(1)
    hist, edges = np.histogram(w1, bins=120)
    json.dump({
        "s_x": s_x, "s_w1": float(s_w1), "s_h": float(s_h), "s_w2": float(s_w2),
        "M": float(m1), "mult": mult1, "shift": shift1,
        "w1_range": [float(w1.min()), float(w1.max())],
        "w1_hist": {"counts": hist.tolist(), "edges": [round(float(e), 6) for e in edges]},
        "w1_zoom": [round(float(v), 7) for v in w1.ravel()[(w1.ravel() > 0.086) & (w1.ravel() < 0.114)][:60]],
        "b1_float": [round(float(v), 5) for v in b1], "b1_int": b1q.tolist(),
        "images": {
            "count": n, "labels": yte[:n].tolist(),
            "acc32": acc1[:, :].tolist(),
            "h_int8": hq.tolist(), "h_float": np.round(hf, 4).tolist(),
            "logits_int": lq.tolist(), "logits_float": np.round(lf, 4).tolist(),
        },
        "test_set": {"float_correct": int((fpred_all == yte).sum()), "int8_correct": int((qpred_all == yte).sum()),
                     "predictions_differing": int((fpred_all != qpred_all).sum())},
    }, open(os.path.join(out, "quant.json"), "w"), separators=(",", ":"))
    print(f"neurons {neurons}\nloss points {len(losses)}, accuracy {accs[-1]}, "
          f"float/int8 predictions differing {int((fpred_all != qpred_all).sum())} of 10000")


if __name__ == "__main__":
    main()
