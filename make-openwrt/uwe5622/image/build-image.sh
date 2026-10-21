#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#============================================================================================
# Assemble a flashable ImmortalWrt image for the Orange Pi 3B (rk3566 + UWE5622)
# inside the openwrt-image-builder container.
#
#   1. ImageBuilder builds the rootfs from prebuilt ipks (ImmortalWrt feed +
#      the EasyTier ipks fetched by fetch-easytier-ipks.sh);
#   2. remake packs it together with the ophub kernel, u-boot and the DT-patched
#      dtb (the board hook lives in
#      openwrt-files/different-files/orangepi-3b/rootfs/etc/openwrt-board-release.conf).
#
# Run it from the image builder container, with the repository checkout mounted
# at /work and a persistent build volume (kernel download cache) at /build:
#
#   docker run --rm --privileged \
#       -v "$PWD/..:/work" -v "$PWD/../out:/out" -v openwrt-imgbuild:/build \
#       openwrt-image-builder:1 bash /work/amlogic-s9xxx-openwrt/make-openwrt/uwe5622/image/build-image.sh
#
# Environment:
#   WORK        directory holding the repo checkout / easytier ipks (default /work)
#   REPO        path to this repository            (default ${WORK}/amlogic-s9xxx-openwrt)
#   OUT         output directory                  (default /out)
#   IB          ImageBuilder directory            (default /build/ib/immortalwrt-imagebuilder-24.10.2-armsr-armv8.Linux-x86_64)
#   IPK_DIR     Easytier ipks                       (default ${WORK}/easytier-luci/ipk)
#   KVER        ophub kernel release              (default 6.12.69)
#   ROOTFS_MB   rootfs partition size in MiB      (default 4096; the rest of the
#                                                   medium is turned into a DATA
#                                                   partition on first boot)
#   TAG         suffix of the produced image name (default v9)
#============================================================================================
set -uo pipefail

WORK=${WORK:-/work}
REPO=${REPO:-${WORK}/amlogic-s9xxx-openwrt}
OUT=${OUT:-/out}
IB=${IB:-/build/ib/immortalwrt-imagebuilder-24.10.2-armsr-armv8.Linux-x86_64}
IPK_DIR=${IPK_DIR:-${WORK}/easytier-luci/ipk}
KVER=${KVER:-6.12.69}
ROOTFS_MB=${ROOTFS_MB:-4096}
TAG=${TAG:-v9}

name="openwrt_immortalwrt_orangepi-3b_k${KVER}_wpad-passwall-wifi-${TAG}.img.gz"

for ipk in easytier-noweb_2.6.4_aarch64_generic.ipk luci-app-easytier_2.6.4_all.ipk; do
    [ -f "${IPK_DIR}/${ipk}" ] || {
        echo "FATAL: ${IPK_DIR}/${ipk} is missing."
        echo "       Run make-openwrt/uwe5622/image/fetch-easytier-ipks.sh first."
        exit 1
    }
done

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --allow-remove-essential --no-install-recommends \
    coreutils-from-gnu coreutils-from-uutils- zstd xsltproc make gcc g++ perl \
    wget rsync unzip gawk file >/dev/null 2>&1

echo "=== [1/3] rebuilding rootfs with ImageBuilder (argon + docker + passwall) ==="
# The ImageBuilder default rootfs is 300 MiB, too small for the Docker stack.
sed -i 's/^CONFIG_TARGET_ROOTFS_PARTSIZE=.*/CONFIG_TARGET_ROOTFS_PARTSIZE=2048/' "${IB}/.config"
rm -f "${IB}"/bin/targets/armsr/armv8/*rootfs.tar.gz
cd "${IB}" || exit 1
make image PROFILE=generic \
    PACKAGES="wpad-openssl wifi-scripts iwinfo iw luci-app-passwall luci-i18n-passwall-zh-cn -wpad-basic-mbedtls luci-theme-argon luci-app-argon-config luci-i18n-argon-config-zh-cn cgroupfs-mount docker dockerd docker-compose luci-app-dockerman parted sgdisk ${IPK_DIR}/easytier-noweb_2.6.4_aarch64_generic.ipk ${IPK_DIR}/luci-app-easytier_2.6.4_all.ipk" \
    FILES="" FORCE=1 >/tmp/ib.log 2>&1 || true
# The qcow2 image step fails without qemu-img, but the rootfs tarball is
# produced before it, so only check for that.
rootfs="$(ls -S "${IB}"/bin/targets/armsr/armv8/*rootfs.tar.gz 2>/dev/null | head -n1)"
[ -n "${rootfs}" ] || { echo "FATAL: no rootfs"; tail -40 /tmp/ib.log; exit 1; }
echo "rootfs: ${rootfs}"

echo "=== [2/3] remake ==="
real_losetup="$(command -v losetup)"
# The container has no udev: losetup -P creates the partition devices in the
# kernel but not in /dev, so mirror them from sysfs.
cat >/usr/local/bin/losetup <<SHIM
#!/bin/bash
real=${real_losetup}
out="\$("\$real" "\$@")"; rc=\$?
[ -n "\$out" ] && printf '%s\n' "\$out"
if [ \$rc -eq 0 ] && [[ " \$* " == *" -P "* || " \$* " == *"--partscan"* ]]; then
    dev="\${out%% *}"
    if [ -n "\$dev" ] && [ -b "\$dev" ]; then
        b="\$(basename "\$dev")"
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            found=0
            for i in 1 2 3 4 5 6 7 8; do
                s="/sys/class/block/\${b}p\${i}"
                [ -e "\$s/dev" ] || continue
                found=1
                d="/dev/\${b}p\${i}"
                [ -e "\$d" ] && continue
                read -r maj min < <(tr ':' ' ' < "\$s/dev")
                mknod "\$d" b "\$maj" "\$min" 2>/dev/null || true
            done
            [ "\$found" = "1" ] && break
            sleep 0.3
        done
    fi
fi
exit \$rc
SHIM
chmod +x /usr/local/bin/losetup
hash -r

build=/build/repo
mkdir -p "${build}"
git -C "${REPO}" -c safe.directory='*' archive --format=tar HEAD | tar -x -C "${build}"
chmod +x "${build}/remake"
rm -rf "${build}/openwrt-armsr"
mkdir -p "${build}/openwrt-armsr"
cp -v "${rootfs}" "${build}/openwrt-armsr/"
cd "${build}" && ./remake -b orangepi-3b -a false -k "${KVER}" -s "${ROOTFS_MB}"

echo "=== [3/3] collecting ==="
img="$(ls -t "${build}/openwrt/out"/*.img.gz 2>/dev/null | head -n1)"
[ -n "${img}" ] || { echo "FATAL: no image"; exit 1; }
mkdir -p "${OUT}"
cp -v "${img}" "${OUT}/${name}"
ls -lh "${OUT}/${name}"
sha256sum "${OUT}/${name}"
echo "next: make-openwrt/uwe5622/image/finalize-image.sh (injects the DATA partition scripts, sets the password, recompresses)"
