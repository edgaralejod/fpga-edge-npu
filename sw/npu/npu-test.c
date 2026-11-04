// npu-test: acceptance tests for the card's command queue and GEMM engine.
//
//   npu-test info                 identity, capabilities, queue status
//   npu-test nop [count]          NOPs in full batches: every completion once, in order
//   npu-test latency [count]      one NOP at a time: doorbell-to-completion time,
//                                 polling and with the interrupt
//   npu-test copy [bytes] [loops] COPY_H2C then COPY_C2H through card memory, checked
//   npu-test gemm [m] [k] [n]     random GEMM on the card against the CPU, bit for bit
//   npu-test all                  the phase 3 acceptance run, then gemm
//
// Needs fpga_npu.ko (sw/driver). Times are host CLOCK_MONOTONIC unless
// labelled as card cycles (125 MHz, from the completion records).

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "npu.h"

static struct npu N;

static int cmp_d(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
}
static double pct(double *v, int n, double p) { return v[(int)((n - 1) * p)]; }

static uint32_t rng = 12345;
static uint32_t xr(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }

static int cmd_info(void) {
  printf("version   %u.%u.%u, build %08x\n", npu_reg(&N, 4) >> 16 & 255, npu_reg(&N, 4) >> 8 & 255, npu_reg(&N, 4) & 255, npu_reg(&N, 8));
  uint32_t caps = npu_reg(&N, 0xC);
  printf("caps      0x%08x: %u MiB card memory%s%s%s\n", caps, caps >> 16, caps & 2 ? ", DDR3" : "",
         caps & 4 ? ", command queue" : "", caps & 8 ? ", GEMM" : "");
  printf("status    0x%08x (link %s, ddr %s)\n", npu_reg(&N, 0x18), npu_reg(&N, 0x18) & 1 ? "up" : "down",
         npu_reg(&N, 0x18) & 2 ? "calibrated" : "NOT calibrated");
  printf("queue     %u entries, SQ at bus 0x%llx, CQ at bus 0x%llx, CQ_STATUS 0x%x, completed %u\n", N.entries,
         (unsigned long long)N.sq_bus, (unsigned long long)N.cq_bus, npu_reg(&N, 0xA0), npu_reg(&N, 0xA4));
  printf("arena     %zu MiB at bus 0x%llx\n", N.arena_size >> 20, (unsigned long long)N.arena_bus);
  return 0;
}

static int cmd_nop(long count) {
  long done = 0, bad = 0;
  uint16_t expect = N.next_cid;
  double t0 = npu_now();
  while (done < count) {
    long batch = 0;
    while (done + batch < count && npu_submit_nop(&N, 0) >= 0) batch++;
    npu_ring(&N);
    for (long i = 0; i < batch; i++) {
      struct npu_cpl c;
      if (npu_wait(&N, &c, 0, 5.0)) return 1;
      if (c.cid != expect || c.status != NPU_ST_OK) {
        if (bad++ < 5) fprintf(stderr, "nop: completion cid %u status %u, expected cid %u status 0\n", c.cid, c.status, expect);
      }
      expect++;
    }
    done += batch;
  }
  double t = npu_now() - t0;
  printf("nop       %ld commands in batches of %u: %ld out of order or failed; %.0f commands/s (%.2f us each): %s\n",
         count, N.entries - 1, bad, count / t, t / count * 1e6, bad ? "FAIL" : "PASS");
  return bad ? 1 : 0;
}

