#!/usr/bin/env bash
# Runs a self-checking XSim testbench. Usage: hw/sim/run_xsim.sh <tb_name>
# Needs Vivado's xvlog/xelab/xsim on PATH. Exit status 0 only on RESULT: PASS.
set -euo pipefail
tb=${1:-tb_npu_regs}
repo=$(cd "$(dirname "$0")/../.." && pwd)
work="$repo/build/sim/$tb"
mkdir -p "$work" && cd "$work"
# Every module written for this project except the top level, which needs the
# generated AMD IP.
rtl=$(ls "$repo"/hw/rtl/*.v | grep -v '/npu_top\.v$')
# Shared simulation models (hw/sim/*_model.v) are compiled with every testbench.
# shellcheck disable=SC2086
models=$(ls "$repo"/hw/sim/*_model.v 2>/dev/null || true)
xvlog --nolog $rtl $models "$repo/hw/sim/$tb.v" > xvlog.out
xelab --nolog --debug off "$tb" -s "$tb" > xelab.out
xsim --nolog "$tb" -R | tee xsim.out | grep -E '^(ok|FAIL|RESULT)'
grep -q '^RESULT: PASS' xsim.out
