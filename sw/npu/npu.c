// npu.c: user-space runtime for the fpga-edge-npu card (see npu.h).

#define _GNU_SOURCE
#include "npu.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "../driver/fpga_npu.h"

// Registers (docs/register-map.md)
#define REG_ID        0x000
#define REG_VERSION   0x004
#define REG_CAPS      0x00C
#define REG_CQ_CTRL   0x080
#define REG_CQ_LOG2   0x084
#define REG_SQ_LO     0x088
#define REG_SQ_HI     0x08C
#define REG_CQB_LO    0x090
#define REG_CQB_HI    0x094
#define REG_SQ_TAIL   0x098
#define REG_CQ_HEAD   0x09C
#define REG_CQ_STATUS 0x0A0

#define NPU_ID_VALUE 0x4E505530u

// Commands are written to uncached arena memory, then the doorbell goes to
// the device: the writes must reach memory before the card can fetch them.
// Completions are read in the other order: phase bit first, then the rest.
#if defined(__aarch64__)
#define wmb_dev() __asm__ volatile("dsb st" ::: "memory")
#define rmb_dev() __asm__ volatile("dsb ld" ::: "memory")
#else
#define wmb_dev() __sync_synchronize()
#define rmb_dev() __sync_synchronize()
#endif

double npu_now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

uint32_t npu_reg(struct npu *n, uint32_t off) { return n->regs[off / 4]; }
void npu_reg_write(struct npu *n, uint32_t off, uint32_t v) { n->regs[off / 4] = v; }

void *npu_alloc(struct npu *n, size_t bytes, uint64_t *bus) {
  size_t off = (n->arena_used + 4095) & ~(size_t)4095;
  if (off + bytes > n->arena_size) return NULL;
  n->arena_used = off + bytes;
  if (bus) *bus = n->arena_bus + off;
  return n->arena + off;
}

uint32_t npu_card_alloc(struct npu *n, size_t bytes) {
  uint32_t off = (n->card_used + 4095) & ~4095u;
  if ((uint64_t)off + bytes > n->card_size) return UINT32_MAX;
  n->card_used = off + bytes;
  return off;
}

int npu_open(struct npu *n, const char *dev, unsigned entries_log2) {
  struct fpga_npu_info info;
  memset(n, 0, sizeof(*n));
  n->fd = open(dev ? dev : "/dev/fpga-npu", O_RDWR);
  if (n->fd < 0) { fprintf(stderr, "npu: open %s: %s (is fpga_npu.ko loaded?)\n", dev ? dev : "/dev/fpga-npu", strerror(errno)); return -1; }
  if (ioctl(n->fd, FPGA_NPU_IOC_INFO, &info)) { perror("npu: info"); return -1; }
  n->arena_size = info.arena_size;
  n->arena_bus = info.arena_bus;
  n->irq_seen = info.irq_count;
  n->arena = mmap(NULL, info.arena_size, PROT_READ | PROT_WRITE, MAP_SHARED, n->fd, FPGA_NPU_ARENA_OFFSET);
  void *r = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, n->fd, FPGA_NPU_BAR0_OFFSET);
  if (n->arena == MAP_FAILED || r == MAP_FAILED) { perror("npu: mmap"); return -1; }
  n->regs = r;
  if (npu_reg(n, REG_ID) != NPU_ID_VALUE || (npu_reg(n, REG_VERSION) & 0xffff00) < 0x000400) {
    fprintf(stderr, "npu: card ID 0x%08x, version 0x%08x: need an NPU0 card, 0.4.0 or later\n",
            npu_reg(n, REG_ID), npu_reg(n, REG_VERSION));
    return -1;
  }
  n->card_size = (npu_reg(n, REG_CAPS) >> 16) << 20;

  // Rings at the start of the arena: SQ (64-byte entries), then CQ (16-byte).
  n->entries = 1u << entries_log2;
  n->sq = npu_alloc(n, n->entries * 64, &n->sq_bus);
  n->cq = npu_alloc(n, n->entries * 16, &n->cq_bus);
  if (!n->sq || !n->cq) return -1;
  memset(n->sq, 0, n->entries * 64);
  memset(n->cq, 0, n->entries * 16);
  n->phase = 1;

  npu_reg_write(n, REG_CQ_CTRL, 0);                        // disable to change the settings
  npu_reg_write(n, REG_CQ_LOG2, entries_log2);
  npu_reg_write(n, REG_SQ_LO, (uint32_t)n->sq_bus);
  npu_reg_write(n, REG_SQ_HI, (uint32_t)(n->sq_bus >> 32));
  npu_reg_write(n, REG_CQB_LO, (uint32_t)n->cq_bus);
  npu_reg_write(n, REG_CQB_HI, (uint32_t)(n->cq_bus >> 32));
  wmb_dev();
  npu_reg_write(n, REG_CQ_CTRL, 3);                        // enable (rings reset), interrupts on
  if (npu_reg(n, REG_CQ_STATUS) & 8) {
    fprintf(stderr, "npu: card rejected the ring settings (CQ_STATUS 0x%x)\n", npu_reg(n, REG_CQ_STATUS));
    return -1;
  }
  return 0;
}

void npu_close(struct npu *n) {
  if (n->regs) npu_reg_write(n, REG_CQ_CTRL, 0);
  if (n->fd >= 0) close(n->fd);
}

