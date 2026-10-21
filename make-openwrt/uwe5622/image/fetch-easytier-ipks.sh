#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#============================================================================================
# Fetch the prebuilt EasyTier ipks used by build-image.sh.
#
# ImmortalWrt's own feeds do not carry EasyTier; the upstream project publishes
# opkg packages for every OpenWrt arch in EasyTier/luci-app-easytier.  We use the
# aarch64_generic build (the opkg flavour, i.e. the 22.03.7 asset, works with the
# 24.10 opkg too) and take the zh-cn translation file from the i18n package: that
# package ships the same /etc/uci-defaults file as luci-app-easytier, so installing
# both would make opkg abort with a file clash.
#
# Environment:
#   IPK_DIR   where the ipks are extracted (default: <this dir>/../../../easytier-luci/ipk)
#============================================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_GUESS="$(cd "${HERE}/../../../.." && pwd)"
IPK_DIR=${IPK_DIR:-${WORK_GUESS}/easytier-luci/ipk}
REL=v2.6.4
ZIP="EasyTier-${REL}-aarch64_generic-22.03.7.zip"
URL="https://github.com/EasyTier/luci-app-easytier/releases/download/${REL}/${ZIP}"

mkdir -p "${IPK_DIR}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "=== downloading ${ZIP} ==="
curl -fL --retry 3 -o "${tmp}/${ZIP}" "${URL}"
command -v unzip >/dev/null 2>&1 || { echo "FATAL: unzip is required"; exit 1; }
unzip -o -q "${tmp}/${ZIP}" -d "${tmp}/x"
cp -f "${tmp}/x"/*.ipk "${IPK_DIR}/"

echo "=== extracting the zh-cn translation ==="
lmo_src="$(ls "${tmp}/x"/*i18n*zh-cn*.ipk 2>/dev/null | head -n1 || true)"
if [ -n "${lmo_src}" ]; then
    mkdir -p "${tmp}/lmo"
    tar -xzf "${lmo_src}" -C "${tmp}/lmo" data.tar.gz 2>/dev/null
    tar -xzf "${tmp}/lmo/data.tar.gz" -C "${tmp}/lmo"
    dst="${HERE}/extra-rootfs/usr/lib/lua/luci/i18n"
    mkdir -p "${dst}"
    cp -f "${tmp}/lmo/usr/lib/lua/luci/i18n/easytier.zh-cn.lmo" "${dst}/" 2>/dev/null || true
fi

ls -l "${IPK_DIR}"/*.ipk
echo "done"
