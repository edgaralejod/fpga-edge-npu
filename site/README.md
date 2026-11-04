# Site

A one-page explainer of the system, from the i.MX95's CPU through the IOMMU and the PCIe link into the card's memory and its GEMM engine:

- **Try it**: draw a digit and the browser runs the card's MNIST network with the card's integer arithmetic, layer by layer, next to the four commands the host submits to run it on the card.
- **One inference, timed**: one real inference on the card, drawn as logic-analyzer lanes from the timestamps in its completion records.
- An interactive block diagram, animated data flows, charts of the measured latencies and bandwidths, the bugs found on the bench, and the debug captures.

Plain HTML, CSS and JavaScript in `public/`; no build step. Every number comes from `public/data.js`, which labels each one as measured, derived or spec, with the source; keep it in step with `docs/bringup.md`.

| File | Contents |
| --- | --- |
| `public/index.html`, `style.css` | The page. |
| `public/app.js` | Block diagram, data flows, charts, bugs, comparison, roadmap. |
| `public/data.js` | Every measured number, and the `trace` line from `npu-mnist`. |
| `public/mnist.js` | The card's network in JavaScript: parses `model.bin`, runs the GEMM arithmetic bit for bit. |
| `public/demo.js` | The drawing pad, MNIST-style preprocessing, the layer view and the command words. |
| `public/trace.js` | The timing lanes. |
| `public/model/mnist.bin` | A copy of `build/mnist/model.bin` from `sw/mnist/train.py` (format in `sw/mnist/README.md`). |
| `public/model/samples.bin` | The first 40 MNIST test images: 40 label bytes, then 40 × 784 pixels. |
| `check_mnist.mjs` | Checks `mnist.js` against the bit-exact model on all 10 000 test images. |

After retraining, copy the model and check the browser network still matches:

```sh
cp build/mnist/model.bin site/public/model/mnist.bin
node site/check_mnist.mjs build/mnist     # 0 of 10000 predictions differ
```

After a new `npu-mnist` run, paste its `TRACE` line's JSON into `trace` in `data.js`.

Preview locally (any static server, because the page uses JavaScript modules):

```sh
cd site/public && python3 -m http.server 8000     # http://localhost:8000
```

`?flow=cmd&step=7` opens a data-flow journey at a given step (`reg`, `cmd`, `copy`, `gemm`, `bw`).

Published with GitHub Pages at <https://edgaralejod.github.io/fpga-edge-npu/>, served from the `gh-pages` branch, which holds only `site/public`. After committing site changes to `main`:

```sh
make site-publish      # splits site/public onto gh-pages and pushes it
```

`firebase.json` is kept for hosting the same files on Firebase instead (`npx firebase-tools deploy --only hosting --project <id>`).
