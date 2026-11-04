// npu-ctl: bring-up tool for the fpga-edge-npu PCIe card.
//
//   npu-ctl info                    identity, version, build, link status
//   npu-ctl read  <offset>          read a BAR0 register
//   npu-ctl write <offset> <value>  write a BAR0 register
//   npu-ctl led   <0..3>            set the two software LEDs
//   npu-ctl regtest [count]         scratch-register pattern test
//   npu-ctl latency [count]         BAR0 read round-trip time
//   npu-ctl dmatest [bytes] [loops] DMA loopback through card memory
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

static int cmd_info(void) {
  uint32_t ver = rd(REG_VERSION), caps = rd(REG_CAPS);
  printf("id        0x%08x %s\n", rd(REG_ID), rd(REG_ID) == NPU_ID_VALUE ? "(NPU0)" : "(unexpected)");
  printf("version   %u.%u.%u\n", (ver >> 16) & 0xff, (ver >> 8) & 0xff, ver & 0xff);
  printf("build     %08x\n", rd(REG_BUILD));
  printf("caps      0x%08x (card memory %u KiB, dma %s)\n", caps, caps >> 16, (caps & 1) ? "yes" : "no");
  printf("status    link %s\n", (rd(REG_STATUS) & 1) ? "up" : "down");
  printf("uptime    %.3f s\n", cycles() / CARD_CLOCK_HZ);
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

static int cmd_dmatest(size_t bytes, int loops) {
  const char *h2c_path = getenv("NPU_H2C") ? getenv("NPU_H2C") : "/dev/xdma0_h2c_0";
  const char *c2h_path = getenv("NPU_C2H") ? getenv("NPU_C2H") : "/dev/xdma0_c2h_0";
  uint32_t mem = (rd(REG_CAPS) >> 16) * 1024u;
  if (bytes == 0 || bytes > mem || bytes % 8) {
    fprintf(stderr, "npu-ctl: bytes must be a multiple of 8 and at most %u\n", mem);
    return 1;
  }
  int h2c = open(h2c_path, O_WRONLY), c2h = open(c2h_path, O_RDONLY);
  if (h2c < 0 || c2h < 0) {
    fprintf(stderr, "npu-ctl: open %s / %s: %s (is the xdma driver loaded?)\n", h2c_path, c2h_path, strerror(errno));
    return 1;
  }
  uint8_t *tx, *rx;
  if (posix_memalign((void **)&tx, 4096, bytes) || posix_memalign((void **)&rx, 4096, bytes)) return 1;
  double t_h2c = 0, t_c2h = 0;
  long errors = 0;
  for (int l = 0; l < loops; l++) {
    for (size_t i = 0; i < bytes; i++) tx[i] = (uint8_t)(i * 7 + l * 13);
    memset(rx, 0, bytes);
    double t0 = now_s();
    if (pwrite(h2c, tx, bytes, 0) != (ssize_t)bytes) { perror("h2c pwrite"); return 1; }
    double t1 = now_s();
    if (pread(c2h, rx, bytes, 0) != (ssize_t)bytes) { perror("c2h pread"); return 1; }
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

static void usage(void) {
  fprintf(stderr,
          "usage: npu-ctl info | read <off> | write <off> <val> | led <0..3> |\n"
          "               regtest [count] | latency [count] | dmatest [bytes] [loops]\n");
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
    return cmd_dmatest(argc > 2 ? strtoul(argv[2], NULL, 0) : 65536, argc > 3 ? atoi(argv[3]) : 100);
  usage();
  return 2;
}
