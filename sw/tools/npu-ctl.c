// npu-ctl: bring-up tool for the fpga-edge-npu PCIe card.
//
//   npu-ctl info                    identity, version, build, link status
//   npu-ctl read  <offset>          read a BAR0 register
//   npu-ctl write <offset> <value>  write a BAR0 register
//   npu-ctl led   <0..3>            set the two software LEDs
//   npu-ctl regtest [count]         scratch-register pattern test
//   npu-ctl latency [count]         BAR0 read round-trip time
//   npu-ctl dmatest [bytes] [loops] [card offset]
//                                   DMA loopback through card memory
//   npu-ctl memtest [chunk bytes]   write all of card memory, then read it all
//                                   back and check it (address-dependent data)
//   npu-ctl bwtest [bytes] [bursts] card-side DDR3 bandwidth (mem_bw engine):
//                                   write then read-and-check, bursts in flight 1..16
//
// BAR0 is reached through the Xilinx XDMA driver's /dev/xdma0_user when it is
// loaded, otherwise through sysfs (resource0 of the first 10ee:7021 device,
// no driver needed). dmatest needs the XDMA driver (/dev/xdma0_h2c_0 and
// /dev/xdma0_c2h_0). Override paths with NPU_BAR0, NPU_H2C, NPU_C2H.
//
// Build natively or cross-compile: aarch64-linux-gnu-gcc -O2 -o npu-ctl npu-ctl.c

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define NPU_VENDOR 0x10ee
#define NPU_DEVICE 0x7021
#define BAR0_SIZE  0x1000

#define REG_ID       0x000
#define REG_VERSION  0x004
#define REG_BUILD    0x008
#define REG_CAPS     0x00C
#define REG_SCRATCH  0x010
#define REG_CONTROL  0x014
#define REG_STATUS   0x018
#define REG_CYCLE_LO 0x020
#define REG_CYCLE_HI 0x024
#define REG_DMA_WR   0x030
#define REG_DMA_RD   0x034
#define REG_DMA_ERR  0x038
#define REG_BW_CTRL  0x040
#define REG_BW_ADDR  0x044
#define REG_BW_LEN   0x048
#define REG_BW_RUNS  0x04C
#define REG_BW_CYC   0x050
#define REG_BW_MISM  0x054
#define REG_BW_ERR   0x058
#define REG_BW_CLK   0x05C
#define DDR3_PEAK_MBS 6400.0 /* 800 MT/s x 8 bytes */

#define NPU_ID_VALUE  0x4E505530u /* "NPU0" */
#define CARD_CLOCK_HZ 125000000.0

static volatile uint32_t *bar0;

static uint32_t rd(uint32_t off) { return bar0[off / 4]; }
static void wr(uint32_t off, uint32_t v) { bar0[off / 4] = v; }

static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static int read_hex_file(const char *path, unsigned *out) {
  FILE *f = fopen(path, "r");
  if (!f) return -1;
  int ok = fscanf(f, "%x", out) == 1;
  fclose(f);
  return ok ? 0 : -1;
}

// First 10ee:7021 device in sysfs; fills path with its resource0.
static int find_sysfs_bar0(char *path, size_t len) {
  DIR *d = opendir("/sys/bus/pci/devices");
  if (!d) return -1;
  struct dirent *e;
  int found = -1;
  while ((e = readdir(d))) {
    if (e->d_name[0] == '.') continue;
    char p[512];
    unsigned v, dev;
    snprintf(p, sizeof p, "/sys/bus/pci/devices/%s/vendor", e->d_name);
    if (read_hex_file(p, &v)) continue;
    snprintf(p, sizeof p, "/sys/bus/pci/devices/%s/device", e->d_name);
    if (read_hex_file(p, &dev)) continue;
    if (v == NPU_VENDOR && dev == NPU_DEVICE) {
      // With no driver bound, memory decoding is off; on arm64 an access to
      // a disabled BAR can end in an SError. Enable the device first.
      snprintf(p, sizeof p, "/sys/bus/pci/devices/%s/enable", e->d_name);
      FILE *f = fopen(p, "w");
      if (!f || fputs("1", f) < 0) {
        fprintf(stderr, "npu-ctl: cannot enable %s (run as root): %s\n", e->d_name, strerror(errno));
        if (f) fclose(f);
        break;
      }
      fclose(f);
      snprintf(path, len, "/sys/bus/pci/devices/%s/resource0", e->d_name);
      found = 0;
      break;
    }
  }
  closedir(d);
  return found;
}

