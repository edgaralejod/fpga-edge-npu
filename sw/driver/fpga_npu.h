/* SPDX-License-Identifier: GPL-2.0 OR Apache-2.0 */
/*
 * Interface between the fpga-npu kernel driver and the user-space runtime
 * (sw/npu/). Shared by both, so it carries both licenses.
 */
#ifndef FPGA_NPU_H
#define FPGA_NPU_H

#include <linux/types.h>
#ifdef __KERNEL__
#include <linux/ioctl.h>
#else
#include <sys/ioctl.h>
#endif

/* mmap offsets on /dev/fpga-npu */
#define FPGA_NPU_ARENA_OFFSET 0x0ul          /* DMA arena, coherent */
#define FPGA_NPU_BAR0_OFFSET  0x10000000ul   /* BAR0 registers */

struct fpga_npu_info {
	__u64 arena_bus;    /* bus address of the arena: what commands carry */
	__u32 arena_size;   /* bytes */
	__u32 bar0_size;    /* bytes */
	__u32 irq_count;    /* MSIs received so far */
	__u32 reserved;
};

#define FPGA_NPU_IOC_INFO _IOR('N', 1, struct fpga_npu_info)

/* The one register the kernel touches (docs/register-map.md) */
#define FPGA_NPU_REG_CQ_CTRL 0x080

#endif
