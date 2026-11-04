# Contributing to fpga-edge-npu

Help make an accelerator card whose every layer can be read and measured. Useful contributions include bring-up reports from other hosts, testbench coverage, documentation, and well-tested pieces of the next roadmap phase. See the [roadmap](ROADMAP.md) for bounded starting points.

## Choose a useful change

For a bug, give the setup (boards, BSP, Vivado version), the command, what happened and what you expected. For a hardware change, state what it changes on the bus or in the register map and how you tested it. Discuss register-map, PCIe-configuration or architecture changes in an issue first, so contributors do not build incompatible approaches.

Fork the repository, create a branch, and open a pull request against `main`. Keep one coherent change per pull request.

## Development workflow

1. Read the [architecture](ARCHITECTURE.md) and [agent and repository guidance](AGENTS.md).
2. Make the change; keep the files listed together in AGENTS.md in step.
3. Run `make sim` and `make bitstream`; both must pass. Run the [bring-up](docs/bringup.md) checks your change affects if you have the hardware, and say so if you do not.
4. Lead the pull request with the problem and the resulting behavior, then the evidence: testbench output, timing summary, or hardware results with date and setup. State which checks ran and which did not.

Keep `git log` readable: a short subject plus a few sentences per commit.

## AI-assisted contributions

Welcome, and reviewed to the same standard. The contributor is responsible for understanding the change and the accuracy of its claims. Do not report hardware results that were not measured.

## Licensing

Contributions intentionally submitted for inclusion are provided under [Apache-2.0](LICENSE), unless explicitly stated otherwise.
