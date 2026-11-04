# User-space runtime and tools for the card (needs the fpga_npu.ko driver).
# Native:  make          Cross:  make CC=aarch64-linux-gnu-gcc
CC     ?= cc
CFLAGS ?= -O2 -Wall -Wextra -std=c11

all: npu-test npu-mnist

npu-test: npu-test.c npu.c npu.h ../driver/fpga_npu.h
	$(CC) $(CFLAGS) -o $@ npu-test.c npu.c

npu-mnist: npu-mnist.c npu.c npu.h ../driver/fpga_npu.h
	$(CC) $(CFLAGS) -o $@ npu-mnist.c npu.c

clean:
	rm -f npu-test npu-mnist

.PHONY: all clean