static int submit(struct npu *n, const uint64_t w[4]) {
  if (n->in_flight >= n->entries - 1) return -1;
  volatile uint64_t *slot = (volatile uint64_t *)(n->sq + n->sq_tail * 64);
  for (int i = 0; i < 8; i++) slot[i] = i < 4 ? w[i] : 0;
  n->sq_tail = (n->sq_tail + 1) & (n->entries - 1);
  n->in_flight++;
  return (int)(w[0] >> 16 & 0xffff);
}

static uint64_t word0(struct npu *n, uint8_t op, uint8_t flags, uint32_t hi) {
  uint16_t cid = n->next_cid++;
  return (uint64_t)op | (uint64_t)flags << 8 | (uint64_t)cid << 16 | (uint64_t)hi << 32;
}

int npu_submit_nop(struct npu *n, uint8_t flags) {
  uint64_t w[4] = { word0(n, NPU_OP_NOP, flags, 0), 0, 0, 0 };
  return submit(n, w);
}

int npu_submit_copy(struct npu *n, uint8_t op, uint8_t flags, uint32_t len, uint64_t host_bus, uint32_t card) {
  uint64_t w[4] = { word0(n, op, flags, len), host_bus, card, 0 };
  return submit(n, w);
}

int npu_submit_gemm(struct npu *n, uint8_t flags, const struct npu_gemm *g) {
  uint64_t w[4] = {
    word0(n, NPU_OP_GEMM, flags, g->m),
    (uint64_t)g->a | (uint64_t)g->bt << 32,
    (uint64_t)g->c | (uint64_t)g->bias << 32,
    (uint64_t)g->k | (uint64_t)g->n << 16 | (uint64_t)(g->shift & 31) << 32 |
      (uint64_t)(g->relu ? 1 : 0) << 40 | (uint64_t)(g->out32 ? 1 : 0) << 41 | (uint64_t)g->mult << 48,
  };
  return submit(n, w);
}

void npu_ring(struct npu *n) {
  wmb_dev();
  npu_reg_write(n, REG_SQ_TAIL, n->sq_tail);
}

int npu_wait(struct npu *n, struct npu_cpl *cpl, int use_irq, double timeout_s) {
  volatile uint64_t *e = (volatile uint64_t *)(n->cq + n->cq_head * 16);
  double t0 = npu_now();
  for (;;) {
    uint64_t w0 = e[0];
    if (((w0 >> 40) & 1) == n->phase) {
      rmb_dev();
      uint64_t w1 = e[1];
      w0 = e[0];
      if (cpl) {
        cpl->cid = w0 & 0xffff; cpl->sq_head = w0 >> 16 & 0xffff;
        cpl->status = w0 >> 32 & 0xff; cpl->phase = w0 >> 40 & 1;
        cpl->t_fetch = (uint32_t)w1; cpl->t_done = (uint32_t)(w1 >> 32);
      }
      n->cq_head = (n->cq_head + 1) & (n->entries - 1);
      if (n->cq_head == 0) n->phase ^= 1;
      n->in_flight--;
      npu_reg_write(n, REG_CQ_HEAD, n->cq_head);           // release the slot
      return 0;
    }
    if (npu_now() - t0 > timeout_s) {
      fprintf(stderr, "npu: no completion after %.1f s (CQ_STATUS 0x%x)\n", timeout_s, npu_reg(n, REG_CQ_STATUS));
      return -1;
    }
    if (use_irq) {
      struct pollfd p = { .fd = n->fd, .events = POLLIN };
      if (poll(&p, 1, 10) > 0) { uint32_t c; if (read(n->fd, &c, 4) == 4) n->irq_seen = c; }
    }
  }
}

int npu_copy(struct npu *n, uint8_t op, uint32_t len, uint64_t host_bus, uint32_t card) {
  struct npu_cpl c;
  if (npu_submit_copy(n, op, 0, len, host_bus, card) < 0) return -1;
  npu_ring(n);
  if (npu_wait(n, &c, 0, 10.0)) return -1;
  return c.status;
}

int npu_gemm(struct npu *n, const struct npu_gemm *g, struct npu_cpl *cpl) {
  struct npu_cpl c;
  if (npu_submit_gemm(n, 0, g) < 0) return -1;
  npu_ring(n);
  if (npu_wait(n, &c, 0, 60.0)) return -1;
  if (cpl) *cpl = c;
  return c.status;
}

void npu_gemm_ref(const int8_t *a, const int8_t *bt, const int32_t *bias, void *c,
                  uint32_t m, uint32_t k, uint32_t n, uint8_t shift, uint8_t relu, uint8_t out32, uint16_t mult) {
  for (uint32_t i = 0; i < m; i++)
    for (uint32_t j = 0; j < n; j++) {
      int32_t acc = bias[j];
      const int8_t *x = a + (size_t)i * k, *w = bt + (size_t)j * k;
      for (uint32_t t = 0; t < k; t++) acc += (int32_t)x[t] * w[t];
      if (out32) { ((int32_t *)c)[(size_t)i * n + j] = acc; continue; }
      int64_t p = (int64_t)acc * mult;
      if (shift) p = (p + ((int64_t)1 << (shift - 1))) >> shift;   // arithmetic shift
      if (relu && p < 0) p = 0;
      if (p > 127) p = 127;
      if (p < -128) p = -128;
      ((int8_t *)c)[(size_t)i * n + j] = (int8_t)p;
    }
}
