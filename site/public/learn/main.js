// Loads the real data once, then mounts every lesson scene.
import { parseModel, infer } from "../mnist.js";
import { mountScene } from "./stage.js";
import { inferenceScenes } from "./scenes-infer.js";
import { trainingScenes } from "./scenes-train.js";
import { quantScenes } from "./scenes-quant.js";
import { hardwareScenes } from "./scenes-hw.js";

const get = (u, kind) => fetch(u).then((r) => { if (!r.ok) throw new Error(`${u}: ${r.status}`); return kind === "json" ? r.json() : r.arrayBuffer(); });

async function load() {
  const [model, samples, training, snaps, quant] = await Promise.all([
    get("../model/mnist.bin"), get("../model/samples.bin"),
    get("data/training.json", "json"), get("data/snapshots.bin"), get("data/quant.json", "json"),
  ]);
  const m = parseModel(model);
  const n = 40;
  const labels = new Uint8Array(samples, 0, n), pixels = new Uint8Array(samples, n, n * 784);
  const D = {
    model: m, training, quant,
    snaps: new Int8Array(snaps),
    images: Array.from({ length: n }, (_, i) => ({ label: labels[i], px: pixels.subarray(i * 784, (i + 1) * 784) })),
  };
  D.run = (i) => infer(m, D.images[i].px);
  // Layer 1 weights of neuron j as 784 signed values (the card's INT8)
  D.w1row = (j) => m.w1t.subarray(j * m.k1, j * m.k1 + 784);
  return D;
}

// Deep links: #s-neuron opens the page at a scene; ?solo=s-neuron&step=4 shows
// only that scene, at that step (for sharing one moment, and for screenshots).
load().then((D) => {
  const groups = { 1: inferenceScenes, 2: trainingScenes, 3: quantScenes, 4: hardwareScenes };
  const q = new URLSearchParams(location.search), solo = q.get("solo");
  if (solo) {
    document.body.classList.add("solo");
    const def = Object.values(groups).flat().find((d) => d.id === solo);
    const host = document.querySelector(".scenes");
    document.querySelectorAll(".scenes").forEach((h) => (h.innerHTML = ""));
    if (def) { const api = mountScene(host, def, D); const n = Number(q.get("step") || 1) - 1; if (n > 0) for (let i = 1; i <= n; i++) api.go(i, false); }
    host.closest(".part").scrollIntoView();
    return;
  }
  for (const host of document.querySelectorAll(".scenes")) {
    for (const def of groups[host.dataset.part]) mountScene(host, def, D);
  }
  if (location.hash) document.querySelector(location.hash)?.scrollIntoView();
}).catch((e) => {
  for (const host of document.querySelectorAll(".scenes")) host.innerHTML = `<p class="loading">Could not load the lesson data: ${e.message}</p>`;
});
