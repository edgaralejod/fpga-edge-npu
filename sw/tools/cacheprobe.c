// cacheprobe: checks whether card-to-host DMA data is in memory but hidden
// behind stale CPU cache lines. Needs the XDMA driver (/dev/xdma0_h2c_0 and
// /dev/xdma0_c2h_0); aarch64 only.
//
// Writes a 64 KiB pattern to card memory, reads it back into a buffer that
// was just cleared, and counts wrong bytes in pages 1-15: right after the
// read, after cleaning and invalidating the buffer's cache lines from user
// space (DC CIVAC), after 100 ms, and after a second flush. A count that drops
// to zero after the flush means the data had reached memory and the CPU was
// reading stale lines. See docs/bringup.md, "Problems found".
//
// Build: make cacheprobe CC=aarch64-linux-gnu-gcc

#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define N 65536

static size_t bad(const uint8_t *want, const uint8_t *got) {
  size_t c = 0;
  for (size_t i = 4096; i < N; i++) c += want[i] != got[i];
  return c;
}

// Arm64 Linux lets user space clean and invalidate by address (SCTLR_EL1.UCI).
static void flush(const void *p, size_t n) {
  for (uintptr_t a = (uintptr_t)p & ~(uintptr_t)63; a < (uintptr_t)p + n; a += 64)
    __asm__ volatile("dc civac, %0" ::"r"(a) : "memory");
  __asm__ volatile("dsb sy" ::: "memory");
}

int main(void) {
  int h2c = open("/dev/xdma0_h2c_0", O_WRONLY), c2h = open("/dev/xdma0_c2h_0", O_RDONLY);
  if (h2c < 0 || c2h < 0) { perror("cacheprobe: open /dev/xdma0_*"); return 1; }
  uint8_t *a, *b;
  if (posix_memalign((void **)&a, 4096, N) || posix_memalign((void **)&b, 4096, N)) return 1;
  int failed = 0;
  for (int run = 0; run < 3; run++) {
    for (size_t i = 0; i < N; i++) a[i] = (uint8_t)(i * 7 + run * 29 + 1);
    if (pwrite(h2c, a, N, 0) != N) { perror("cacheprobe: h2c"); return 1; }
    memset(b, 0, N);
    if (pread(c2h, b, N, 0) != N) { perror("cacheprobe: c2h"); return 1; }
    size_t e0 = bad(a, b);
    flush(b, N);
    size_t e1 = bad(a, b);
    usleep(100000);
    size_t e2 = bad(a, b);
    flush(b, N);
    size_t e3 = bad(a, b);
    printf("run %d: wrong bytes in pages 1-15: after read %zu, after flush %zu, +100 ms %zu, after 2nd flush %zu\n",
           run, e0, e1, e2, e3);
    failed |= e0 != 0;
  }
  printf("cacheprobe: %s\n", failed ? "FAIL (stale data after DMA)" : "PASS");
  return failed;
}
