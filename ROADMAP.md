# Roadmap

An ordered backlog, not a schedule. Each phase builds on the one before it and is done only when its acceptance check passes on hardware, with results recorded in the docs. The [architecture](ARCHITECTURE.md) describes what exists today.

## Phases

| # | Phase | Scope | Done when |
| --- | --- | --- | --- |
| 1 | **PCIe link** (done 2026-11-04) | XDMA endpoint on the AC701, BAR0 registers, 64 KiB card memory, `npu-ctl`, SPI flash boot. | The FRDM-i.MX95 enumerates the card at Gen2 x1 after a cold boot; `regtest` passes 10⁶ writes; `dmatest` passes; BAR0 latency and DMA throughput in both directions are recorded in [bring-up](docs/bringup.md). |
| 2 | **Card memory** (done 2026-11-04) | Replace the BRAM with the AC701's DDR3 SODIMM through the memory controller (MIG). Report DDR bandwidth from the card's side with a counter-based test. | `dmatest` passes across the full DDR3 range; card-side read and write bandwidth are measured and documented. |
| 3 | **Command queue** (current; [design](docs/command-queue.md)) | XDMA replaced by AMD's AXI-PCIe bridge so the card can reach host memory itself. A ring of commands in host memory, a doorbell register, completion records and an MSI per completion, the shape used by NVMe and by accelerator runtimes. The project's own Linux driver, with its own PCI ID, replaces raw `npu-ctl` access. | A user-space program submits thousands of no-op commands, each completion is seen once and in order, and per-command latency is measured with the card's cycle counter. |
| 4 | **Compute engine** | INT8 matrix-multiply and convolution engine on the DSP48E1 slices, fed from card memory, driven by commands from phase 3. A bit-exact Python reference model of the engine. | Randomized layer tests match the reference model bit for bit in simulation and on hardware; achieved MAC/s against the theoretical peak is reported. |
| 5 | **Compiler** | Python tool: a quantized model (TFLite or ONNX, INT8) to a card program (weights, layout, command list), the role of Hailo's `.hef` file. Host runtime library to load and run it. | A small CNN (an MNIST or CIFAR-10 class network) runs end to end on the card and matches the reference model's outputs and accuracy. |
| 6 | **Comparison** | The same model on the i.MX95's Cortex-A55 cores, its eIQ Neutron NPU, and the FPGA card. Add an Ara-2 or Hailo-8 module if one is available. | A table of latency, throughput, power and accuracy, with the method and every number reproducible from scripts in the repository. |

## Design questions to settle along the way

| Question | When | How it will be decided |
| --- | --- | --- |
| Hailo-style (weights on chip, layer pipeline) or Ara-style (weights in DRAM, one programmable engine)? | Phase 4 | Start Ara-style: one engine and a compiler run any model that fits in DDR3. Try a pipelined on-chip variant for a model small enough for block RAM and compare. |
| Who sequences layers: host, a soft CPU on the card, or a hardware sequencer? | Phase 4 | Measure command overhead in phase 3 first. |
| Keep the Xilinx XDMA driver or write one? | Phase 3 | Own driver once commands, completions and interrupts need semantics XDMA's character devices do not offer. |

## Good first contributions

Documentation fixes, bring-up reports from other hosts (a Raspberry Pi 5 or an x86 PC with an M.2 or PCIe slot), and testbench coverage for `npu_regs` are all useful. Do not label a change easy because the patch is small; changes to the PCIe configuration or the register map need hardware evidence.
