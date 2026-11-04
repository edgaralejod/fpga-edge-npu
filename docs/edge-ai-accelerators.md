# How discrete edge-AI accelerators work

This page explains the two accelerators this project learns from, the Hailo-8 and NXP's Ara-2 (from its 2025 purchase of Kinara), and how each idea maps onto the FPGA card. Facts about those products come from vendor and distributor documents listed at the end; anything this project has not measured itself is labelled.

## The shared shape

Both are **co-processors on PCIe**. The host (an i.MX95, a Raspberry Pi, an x86 box) runs Linux and the application; the accelerator only runs neural networks. The software stack has the same four parts in both:

| Part | Where it runs | What it does | Hailo-8 | Ara-2 |
| --- | --- | --- | --- | --- |
| Compiler | Developer PC | Turns a trained, quantized model (ONNX, TFLite) into a binary for the chip: layer placement, memory layout, schedule. | Dataflow Compiler, produces a `.hef` file | Kinara SDK compiler |
| Runtime library | Host | Loads the binary, manages input and output buffers, queues inference requests. | HailoRT (C/C++, Python, CLI) | Kinara runtime |
| Kernel driver | Host | Enumerates the PCIe device, maps its BARs, sets up DMA descriptor rings and MSI interrupts. | `hailo_pci` | Vendor PCIe driver |
| Device | Card | Firmware plus the compute fabric; fetches inputs by DMA, runs the network, writes results back, raises an interrupt. | Hailo-8 chip | Ara-2 chip and its DRAM |

An inference is the same conversation on the bus in both cases: the host writes input tensors into memory the card can reach, rings a doorbell register, the card's DMA engine pulls the data across PCIe, the network runs, the card pushes the outputs back and raises an MSI, and the driver wakes the waiting application.

## Two different machines inside

The chips differ most in where the network's weights live.

**Hailo-8: weights on chip, layers laid out in space.** Hailo describes its design as a structure-defined dataflow architecture built to run without external DRAM. The compiler maps the network's layers onto a pipeline of compute, memory and control blocks across the die, and the weights stay in on-chip memory. Frames stream through the pipeline, so throughput is high and latency is predictable, but the whole network (or each piece of it, when the compiler splits it into contexts) has to fit on chip. The M.2 modules use PCIe Gen3 x2 or x4.

**Ara-2: weights in DRAM, a programmable engine.** Ara-2 is aimed at transformer and generative models, which are far too big for on-chip memory. The M.2 module NXP lists for the FRDM-i.MX95 carries 16 GB of memory (ARA2-M2-16G-GT). The engine works through the model by streaming weights from that memory, so memory bandwidth and scheduling decide performance. NXP rates it at up to 40 TOPS, over PCIe Gen4 x4 or USB 3.2.

## Why this matters on the i.MX95

The i.MX95 already has its own NPU (NXP's eIQ Neutron). A discrete card earns its place when a model is too large or too slow for the built-in NPU; NXP's own guidance is to add Ara-2 to i.MX95 designs for larger language models. The FRDM-i.MX95's M.2 Key-M slot (PCIe 3.0 x1) is exactly where such a card goes, and it is where this project's FPGA card plugs in.

## How this project maps onto them

| Accelerator part | This project | Phase |
| --- | --- | --- |
| PCIe endpoint, BARs, MSI | AMD's `axi_pcie` bridge; BAR0 control registers; MSI from the command queue (XDMA in phases 1 and 2) | 1, 3 (done) |
| DMA engine and descriptor rings | `npu_cq`: the card fetches commands and moves data itself, 419 MB/s | 3 (done) |
| On-card memory | 1 GiB DDR3, 5.9 GB/s read measured inside the card | 2 (done) |
| Doorbells and command queue | Command ring in host memory, doorbell register, completions with a phase bit, MSI; 3.8 µs per command round trip | 3 (done) |
| Compute fabric | INT8 GEMM engine, 64 MACs per clock on 64 of the Artix-7's 740 DSP slices, 6.5 GMAC/s; MNIST at 55 000 images/s. Convolutions next | 4 (GEMM done) |
| Compiler and model binary | Python tool: quantized model to a card program | 5 |
| Runtime and benchmarks | Host library, then the same model on CPU, Neutron NPU and the card | 6 |

The Artix-7 can play both roles at small scale. A small CNN fits in its block RAM, so a Hailo-style build keeps weights on chip and pipelines layers. With the AC701's DDR3, an Ara-style build streams weights from memory through a single programmable engine. The roadmap builds the second first, because one programmable engine plus a compiler can run many models, and then compares the two.

## What an FPGA card will and will not show

It will show the full data path and every cost on it: PCIe latency, DMA setup time, memory bandwidth, and compute utilisation, each one measurable from a register or a counter. It will not match the products' throughput. A Gen2 x1 link carries about 500 MB/s each way before protocol overhead (estimated from the line rate), against the several GB/s of a Gen3 x4 or Gen4 x4 module. The Artix-7 runs its DSP slices at a few hundred MHz, far below an ASIC's TOPS. The value is in seeing and measuring every step, not in winning a benchmark.

## Sources

- Hailo-8 product brief: [hailo.ai](https://hailo.ai/wp-content/uploads/2023/10/hailo-8-product-brief-rev3.26.pdf); M.2 module brief: [hailo-8-m-2-2280](https://cdn.soselectronic.com/productdata/a9/5f/8475c971/hailo-8-m-2-2280-re-othailo2280b.pdf); toolchain overview: [RidgeRun Hailo AI Software Suite](https://developer.ridgerun.com/wiki/index.php/Hailo/Hailo-8/AI_Software_and_Tools/Hailo_AI_Software_Suite).
- Ara-2: [Future Electronics, NXP Ara-2 discrete NPUs](https://www.futureelectronics.com/en/resources/featured-products/nxp-ara2-discrete-neural-processing-units); acquisition and i.MX95 positioning: [EE Times Asia, why NXP acquired Kinara](https://www.eetasia.com/why-nxp-acquired-chip-startup-kinara/), [NXP edge LLM strategy](https://www.eetasia.com/nxp-highlights-edge-llm-strategy/).
- FRDM-i.MX95: [quick start guide](https://www.nxp.com.cn/docs/en/quick-reference-guide/FRDMIMX95QSG.pdf) (M.2 Key-M "for AI card and SSD", ARA2-M2-16G-GT accessory) and [block diagram](https://www.nxp.com/assets/block-diagram/en/FRDM-IMX95.pdf) (PCIe 3.0 x1 lane to M.2 Key-M).
