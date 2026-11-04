#!/usr/bin/env bash
# Runs a self-checking XSim testbench. Usage: hw/sim/run_xsim.sh <tb_name>
# Needs Vivado's xvlog/xelab/xsim on PATH. Exit status 0 only on RESULT: PASS.
set -euo pipefail
tb=${1:-tb_npu_regs}
repo=$(cd "$(dirname "$0")/../.." && pwd)
work="$repo/build/sim/$tb"
mkdir -p "$work" && cd "$work"
xvlog --nolog "$repo"/hw/rtl/npu_regs.v "$repo/hw/sim/$tb.v" > xvlog.out
xelab --nolog --debug off "$tb" -s "$tb" > xelab.out
xsim --nolog "$tb" -R | tee xsim.out | grep -E '^(ok|FAIL|RESULT)'
grep -q '^RESULT: PASS' xsim.out
