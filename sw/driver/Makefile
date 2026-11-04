# fpga-npu kernel module. Build against the board's kernel build tree, as
# docs/bringup.md describes for the NXP BSP:
#
#   make KDIR=<kernel build dir> ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- [LOCALVERSION=...]
#
# For the FRDM-i.MX95 setup of this project:
#   make -C sw/driver KDIR=~/fpga/imx95/kbuild KSRC=~/fpga/imx95/linux-imx \
#        ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION=-1.0.0

obj-m := fpga_npu.o

KDIR ?= /lib/modules/$(shell uname -r)/build
KSRC ?= $(KDIR)

all:
	$(MAKE) -C $(KSRC) O=$(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KSRC) O=$(KDIR) M=$(CURDIR) clean

.PHONY: all clean