static int cmd_latency(int count) {
  double *rt = malloc(sizeof(double) * count), *card = malloc(sizeof(double) * count);
  for (int mode = 0; mode < 2; mode++) {
    for (int i = 0; i < count; i++) {
      struct npu_cpl c;
      double t0 = npu_now();
      npu_submit_nop(&N, mode ? NPU_FLAG_IRQ : 0);
      npu_ring(&N);
      if (npu_wait(&N, &c, mode, 5.0)) return 1;
      rt[i] = (npu_now() - t0) * 1e6;
      card[i] = (uint32_t)(c.t_done - c.t_fetch) / NPU_CLOCK_HZ * 1e6;
    }
    qsort(rt, count, sizeof(double), cmp_d);
    qsort(card, count, sizeof(double), cmp_d);
    printf("latency   NOP, %s, %d runs: round trip median %.2f us, p99 %.2f us, min %.2f us; card execution median %.3f us\n",
           mode ? "interrupt" : "polling", count, pct(rt, count, 0.5), pct(rt, count, 0.99), rt[0], pct(card, count, 0.5));
  }
  free(rt); free(card);
  return 0;
}

static int cmd_copy(uint32_t bytes, int loops) {
  uint64_t sbus, dbus;
  uint8_t *src = npu_alloc(&N, bytes, &sbus), *dst = npu_alloc(&N, bytes, &dbus);
  uint32_t card = npu_card_alloc(&N, bytes);
  if (!src || !dst || card == UINT32_MAX) { fprintf(stderr, "copy: %u bytes do not fit\n", bytes); return 1; }
  long bad = 0;
  double th = 0, tc = 0;
  for (int l = 0; l < loops; l++) {
    for (uint32_t i = 0; i < bytes; i++) src[i] = (uint8_t)xr();
    memset(dst, 0, bytes);
    struct npu_cpl c1, c2;
    npu_submit_copy(&N, NPU_OP_COPY_H2C, 0, bytes, sbus, card);
    npu_submit_copy(&N, NPU_OP_COPY_C2H, 0, bytes, dbus, card);
    npu_ring(&N);
    if (npu_wait(&N, &c1, 0, 10.0) || npu_wait(&N, &c2, 0, 10.0)) return 1;
    if (c1.status || c2.status) { fprintf(stderr, "copy: status %u, %u\n", c1.status, c2.status); return 1; }
    th += (uint32_t)(c1.t_done - c1.t_fetch) / NPU_CLOCK_HZ;
    tc += (uint32_t)(c2.t_done - c2.t_fetch) / NPU_CLOCK_HZ;
    if (memcmp(src, dst, bytes)) bad++;
  }
  double mb = (double)bytes * loops / 1e6;
  printf("copy      %u B x %d: host->card %.1f MB/s, card->host %.1f MB/s (card timestamps), %ld mismatched loops: %s\n",
         bytes, loops, mb / th, mb / tc, bad, bad ? "FAIL" : "PASS");
  return bad ? 1 : 0;
}

