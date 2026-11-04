// npu.h: user-space runtime for the fpga-edge-npu card.
//
// Drives the command queue of docs/command-queue.md through the fpga-npu
// kernel driver (sw/driver): the rings and every data buffer live in the
// driver's DMA arena, which this library maps and carves up; BAR0 is mapped
// for the doorbells. Not thread-safe: one process, one queue.

#ifndef NPU_H
#define NPU_H

#include <stddef.h>
#include <stdint.h>

#define NPU_OP_NOP      0x00
#define NPU_OP_COPY_H2C 0x01
#define NPU_OP_COPY_C2H 0x02
#define NPU_OP_GEMM     0x10
#define NPU_FLAG_IRQ    0x01

#define NPU_ST_OK         0
#define NPU_ST_BAD_OPCODE 1
#define NPU_ST_BAD_LENGTH 2
#define NPU_ST_AXI_ERROR  3

#define NPU_CLOCK_HZ 125000000.0   // card cycle counter (completion timestamps)

struct npu_cpl {
  uint16_t cid, sq_head;
  uint8_t status, phase;
  uint32_t t_fetch, t_done;        // card cycles
};

struct npu {
  int fd;
  volatile uint32_t *regs;         // BAR0
  uint8_t *arena;                  // DMA arena, mapped
  uint64_t arena_bus;              // its bus address, for commands
  size_t arena_size, arena_used;
  uint32_t card_size, card_used;   // card memory bump allocator
  unsigned entries, sq_tail, cq_head, phase, in_flight;
  uint8_t *sq, *cq;
  uint64_t sq_bus, cq_bus;
  uint16_t next_cid;
  uint32_t irq_seen;
};

struct npu_gemm {
  uint32_t m;                      // rows of A and C
  uint32_t a, bt, c, bias;         // card addresses, 64-byte aligned
  uint16_t k, n;                   // K % 64 == 0 (<= 2048), N % 64 == 0 (<= 1024)
  uint8_t shift, relu, out32;
  uint16_t mult;
};

int  npu_open(struct npu *n, const char *dev, unsigned entries_log2);
void npu_close(struct npu *n);

uint32_t npu_reg(struct npu *n, uint32_t off);
void     npu_reg_write(struct npu *n, uint32_t off, uint32_t v);

// Arena memory (host side, visible to the card): 4 KiB aligned, never freed.
void *npu_alloc(struct npu *n, size_t bytes, uint64_t *bus);
// Card memory (DDR3): 4 KiB aligned, never freed.
uint32_t npu_card_alloc(struct npu *n, size_t bytes);

// Queue: put a command in the SQ (no doorbell), ring the doorbell, wait for
// the next completion. npu_submit returns the command ID, or -1 when the SQ is
// full (wait for completions first).
int  npu_submit_nop(struct npu *n, uint8_t flags);
int  npu_submit_copy(struct npu *n, uint8_t op, uint8_t flags, uint32_t len, uint64_t host_bus, uint32_t card);
int  npu_submit_gemm(struct npu *n, uint8_t flags, const struct npu_gemm *g);
void npu_ring(struct npu *n);
// use_irq: sleep on the MSI instead of polling the CQ. Returns 0, or -1 on timeout.
int  npu_wait(struct npu *n, struct npu_cpl *cpl, int use_irq, double timeout_s);

// Convenience: run one command synchronously; returns its status, or -1.
int  npu_copy(struct npu *n, uint8_t op, uint32_t len, uint64_t host_bus, uint32_t card);
int  npu_gemm(struct npu *n, const struct npu_gemm *g, struct npu_cpl *cpl);

double npu_now(void);

// The card's GEMM arithmetic on the CPU, bit for bit (sw/npu/npu_ref.py).
void npu_gemm_ref(const int8_t *a, const int8_t *bt, const int32_t *bias, void *c,
                  uint32_t m, uint32_t k, uint32_t n, uint8_t shift, uint8_t relu, uint8_t out32, uint16_t mult);

#endif
