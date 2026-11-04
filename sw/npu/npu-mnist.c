// npu-mnist: runs the MNIST test set on the card and on the CPU.
//
//   npu-mnist model.bin t10k-images-idx3-ubyte t10k-labels-idx1-ubyte [expected.bin]
//
// model.bin comes from sw/mnist/train.py (format in sw/mnist/README.md); the
// image and label files are the uncompressed MNIST test set. The network is
// 784 -> 128 (ReLU) -> 10 in INT8, two GEMM commands on the card:
//
//   upload the weights and all 10 000 images (COPY_H2C)
//   layer 1: GEMM M=10000 K=832 N=128, INT8 out with ReLU
//   layer 2: GEMM M=10000 K=128 N=64, INT32 out
//   download the logits (COPY_C2H), argmax of the first 10 on the CPU
//
// It checks the card's logits against the same INT8 arithmetic on the CPU
// (bit for bit), the predictions against train.py's bit-exact model
// (expected.bin) and the labels, then measures one image at a time: the
// host's round trip for upload, both layers and download.

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "npu.h"

static struct npu N;

static void *slurp(const char *path, size_t *len) {
  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); exit(1); }
  fseek(f, 0, SEEK_END); *len = ftell(f); fseek(f, 0, SEEK_SET);
  void *p = malloc(*len);
  if (fread(p, 1, *len, f) != *len) { perror(path); exit(1); }
  fclose(f);
  return p;
}
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static int argmax10(const int32_t *v) { int b = 0; for (int i = 1; i < 10; i++) if (v[i] > v[b]) b = i; return b; }
static int cmp_d(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }

