#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#============================================================================================
# Unpack the finalized image inside the container and assert that everything the
# pipeline is supposed to inject really made it in.  This is the same "quick"
# loop/mount/umount flow used by finalize-image.sh, so it also proves that the
# loop device handling works without udev.
#
# Environment:
#   OUT     output directory (default /out)
#   KVER    kernel release   (default 6.12.69)
#   TAG     image suffix     (default v9)
#============================================================================================
set -uo pipefail

OUT=${OUT:-/out}
KVER=${KVER:-6.12.69}
TAG=${TAG:-v9}
name="openwrt_immortalwrt_orangepi-3b_k${KVER}_wpad-passwall-wifi-${TAG}"
src="${OUT}/${name}.img.gz"
img="/tmp/verify-${name}.img"

[ -f "${src}" ] || { echo "FATAL: ${src} not found"; exit 1; }

cleanup() {
    umount /mnt/verify 2>/dev/null || true
    [ -n "${loop:-}" ] && losetup -d "${loop}" 2>/dev/null || true
    rm -f "${img}"
}
trap cleanup EXIT

echo "=== unpacking ${src} ==="
gunzip -c "${src}" >"${img}"

L="$(command -v losetup)"
loop="$("${L}" -P -f --show "${img}")"
b="$(basename "${loop}")"
for i in 1 2; do
    s="/sys/class/block/${b}p${i}"
    [ -e "${s}/dev" ] || continue
    [ -e "/dev/${b}p${i}" ] && continue
    read -r maj min < <(tr ':' ' ' <"${s}/dev")
    mknod "/dev/${b}p${i}" b "${maj}" "${min}" 2>/dev/null || true
done

mkdir -p /mnt/verify
mount "${loop}p2" /mnt/verify

fail=0
check() {
    if [ -e "$1" ]; then
        echo "  ok:      ${1#/mnt/verify}"
    else
        echo "  MISSING: ${1#/mnt/verify}"
        fail=1
    fi
}

echo "=== injected files ==="
check /mnt/verify/usr/sbin/setup-data-partition
check /mnt/verify/etc/init.d/data-partition
check /mnt/verify/etc/rc.d/S90data-partition
check /mnt/verify/etc/config/dockerd
check /mnt/verify/usr/bin/easytier-core
check /mnt/verify/usr/bin/easytier-cli
check /mnt/verify/usr/lib/lua/luci/controller/easytier.lua
check /mnt/verify/usr/lib/lua/luci/i18n/easytier.zh-cn.lmo

echo "=== uwe5622 modules ==="
moddir="$(ls -d /mnt/verify/lib/modules/*/ | head -n1)"
for ko in sprdwl_ng uwe5622_bsp_sdio sprdbt_tty; do
    check "${moddir}extra/${ko}.ko"
done
if [ -f "${moddir}extra/sprdwl_ng.ko" ]; then
    echo "  vermagic: $(strings "${moddir}extra/sprdwl_ng.ko" | grep '^vermagic=' | head -n1)"
fi

echo "=== rootfs ==="
df -h /mnt/verify | tail -1
echo "=== root password ==="
awk -F: '$1=="root"{print "  hash set: " (($2!="")?"yes":"no")}' /mnt/verify/etc/shadow

if [ "${fail}" -ne 0 ]; then
    echo "FATAL: image verification failed"
    exit 1
fi
echo "image verification passed"
