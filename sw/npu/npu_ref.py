"""Bit-exact model of the card's INT8 matrix engine (hw/rtl/npu_mm.v).

    acc[m][n] = sum_k A[m][k] * Bt[n][k] + bias[n]          (INT8 x INT8 -> INT32)
    C[m][n]   = acc                                          when out32
              = clamp(relu?((acc * mult + 2**(shift-1)) >> shift), -128, 127)

The shift is arithmetic (rounds toward minus infinity after adding half), the
same as Verilog's >>> on a signed value. The hardware and this file must agree
bit for bit; hw/sim/tb_npu_cq.v and sw/npu/check_gemm.py compare them.
"""
import numpy as np


def gemm(a, bt, bias, mult=1, shift=0, relu=False, out32=False):
    """a: (M, K) int8, bt: (N, K) int8, bias: (N,) int32. Returns int8 or int32."""
    a = np.asarray(a, dtype=np.int64)
    bt = np.asarray(bt, dtype=np.int64)
    acc = a @ bt.T + np.asarray(bias, dtype=np.int64)[None, :]
    acc = ((acc + 2**31) % 2**32) - 2**31            # the engine accumulates in 32 bits
    if out32:
        return acc.astype(np.int32)
    p = acc * int(mult)
    if shift:
        p = (p + (1 << (shift - 1))) >> shift          # numpy >> on int64 is arithmetic
    if relu:
        p = np.maximum(p, 0)
    return np.clip(p, -128, 127).astype(np.int8)