int main(int argc, char **argv) {
  if (argc < 4) { fprintf(stderr, "usage: npu-mnist model.bin images labels [expected.bin]\n"); return 2; }
  size_t mlen, ilen, llen, elen = 0;
  uint8_t *model = slurp(argv[1], &mlen), *img = slurp(argv[2], &ilen), *lab = slurp(argv[3], &llen);
  uint8_t *expected = argc > 4 ? slurp(argv[4], &elen) : NULL;
  if (memcmp(model, "NPUMLP01", 8) || be32(img) != 2051 || be32(lab) != 2049) { fprintf(stderr, "npu-mnist: bad input files\n"); return 1; }
  uint32_t *h = (uint32_t *)(model + 8);
  uint32_t k1 = h[0], n1 = h[1], k2 = h[2], n2 = h[3], classes = h[4], mult1 = h[5], shift1 = h[6];
  const int8_t *w1t = (const int8_t *)(model + 40);
  const int32_t *b1 = (const int32_t *)(w1t + (size_t)n1 * k1);
  const int8_t *w2t = (const int8_t *)(b1 + n1);
  const int32_t *b2 = (const int32_t *)(w2t + (size_t)n2 * k2);
  uint32_t count = be32(img + 4), pixels = be32(img + 8) * be32(img + 12);
  printf("model     %u -> %u (ReLU) -> %u, padded to K %u and N %u; layer 1 requant mult %u shift %u\n",
         pixels, n1, classes, k1, n2, mult1, shift1);

  if (npu_open(&N, NULL, 6)) return 1;

  // Arena (host side) and card memory
  uint64_t bw1, bb1, bw2, bb2, bx, blog;
  int8_t *aw1 = npu_alloc(&N, (size_t)n1 * k1, &bw1);   int32_t *ab1 = npu_alloc(&N, n1 * 4, &bb1);
  int8_t *aw2 = npu_alloc(&N, (size_t)n2 * k2, &bw2);   int32_t *ab2 = npu_alloc(&N, n2 * 4, &bb2);
  int8_t *ax = npu_alloc(&N, (size_t)count * k1, &bx);
  int32_t *alog = npu_alloc(&N, (size_t)count * n2 * 4, &blog);
  uint32_t cw1 = npu_card_alloc(&N, (size_t)n1 * k1), cb1 = npu_card_alloc(&N, n1 * 4);
  uint32_t cw2 = npu_card_alloc(&N, (size_t)n2 * k2), cb2 = npu_card_alloc(&N, n2 * 4);
  uint32_t cx = npu_card_alloc(&N, (size_t)count * k1), ch = npu_card_alloc(&N, (size_t)count * n1);
  uint32_t clog = npu_card_alloc(&N, (size_t)count * n2 * 4);
  if (!ax || !alog || clog == UINT32_MAX) { fprintf(stderr, "npu-mnist: does not fit\n"); return 1; }
  memcpy(aw1, w1t, (size_t)n1 * k1); memcpy(ab1, b1, n1 * 4);
  memcpy(aw2, w2t, (size_t)n2 * k2); memcpy(ab2, b2, n2 * 4);

  // Input quantization, as in train.py: pixel >> 1, zero-padded to K.
  int8_t *xq = calloc((size_t)count, k1);
  for (uint32_t i = 0; i < count; i++)
    for (uint32_t p = 0; p < pixels; p++) xq[(size_t)i * k1 + p] = (int8_t)(img[16 + (size_t)i * pixels + p] >> 1);
  memcpy(ax, xq, (size_t)count * k1);

  // --- The whole test set on the card ---------------------------------------
  struct npu_gemm l1 = { .m = count, .a = cx, .bt = cw1, .c = ch, .bias = cb1, .k = k1, .n = n1,
                         .shift = shift1, .relu = 1, .mult = mult1 };
  struct npu_gemm l2 = { .m = count, .a = ch, .bt = cw2, .c = clog, .bias = cb2, .k = k2, .n = n2, .out32 = 1, .mult = 1 };
  struct npu_cpl c[7];
  double t0 = npu_now();
  npu_submit_copy(&N, NPU_OP_COPY_H2C, 0, n1 * k1, bw1, cw1);
  npu_submit_copy(&N, NPU_OP_COPY_H2C, 0, n1 * 4, bb1, cb1);
  npu_submit_copy(&N, NPU_OP_COPY_H2C, 0, n2 * k2, bw2, cw2);
  npu_submit_copy(&N, NPU_OP_COPY_H2C, 0, n2 * 4, bb2, cb2);
  npu_submit_copy(&N, NPU_OP_COPY_H2C, 0, count * k1, bx, cx);
  npu_submit_gemm(&N, 0, &l1);
  npu_submit_gemm(&N, 0, &l2);
  npu_ring(&N);
  for (int i = 0; i < 7; i++) if (npu_wait(&N, &c[i], 0, 120.0)) return 1;
  struct npu_cpl d;
  npu_submit_copy(&N, NPU_OP_COPY_C2H, NPU_FLAG_IRQ, count * n2 * 4, blog, clog);
  npu_ring(&N);
  if (npu_wait(&N, &d, 1, 60.0)) return 1;
  double t_card_total = npu_now() - t0;
  for (int i = 0; i < 7; i++) if (c[i].status) { fprintf(stderr, "npu-mnist: command %d status %u\n", i, c[i].status); return 1; }
  if (d.status) { fprintf(stderr, "npu-mnist: download status %u\n", d.status); return 1; }
  double sec = 1 / 125e6;
  double t_up = (uint32_t)(c[4].t_done - c[4].t_fetch) * sec, t_l1 = (uint32_t)(c[5].t_done - c[5].t_fetch) * sec;
  double t_l2 = (uint32_t)(c[6].t_done - c[6].t_fetch) * sec, t_down = (uint32_t)(d.t_done - d.t_fetch) * sec;

  // --- The same network on the CPU (one Cortex-A55 core, scalar C) -----------
  int8_t *hq = malloc((size_t)count * n1);
  int32_t *ref = malloc((size_t)count * n2 * 4);
  double t1 = npu_now();
  npu_gemm_ref(xq, w1t, b1, hq, count, k1, n1, shift1, 1, 0, mult1);
  npu_gemm_ref(hq, w2t, b2, ref, count, k2, n2, 0, 0, 1, 1);
  double t_cpu = npu_now() - t1;

  long mism = 0, correct = 0, cpu_correct = 0, exp_diff = 0;
  for (uint32_t i = 0; i < count; i++) {
    for (uint32_t j = 0; j < classes; j++) mism += alog[(size_t)i * n2 + j] != ref[(size_t)i * n2 + j];
    int p = argmax10(alog + (size_t)i * n2), q = argmax10(ref + (size_t)i * n2);
    correct += p == lab[8 + i];
    cpu_correct += q == lab[8 + i];
    if (expected && i < elen) exp_diff += p != expected[i];
  }
  double macs = (double)count * (k1 * n1 + k2 * n2);
  printf("card      %u images: accuracy %.2f %%; logits differing from the CPU %ld of %u; predictions differing from train.py %ld\n",
         count, 100.0 * correct / count, mism, count * classes, exp_diff);
  printf("card      layer 1 %.1f ms, layer 2 %.1f ms (%.0f images/s, %.0f MMAC/s of padded work); images up %.1f ms, logits down %.1f ms;"
         " end to end on the host %.1f ms\n", t_l1 * 1e3, t_l2 * 1e3, count / (t_l1 + t_l2), macs / (t_l1 + t_l2) / 1e6,
         t_up * 1e3, t_down * 1e3, t_card_total * 1e3);
  printf("cpu       one Cortex-A55 core, scalar C: %.1f ms (%.0f images/s, %.0f MMAC/s), accuracy %.2f %%\n",
         t_cpu * 1e3, count / t_cpu, macs / t_cpu / 1e6, 100.0 * cpu_correct / count);

  // --- One image at a time: the latency an application sees -------------------
  int runs = 200;
  double *lat = malloc(sizeof(double) * runs), *card_us = malloc(sizeof(double) * runs);
  struct npu_gemm s1 = l1, s2 = l2;
  s1.m = 1; s2.m = 1;
  long single_bad = 0;
  double tr_host[3] = {0}; struct npu_cpl tr_cpl[4]; int tr_label = 0, tr_pred = 0;
  for (int r = 0; r < runs; r++) {
    uint32_t i = r % count;
    double ts = npu_now();                                  // upload the image, as an application would
    memcpy(ax, xq + (size_t)i * k1, k1);
    struct npu_cpl e[4];
    npu_submit_copy(&N, NPU_OP_COPY_H2C, 0, k1, bx, cx);
    s1.a = cx;
    npu_submit_gemm(&N, 0, &s1);
    npu_submit_gemm(&N, 0, &s2);
    npu_submit_copy(&N, NPU_OP_COPY_C2H, 0, n2 * 4, blog, clog);
    double tring = npu_now();
    npu_ring(&N);
    for (int t = 0; t < 4; t++) if (npu_wait(&N, &e[t], 0, 5.0)) return 1;
    int p = argmax10(alog);
    lat[r] = (npu_now() - ts) * 1e6;
    if (r == runs - 1) {                                    // keep one run as a trace
      tr_host[0] = 0; tr_host[1] = (tring - ts) * 1e6; tr_host[2] = lat[r];
      memcpy(tr_cpl, e, sizeof(e)); tr_label = lab[8 + i]; tr_pred = p;
    }
    card_us[r] = (uint32_t)(e[3].t_done - e[0].t_fetch) * sec * 1e6;
    single_bad += p != argmax10(ref + (size_t)i * n2);
  }
  qsort(lat, runs, sizeof(double), cmp_d);
  qsort(card_us, runs, sizeof(double), cmp_d);
  printf("latency   one image (upload, 2 layers, download, argmax), %d runs: median %.1f us, p99 %.1f us on the host; "
         "%.1f us on the card; %ld predictions differing from the CPU\n", runs, lat[runs / 2], lat[runs * 99 / 100], card_us[runs / 2], single_bad);
  // One inference as a trace, for the website: host times in microseconds
  // from the start of the run; card times in microseconds from the first
  // command's fetch (the two clocks are not related).
  printf("TRACE {\"image\":%u,\"label\":%d,\"pred\":%d,\"host_us\":{\"prepare\":%.2f,\"doorbell\":%.2f,\"done\":%.2f},\"card_us\":[",
         (runs - 1) % count, tr_label, tr_pred, tr_host[0], tr_host[1], tr_host[2]);
  const char *names[4] = { "COPY_H2C image", "GEMM layer 1", "GEMM layer 2", "COPY_C2H logits" };
  for (int t = 0; t < 4; t++)
    printf("%s{\"cmd\":\"%s\",\"fetch\":%.3f,\"done\":%.3f}", t ? "," : "", names[t],
           (uint32_t)(tr_cpl[t].t_fetch - tr_cpl[0].t_fetch) * sec * 1e6, (uint32_t)(tr_cpl[t].t_done - tr_cpl[0].t_fetch) * sec * 1e6);
  printf("]}\n");
  int ok = mism == 0 && exp_diff == 0 && single_bad == 0;
  printf("mnist     %s\n", ok ? "PASS" : "FAIL");
  npu_close(&N);
  return ok ? 0 : 1;
}
