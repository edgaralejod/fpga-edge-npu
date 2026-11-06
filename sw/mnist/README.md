# MNIST on the card

`train.py` trains a 784 → 128 (ReLU) → 10 multilayer perceptron on MNIST with NumPy, quantizes it for the card's GEMM engine, and checks the quantized network with the bit-exact model of the hardware (`sw/npu/npu_ref.py`). `sw/npu/npu-mnist` then runs it on the card. [Bring-up](../../docs/bringup.md) has the commands and the measured results.

```sh
python3 -m venv ~/venv-npu && ~/venv-npu/bin/pip install numpy
~/venv-npu/bin/python sw/mnist/train.py            # writes build/mnist/
```

`train.py` downloads the four MNIST files from Google's CVDF mirror (`storage.googleapis.com/cvdf-datasets/mnist/`).

`lessons.py` reruns the same training (same seed, so the same weights; it checks them against `model.bin`) and records what the site's lessons animate: the loss after every 5th step, test accuracy per epoch, 16 neurons' weights at 12 moments, and the float and INT8 networks' outputs side by side. It writes `site/public/learn/data/`:

```sh
~/venv-npu/bin/python sw/mnist/lessons.py          # about 15 s on 16 cores
```

## Quantization

| Quantity | Type | Scale |
| --- | --- | --- |
| Input `x_q = pixel >> 1` | INT8, 0 to 127 | 1/127 (the float network is trained on `x_q / 127`, so this is exact) |
| Layer 1 weights | INT8, symmetric, per layer | `max|W1| / 127` |
| Layer 1 bias | INT32 | input scale × weight scale (the accumulator's) |
| Hidden activations `h_q` | INT8 after ReLU | 99.99th percentile of the float activations on the training set / 127 |
| Layer 1 requantization | `mult` (16-bit), `shift` (5-bit) | `mult / 2^shift ≈ s_x · s_w1 / s_h` |
| Layer 2 weights, bias | INT8, INT32 | as layer 1 |
| Logits | INT32 | not rescaled: the class is the argmax |

## Files

`model.bin`, little-endian:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 8 | `NPUMLP01` |
| 8 | 4 × 8 | `K1` (832), `N1` (128), `K2` (128), `N2` (64), classes (10), layer 1 `mult`, layer 1 `shift`, reserved |
| 40 | N1 × K1 | Layer 1 weights, transposed (row n = output n), INT8, inputs 784 to 831 zero |
| | N1 × 4 | Layer 1 bias, INT32 |
| | N2 × K2 | Layer 2 weights, transposed, INT8, rows 10 to 63 zero |
| | N2 × 4 | Layer 2 bias, INT32, entries 10 to 63 zero |

K1 and N2 are padded because the engine needs K and N to be multiples of 64.

`expected.bin`: the 10 000 predicted classes of the bit-exact model, one byte each; `npu-mnist` requires the card to match them exactly.
