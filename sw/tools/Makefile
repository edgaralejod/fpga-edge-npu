# Native build:  make
# Cross build:   make CC=aarch64-linux-gnu-gcc   (or the i.MX Yocto SDK's $CC)
# cacheprobe is aarch64 only: make cacheprobe CC=aarch64-linux-gnu-gcc
CC     ?= cc
CFLAGS ?= -O2 -Wall -Wextra -std=c11

npu-ctl: npu-ctl.c
	$(CC) $(CFLAGS) -o $@ $<

cacheprobe: cacheprobe.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f npu-ctl cacheprobe

.PHONY: clean