static int open_bar0(void) {
  char path[512];
  const char *env = getenv("NPU_BAR0");
  if (env) snprintf(path, sizeof path, "%s", env);
  else if (access("/dev/xdma0_user", R_OK | W_OK) == 0) snprintf(path, sizeof path, "/dev/xdma0_user");
  else if (find_sysfs_bar0(path, sizeof path)) {
    fprintf(stderr, "npu-ctl: no %04x:%04x device found (lspci -nn; check the link and PERST# timing)\n",
            NPU_VENDOR, NPU_DEVICE);
    return -1;
  }
  int fd = open(path, O_RDWR | O_SYNC);
  if (fd < 0) { fprintf(stderr, "npu-ctl: open %s: %s\n", path, strerror(errno)); return -1; }
  void *m = mmap(NULL, BAR0_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  close(fd);
  if (m == MAP_FAILED) { fprintf(stderr, "npu-ctl: mmap %s: %s\n", path, strerror(errno)); return -1; }
  bar0 = m;
  if (rd(REG_ID) != NPU_ID_VALUE)
    fprintf(stderr, "npu-ctl: warning: ID reads 0x%08x, expected 0x%08x (%s)\n", rd(REG_ID), NPU_ID_VALUE, path);
  return 0;
}

static uint64_t cycles(void) {
  uint32_t lo = rd(REG_CYCLE_LO); // latches HI
  return ((uint64_t)rd(REG_CYCLE_HI) << 32) | lo;
}

// Version 0.2 and later: DDR3 status bits, DMA counters, CAPS size in MiB.
static int has_ddr(void) { return (rd(REG_VERSION) & 0xffff00) >= 0x000200; }

static uint64_t card_mem_bytes(void) {
  uint64_t n = rd(REG_CAPS) >> 16;
  return has_ddr() ? n << 20 : n << 10; // 0.1.x reported KiB
}

static int cmd_info(void) {
  uint32_t ver = rd(REG_VERSION), caps = rd(REG_CAPS), st = rd(REG_STATUS);
  printf("id        0x%08x %s\n", rd(REG_ID), rd(REG_ID) == NPU_ID_VALUE ? "(NPU0)" : "(unexpected)");
  printf("version   %u.%u.%u\n", (ver >> 16) & 0xff, (ver >> 8) & 0xff, ver & 0xff);
  printf("build     %08x\n", rd(REG_BUILD));
  printf("caps      0x%08x (card memory %" PRIu64 " KiB%s, dma %s)\n", caps, card_mem_bytes() >> 10,
         (has_ddr() && (caps & 2)) ? " DDR3" : "", (caps & 1) ? "yes" : "no");
  printf("status    link %s", (st & 1) ? "up" : "down");
  if (has_ddr())
    printf(", ddr %s, ddr clock %s", (st & 2) ? "calibrated" : "NOT calibrated", (st & 4) ? "locked" : "NOT locked");
  printf("\n");
  if (has_ddr())
    printf("dma axi   %u writes, %u reads, %u error responses\n", rd(REG_DMA_WR), rd(REG_DMA_RD), rd(REG_DMA_ERR));
  if ((ver & 0xffff00) >= 0x000300)
    printf("mem_bw    %u runs, %s, clock %u kHz\n", rd(REG_BW_RUNS), (rd(REG_BW_CTRL) & 1) ? "busy" : "idle", rd(REG_BW_CLK));
  printf("uptime    %.3f s\n", cycles() / CARD_CLOCK_HZ);
  return 0;
}

// DMA tests are meaningless before the memory controller has calibrated.
static int require_memory(void) {
  if (has_ddr() && !(rd(REG_STATUS) & 2)) {
    fprintf(stderr, "npu-ctl: DDR3 not calibrated (STATUS 0x%08x); see npu-ctl info\n", rd(REG_STATUS));
    return -1;
  }
  return 0;
}

static int open_dma(int *h2c, int *c2h) {
  const char *h2c_path = getenv("NPU_H2C") ? getenv("NPU_H2C") : "/dev/xdma0_h2c_0";
  const char *c2h_path = getenv("NPU_C2H") ? getenv("NPU_C2H") : "/dev/xdma0_c2h_0";
  *h2c = open(h2c_path, O_WRONLY);
  *c2h = open(c2h_path, O_RDONLY);
  if (*h2c < 0 || *c2h < 0) {
    fprintf(stderr, "npu-ctl: open %s / %s: %s (is the xdma driver loaded?)\n", h2c_path, c2h_path, strerror(errno));
    return -1;
  }
  return 0;
}

static int cmd_regtest(long count) {
  static const uint32_t fixed[] = {0x00000000, 0xFFFFFFFF, 0xAAAAAAAA, 0x55555555, 0x12345678};
  uint32_t x = 0x1234567u;
  long errors = 0;
  for (long i = 0; i < count; i++) {
    uint32_t v;
    if (i < 5) v = fixed[i];
    else { x ^= x << 13; x ^= x >> 17; x ^= x << 5; v = x; } // xorshift32
    wr(REG_SCRATCH, v);
    uint32_t r = rd(REG_SCRATCH);
    if (r != v && errors++ < 10) fprintf(stderr, "mismatch %ld: wrote 0x%08x read 0x%08x\n", i, v, r);
  }
  printf("regtest   %ld writes, %ld errors: %s\n", count, errors, errors ? "FAIL" : "PASS");
  return errors ? 1 : 0;
}

static int cmd_latency(long count) {
  double t0 = now_s();
  for (long i = 0; i < count; i++) (void)rd(REG_SCRATCH);
  double t = now_s() - t0;
  printf("latency   %ld BAR0 reads, %.0f ns each (host clock)\n", count, t / count * 1e9);
  return 0;
}

static int cmd_dmatest(size_t bytes, int loops, uint64_t off) {
  uint64_t mem = card_mem_bytes();
  if (bytes == 0 || bytes % 8 || off % 8 || off + bytes > mem) {
    fprintf(stderr, "npu-ctl: bytes and offset must be multiples of 8, within %" PRIu64 " bytes of card memory\n", mem);
    return 1;
  }
  int h2c, c2h;
  if (require_memory() || open_dma(&h2c, &c2h)) return 1;
  uint8_t *tx, *rx;
  if (posix_memalign((void **)&tx, 4096, bytes) || posix_memalign((void **)&rx, 4096, bytes)) return 1;
  double t_h2c = 0, t_c2h = 0;
  long errors = 0;
  for (int l = 0; l < loops; l++) {
    for (size_t i = 0; i < bytes; i++) tx[i] = (uint8_t)(i * 7 + l * 13);
    memset(rx, 0, bytes);
    double t0 = now_s();
    if (pwrite(h2c, tx, bytes, off) != (ssize_t)bytes) { perror("h2c pwrite"); return 1; }
    double t1 = now_s();
    if (pread(c2h, rx, bytes, off) != (ssize_t)bytes) { perror("c2h pread"); return 1; }
    double t2 = now_s();
    t_h2c += t1 - t0;
    t_c2h += t2 - t1;
    if (memcmp(tx, rx, bytes)) {
      // Report the first bad loop in detail: where the data goes wrong says
      // more than a count (an address bit, a burst boundary, a byte lane).
      if (errors++ == 0) {
        size_t first = 0, bad = 0;
        while (tx[first] == rx[first]) first++;
        for (size_t i = 0; i < bytes; i++) bad += tx[i] != rx[i];
        fprintf(stderr, "dmatest   loop %d: first mismatch at 0x%zx (wrote 0x%02x, read 0x%02x), %zu of %zu bytes differ\n",
                l, first, tx[first], rx[first], bad, bytes);
      }
    }
  }
  double mb = (double)bytes * loops / 1e6;
  printf("dmatest   %zu B x %d: host->card %.1f MB/s, card->host %.1f MB/s, %ld mismatched loops: %s\n",
         bytes, loops, mb / t_h2c, mb / t_c2h, errors, errors ? "FAIL" : "PASS");
  return errors ? 1 : 0;
}

// Pattern word for card address a: every 64-bit word differs, and a stuck or
// shorted address line shows up as data from another address.
static uint64_t pattern(uint64_t a, uint64_t seed) {
  uint64_t z = a + seed * 0x9E3779B97F4A7C15ull;
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
  return z ^ (z >> 31);
}

static int cmd_memtest(size_t chunk) {
  uint64_t mem = card_mem_bytes();
  if (chunk == 0 || chunk % 8 || mem % chunk) {
    fprintf(stderr, "npu-ctl: chunk must be a multiple of 8 that divides %" PRIu64 "\n", mem);
    return 1;
  }
  int h2c, c2h;
  if (require_memory() || open_dma(&h2c, &c2h)) return 1;
  uint64_t *buf;
  if (posix_memalign((void **)&buf, 4096, chunk)) return 1;
  uint64_t seed = (uint64_t)time(NULL), bad = 0, first_bad = 0;
  uint32_t err0 = has_ddr() ? rd(REG_DMA_ERR) : 0;

  double t0 = now_s();
  for (uint64_t off = 0; off < mem; off += chunk) {
    for (size_t i = 0; i < chunk / 8; i++) buf[i] = pattern(off + i * 8, seed);
    if (pwrite(h2c, buf, chunk, off) != (ssize_t)chunk) { perror("h2c pwrite"); return 1; }
  }
  double t1 = now_s();
  for (uint64_t off = 0; off < mem; off += chunk) {
    if (pread(c2h, buf, chunk, off) != (ssize_t)chunk) { perror("c2h pread"); return 1; }
    for (size_t i = 0; i < chunk / 8; i++) {
      uint64_t want = pattern(off + i * 8, seed);
      if (buf[i] != want) {
        if (bad++ == 0) {
          first_bad = off + i * 8;
          fprintf(stderr, "memtest   first mismatch at card address 0x%" PRIx64 ": wrote 0x%016" PRIx64 ", read 0x%016" PRIx64 "\n",
                  first_bad, want, buf[i]);
        }
      }
    }
  }
  double t2 = now_s();
  uint32_t errs = has_ddr() ? rd(REG_DMA_ERR) - err0 : 0;
  printf("memtest   %" PRIu64 " MiB in %zu KiB chunks: write %.1f MB/s, read %.1f MB/s, %" PRIu64 " bad words, %u AXI errors: %s\n",
         mem >> 20, chunk >> 10, mem / 1e6 / (t1 - t0), mem / 1e6 / (t2 - t1), bad, errs,
         (bad || errs) ? "FAIL" : "PASS");
  return (bad || errs) ? 1 : 0;
}

// One mem_bw run; returns the memory-clock cycles, or -1 on timeout.
static int64_t bw_run(int read, uint32_t addr, uint32_t len, unsigned bursts, uint16_t seed) {
  uint32_t runs = rd(REG_BW_RUNS);
  wr(REG_BW_ADDR, addr);
  wr(REG_BW_LEN, len);
  wr(REG_BW_CTRL, ((uint32_t)seed << 16) | ((bursts & 0x1f) << 8) | (read ? 2u : 0u) | 1u);
  double t0 = now_s();
  while (rd(REG_BW_RUNS) == runs) {
    if (now_s() - t0 > 10.0) return -1;
  }
  return rd(REG_BW_CYC);
}

static int cmd_bwtest(uint64_t bytes, unsigned bursts) {
  if ((rd(REG_VERSION) & 0xffff00) < 0x000300) {
    fprintf(stderr, "npu-ctl: bwtest needs card version 0.3.0 or later\n");
    return 1;
  }
  uint64_t mem = card_mem_bytes();
  if (bytes == 0 || bytes % 4096 || bytes > mem || bytes > 0xFFFFF000u) {
    fprintf(stderr, "npu-ctl: bytes must be a multiple of 4096, at most %" PRIu64 "\n", mem);
    return 1;
  }
  if (bursts < 1 || bursts > 16) { fprintf(stderr, "npu-ctl: bursts in flight must be 1..16\n"); return 1; }
  if (require_memory()) return 1;
  double khz = rd(REG_BW_CLK);
  uint16_t seed = (uint16_t)time(NULL);
  int64_t wc = bw_run(0, 0, (uint32_t)bytes, bursts, seed);
  if (wc < 0) { fprintf(stderr, "npu-ctl: write run timed out\n"); return 1; }
  uint32_t werr = rd(REG_BW_ERR);
  int64_t rc = bw_run(1, 0, (uint32_t)bytes, bursts, seed);
  if (rc < 0) { fprintf(stderr, "npu-ctl: read run timed out\n"); return 1; }
  uint32_t rerr = rd(REG_BW_ERR), mism = rd(REG_BW_MISM);
  double wmbs = bytes / 1e6 / (wc / (khz * 1e3)), rmbs = bytes / 1e6 / (rc / (khz * 1e3));
  int ok = !werr && !rerr && !mism;
  printf("bwtest    %" PRIu64 " MiB, %u bursts of 4 KiB in flight: write %.0f MB/s (%.0f %%), read %.0f MB/s (%.0f %%) of %.0f MB/s peak;"
         " %u mismatched beats, %u AXI errors: %s\n",
         bytes >> 20, bursts, wmbs, 100 * wmbs / DDR3_PEAK_MBS, rmbs, 100 * rmbs / DDR3_PEAK_MBS, DDR3_PEAK_MBS,
         mism, werr + rerr, ok ? "PASS" : "FAIL");
  return ok ? 0 : 1;
}

static void usage(void) {
  fprintf(stderr,
          "usage: npu-ctl info | read <off> | write <off> <val> | led <0..3> |\n"
          "               regtest [count] | latency [count] | dmatest [bytes] [loops] [offset] |\n"
          "               memtest [chunk bytes] | bwtest [bytes] [bursts in flight]\n");
}

int main(int argc, char **argv) {
  if (argc < 2) { usage(); return 2; }
  const char *cmd = argv[1];
  if (open_bar0()) return 1;
  if (!strcmp(cmd, "info")) return cmd_info();
  if (!strcmp(cmd, "read") && argc == 3) {
    uint32_t off = strtoul(argv[2], NULL, 0);
    printf("0x%03x = 0x%08x\n", off, rd(off & ~3u));
    return 0;
  }
  if (!strcmp(cmd, "write") && argc == 4) {
    wr(strtoul(argv[2], NULL, 0) & ~3u, strtoul(argv[3], NULL, 0));
    return 0;
  }
  if (!strcmp(cmd, "led") && argc == 3) { wr(REG_CONTROL, strtoul(argv[2], NULL, 0) & 3); return 0; }
  if (!strcmp(cmd, "regtest")) return cmd_regtest(argc > 2 ? strtol(argv[2], NULL, 0) : 100000);
  if (!strcmp(cmd, "latency")) return cmd_latency(argc > 2 ? strtol(argv[2], NULL, 0) : 100000);
  if (!strcmp(cmd, "dmatest"))
    return cmd_dmatest(argc > 2 ? strtoul(argv[2], NULL, 0) : 65536, argc > 3 ? atoi(argv[3]) : 100,
                       argc > 4 ? strtoull(argv[4], NULL, 0) : 0);
  if (!strcmp(cmd, "memtest")) return cmd_memtest(argc > 2 ? strtoul(argv[2], NULL, 0) : 4u << 20);
  if (!strcmp(cmd, "bwtest"))
    return cmd_bwtest(argc > 2 ? strtoull(argv[2], NULL, 0) : card_mem_bytes(), argc > 3 ? (unsigned)atoi(argv[3]) : 16);
  usage();
  return 2;
}
