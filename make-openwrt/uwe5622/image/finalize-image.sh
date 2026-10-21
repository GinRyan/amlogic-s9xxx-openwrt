#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#============================================================================================
# Post-process the image produced by build-image.sh:
#
#   * verify the uwe5622 modules / dtb / wifi userspace / packages;
#   * install the files from image/extra-rootfs (Docker daemon config, the
#     first-boot DATA partition script and its init script, the EasyTier zh-cn
#     translation);
#   * set the root password;
#   * recompress and print the sha256 sums.
#
# Must run in the same privileged image builder container that has /out mounted.
#
# Environment:
#   OUT       output directory                  (default /out)
#   KVER      kernel release in the file name   (default 6.12.69)
#   TAG       image name suffix                 (default v9)
#   EXTRA     extra rootfs tree                 (default <this dir>/extra-rootfs)
#   ROOT_PASSWORD_HASH  /etc/shadow hash for root
#                       (default: "$1$V4UetPzk$CYXluq4wUazHjmCDBCqXF." = "password")
#============================================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT=${OUT:-/out}
KVER=${KVER:-6.12.69}
TAG=${TAG:-v9}
EXTRA=${EXTRA:-${HERE}/extra-rootfs}
ROOT_PASSWORD_HASH=${ROOT_PASSWORD_HASH:-'$1$V4UetPzk$CYXluq4wUazHjmCDBCqXF.'}

name="openwrt_immortalwrt_orangepi-3b_k${KVER}_wpad-passwall-wifi-${TAG}"
src="${OUT}/${name}.img.gz"
img="${OUT}/${name}.img"
[ -f "${src}" ] || { echo "FATAL: ${src} not found (run build-image.sh first)"; exit 1; }

echo "=== decompressing ${src} ==="
gunzip -c "${src}" >"${img}"

L="$(command -v losetup)"
loop="$("${L}" -P -f --show "${img}")"
b="$(basename "${loop}")"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    n=0
    for i in 1 2; do
        s="/sys/class/block/${b}p${i}"
        [ -e "${s}/dev" ] || continue
        n=$((n + 1))
        [ -e "/dev/${b}p${i}" ] && continue
        read -r maj min < <(tr ':' ' ' <"${s}/dev")
        mknod "/dev/${b}p${i}" b "${maj}" "${min}" 2>/dev/null || true
    done
    [ "${n}" -ge 2 ] && break
    sleep 0.3
done

mkdir -p /mnt/ib /mnt/ir
mount "${loop}p1" /mnt/ib
mount "${loop}p2" /mnt/ir
moddir="$(ls -d /mnt/ir/lib/modules/*/ | head -n1)"

echo "=== modules in the image ==="
ls -l "${moddir}extra/"
for f in "${moddir}extra"/*.ko; do
    echo "  $(basename "$f"): $(strings "$f" | grep '^vermagic=' | head -n1)"
done
echo "=== wifi userspace ==="
ls -l /mnt/ir/usr/sbin/wifi /mnt/ir/usr/sbin/iw /mnt/ir/usr/bin/iwinfo 2>/dev/null | sed 's|/mnt/ir||'
echo "=== dtb nodes ==="
dtc -I dtb -O dts /mnt/ib/dtb/rockchip/rk3566-orangepi-3b.dtb 2>/dev/null | grep -c 'uwe-bsp'

echo "=== installed packages ==="
for p in luci-theme-argon luci-app-argon-config luci-app-dockerman docker dockerd \
         docker-compose containerd cgroupfs-mount luci-app-passwall \
         easytier-noweb luci-app-easytier parted sgdisk; do
    if grep -q "^Package: ${p}$" /mnt/ir/usr/lib/opkg/status 2>/dev/null; then
        echo "  ${p}: installed"
    else
        echo "  ${p}: MISSING"
    fi
done

if [ -d "${EXTRA}" ]; then
    echo "=== installing extra-rootfs ==="
    (cd "${EXTRA}" && find . -type f -o -type l) | while read -r rel; do
        rel="${rel#./}"
        src_file="${EXTRA}/${rel}"
        dst="/mnt/ir/${rel}"
        mkdir -p "$(dirname "${dst}")"
        case "${rel}" in
            *setup-data-partition|*/init.d/*|*/bin/*) mode=0755 ;;
            *) mode=0644 ;;
        esac
        install -m "${mode}" "${src_file}" "${dst}"
    done
    # init script symlink (OpenWrt runs /etc/rc.d/S* at boot)
    [ -f /mnt/ir/etc/init.d/data-partition ] &&
        ln -sfn ../init.d/data-partition /mnt/ir/etc/rc.d/S90data-partition
    ls -l /mnt/ir/etc/rc.d/S90data-partition 2>/dev/null
fi

echo "=== setting the root password ==="
awk -F: -v OFS=: -v h="${ROOT_PASSWORD_HASH}" '$1=="root"{$2=h} {print}' \
    /mnt/ir/etc/shadow >/tmp/shadow.new
cat /tmp/shadow.new >/mnt/ir/etc/shadow
chmod 600 /mnt/ir/etc/shadow
awk -F: '$1=="root"{print "  hash set: " (($2!="")?"yes":"no")}' /mnt/ir/etc/shadow
df -h /mnt/ir | tail -1
umount /mnt/ir /mnt/ib
losetup -d "${loop}"

echo "=== recompressing + checksums ==="
gzip -9 -c "${img}" >"${OUT}/${name}.img.gz"
rm -f "${img}"
ls -lh "${OUT}/${name}.img.gz"
sha256sum "${OUT}/${name}.img.gz"
