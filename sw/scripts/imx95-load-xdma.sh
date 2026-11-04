#!/bin/sh
# Loads AMD's XDMA driver for the card on the FRDM-i.MX95, with the card's
# IOMMU group in pass-through mode.
#
#   sudo sw/scripts/imx95-load-xdma.sh [path/to/xdma.ko]
#
# Why pass-through: with the SMMU translating the card's DMA (the default,
# group type "DMA"), card-to-host transfers larger than one 4 KiB page return
# stale data in every page after the first; flushing the CPU cache lines
# afterwards shows the right data was in memory. In pass-through mode
# ("identity") every DMA test passes. See docs/bringup.md, "Problems found".
#
# Changing a group's type needs every device in it unbound, and the root
# port shares the card's group, so its pcieport services are detached and
# reattached around the change. The PCIe link stays up.
set -eu

ko=${1:-./xdma.ko}
dev=$(grep -l '^0x10ee$' /sys/bus/pci/devices/*/vendor | while read -r v; do
  d=${v%/vendor}; [ "$(cat "$d/device")" = 0x7021 ] && echo "$d"; done | head -n1)
[ -n "$dev" ] || { echo "no 10ee:7021 device; check lspci" >&2; exit 1; }
group=$(readlink -f "$dev/iommu_group")

if [ "$(cat "$group/type")" != identity ]; then
  lsmod | grep -q '^xdma ' && rmmod xdma
  for d in "$group"/devices/*; do
    [ -e "$d/driver" ] && echo "${d##*/}" > "$d/driver/unbind"
  done
  echo identity > "$group/type"
  for d in "$group"/devices/*; do
    [ "$(cat "$d/class")" = 0x060400 ] && echo "${d##*/}" > /sys/bus/pci/drivers/pcieport/bind
  done
fi
echo "IOMMU group $(basename "$group"): $(cat "$group/type")"

lsmod | grep -q '^xdma ' || insmod "$ko"
ls /dev/xdma0_user /dev/xdma0_h2c_0 /dev/xdma0_c2h_0