static int cmd_gemm(uint32_t m, uint32_t k, uint32_t n) {
  size_t sa = (size_t)m * k, sb = (size_t)n * k, sbias = (size_t)n * 4, sc8 = (size_t)m * n, sc32 = (size_t)m * n * 4;
  uint64_t ba, bb, bbias, bc8, bc32;
  int8_t *a = npu_alloc(&N, sa, &ba), *bt = npu_alloc(&N, sb, &bb);
  int32_t *bias = npu_alloc(&N, sbias, &bbias);
  int8_t *c8 = npu_alloc(&N, sc8, &bc8);
  int32_t *c32 = npu_alloc(&N, sc32, &bc32);
  int8_t *r8 = malloc(sc8);
  int32_t *r32 = malloc(sc32);
  uint32_t ka = npu_card_alloc(&N, sa), kb = npu_card_alloc(&N, sb), kbias = npu_card_alloc(&N, sbias);
  uint32_t kc8 = npu_card_alloc(&N, sc8), kc32 = npu_card_alloc(&N, sc32);
  if (!a || !bt || !bias || !c8 || !c32 || kc32 == UINT32_MAX) { fprintf(stderr, "gemm: does not fit\n"); return 1; }
  for (size_t i = 0; i < sa; i++) a[i] = (int8_t)xr();
  for (size_t i = 0; i < sb; i++) bt[i] = (int8_t)xr();
  for (uint32_t i = 0; i < n; i++) bias[i] = (int32_t)(xr() % 40001) - 20000;
  if (npu_copy(&N, NPU_OP_COPY_H2C, sa, ba, ka) || npu_copy(&N, NPU_OP_COPY_H2C, sb, bb, kb) ||
      npu_copy(&N, NPU_OP_COPY_H2C, sbias, bbias, kbias)) { fprintf(stderr, "gemm: upload failed\n"); return 1; }

  struct npu_gemm g8 = { .m = m, .a = ka, .bt = kb, .c = kc8, .bias = kbias, .k = k, .n = n, .shift = 12, .relu = 1, .mult = 300 };
  struct npu_gemm g32 = g8; g32.c = kc32; g32.out32 = 1; g32.relu = 0;
  struct npu_cpl c1, c2;
  if (npu_gemm(&N, &g8, &c1) || npu_gemm(&N, &g32, &c2)) { fprintf(stderr, "gemm: status %u, %u\n", c1.status, c2.status); return 1; }
  if (npu_copy(&N, NPU_OP_COPY_C2H, sc8, bc8, kc8) || npu_copy(&N, NPU_OP_COPY_C2H, sc32, bc32, kc32)) return 1;

  double t0 = npu_now();
  npu_gemm_ref(a, bt, bias, r8, m, k, n, 12, 1, 0, 300);
  double tcpu = npu_now() - t0;
  npu_gemm_ref(a, bt, bias, r32, m, k, n, 0, 0, 1, 1);
  long bad8 = 0, bad32 = 0;
  for (size_t i = 0; i < sc8; i++) bad8 += c8[i] != r8[i];
  for (size_t i = 0; i < (size_t)m * n; i++) bad32 += c32[i] != r32[i];
  double macs = (double)m * n * k, tc = (uint32_t)(c1.t_done - c1.t_fetch) / NPU_CLOCK_HZ;
  printf("gemm      %ux%u . %ux%u: %ld of %zu INT8 and %ld of %zu INT32 outputs differ from the CPU; card %.3f ms (%.0f MMAC/s), "
         "CPU reference %.3f ms (%.0f MMAC/s): %s\n", m, k, k, n, bad8, sc8, bad32, (size_t)m * n, tc * 1e3, macs / tc / 1e6,
         tcpu * 1e3, macs / tcpu / 1e6, bad8 || bad32 ? "FAIL" : "PASS");
  free(r8); free(r32);
  return bad8 || bad32;
}

int main(int argc, char **argv) {
  const char *cmd = argc > 1 ? argv[1] : "all";
  if (npu_open(&N, NULL, 6)) return 1;                     // 64-entry rings
  int rc;
  if (!strcmp(cmd, "info")) rc = cmd_info();
  else if (!strcmp(cmd, "nop")) rc = cmd_nop(argc > 2 ? atol(argv[2]) : 10000);
  else if (!strcmp(cmd, "latency")) rc = cmd_latency(argc > 2 ? atoi(argv[2]) : 1000);
  else if (!strcmp(cmd, "copy")) rc = cmd_copy(argc > 2 ? strtoul(argv[2], 0, 0) : 1 << 20, argc > 3 ? atoi(argv[3]) : 20);
  else if (!strcmp(cmd, "gemm")) rc = cmd_gemm(argc > 2 ? atoi(argv[2]) : 64, argc > 3 ? atoi(argv[3]) : 832, argc > 4 ? atoi(argv[4]) : 128);
  else if (!strcmp(cmd, "all")) {
    rc = cmd_info();
    rc |= cmd_nop(100000);
    rc |= cmd_latency(2000);
    rc |= cmd_copy(4096, 200);
    rc |= cmd_copy(1 << 20, 20);
    rc |= cmd_copy(8 << 20, 4);
    rc |= cmd_gemm(64, 832, 128);
    rc |= cmd_gemm(7, 2048, 1024);
    printf("all       %s\n", rc ? "FAIL" : "PASS");
  } else { fprintf(stderr, "usage: npu-test info | nop [n] | latency [n] | copy [bytes] [loops] | gemm [m k n] | all\n"); rc = 2; }
  npu_close(&N);
  return rc;
}
