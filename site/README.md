# Site

A one-page explainer of the system, from the i.MX95's CPU through the IOMMU and the PCIe link into the card's memory: an interactive block diagram, animated data flows, charts of the measured latencies and bandwidths, and the debug captures.

Plain HTML, CSS and JavaScript in `public/`; no build step. Every number comes from `public/data.js`, which labels each one as measured, derived or spec, with the source; keep it in step with `docs/bringup.md`.

Preview locally (any static server, because the page uses JavaScript modules):

```sh
cd site/public && python3 -m http.server 8000     # http://localhost:8000
```

`?flow=c2h&step=8` opens a data-flow journey at a given step.

Deploy to Firebase Hosting:

```sh
cd site
npx firebase-tools login
npx firebase-tools deploy --only hosting --project <firebase-project-id>
```
