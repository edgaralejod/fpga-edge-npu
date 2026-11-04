#!/bin/sh
# Loads AMD's XDMA driver for the card on the FRDM-i.MX95.
#
#   sudo sw/scripts/imx95-load-xdma.sh [path/to/xdma.ko] [passthrough]
#
# Build xdma.ko with sw/patches/xdma-unmap-orig-nents.patch applied
# (docs/bringup.md). The unpatched driver unmaps card-to-host buffers with the
# entry count that dma_map_sg() returned instead of the one it was given; with
# the i.MX95's IOMMU translating, the pages of a buffer are merged into one
# entry, so the CPU caches are invalidated for the first 4 KiB page only and
# every later page reads back stale. See docs/bringup.md, "Problems found".
#
# "passthrough" puts the card's IOMMU group in identity mode first, which
# hides that bug (no merging), for use with an unpatched driver only: it
# removes the IOMMU's protection against the card.
#
# Changing a group's type needs every device in it unbound, and the root port
# shares the card's group, so its pcieport services are detached and
# reattached around the change. The PCIe link stays up.
set -eu

ko=${1:-./xdma.ko}
mode=${2:-}
dev=$(grep -l '^0x10ee$' /sys/bus/pci/devices/*/vendor | while read -r v; do
  d=${v%/vendor}; [ "$(cat "$d/device")" = 0x7021 ] && echo "$d"; done | head -n1)
[ -n "$dev" ] || { echo "no 10ee:7021 device; check lspci" >&2; exit 1; }
group=$(readlink -f "$dev/iommu_group")

if [ "$mode" = passthrough ] && [ "$(cat "$group/type")" != identity ]; then
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
