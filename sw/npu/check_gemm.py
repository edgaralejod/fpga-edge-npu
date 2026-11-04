"""Checks the GEMM outputs of hw/sim/tb_npu_cq.v against npu_ref.py.

The testbench dumps card memory ($writememh of 64-bit words) after its GEMM
commands; this script recomputes them with the Python model and reports every
mismatch. Usage: check_gemm.py build/sim/tb_npu_cq/card_mem_after_gemm.hex
"""
import sys
import numpy as np
from npu_ref import gemm

words = [int(l, 16) for l in open(sys.argv[1]) if l.strip() and not l.startswith("//")]
mem = np.frombuffer(b"".join(w.to_bytes(8, "little") for w in words), dtype=np.uint8)

def i8(addr, n): return mem[addr:addr + n].view(np.int8)
def i32(addr, n): return mem[addr:addr + 4 * n].view(np.int32)

M, K, N = 3, 192, 128
a = i8(0x4000, M * K).reshape(M, K)
bt = i8(0x8000, N * K).reshape(N, K)
bias = i32(0xF000, N)
bad = 0
for name, addr, kw in [("int8 relu", 0x10000, dict(mult=37, shift=9, relu=True)),
                       ("int8", 0x11000, dict(mult=1000, shift=4)),
                       ("int32", 0x12000, dict(out32=True))]:
    want = gemm(a, bt, bias, **kw)
    got = (i32(addr, M * N) if kw.get("out32") else i8(addr, M * N)).reshape(M, N)
    diff = np.argwhere(got != want)
    bad += len(diff)
    print(f"{name:10s} mismatches {len(diff)} of {M * N}" + (f", first at {tuple(diff[0])}: got {got[tuple(diff[0])]}, want {want[tuple(diff[0])]}" if len(diff) else ""))
sys.exit(1 if bad else 0)
