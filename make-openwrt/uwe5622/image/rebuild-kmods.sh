#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#============================================================================================
# Rebuild the uwe5622 kernel modules for the current kernel release in the
# pinned build container (equivalent to
#   docker run ... uwe5622-builder:26.04 bash make-openwrt/uwe5622/build-kmods.sh -v 6.12.69 -t rk35xx
# but with a persistent download cache).
#
# Environment:
#   KVER    kernel release  (default 6.12.69)
#   KTAGS   kernel tags     (default rk35xx)
#   CACHE   docker volume with the kernel downloads (default uwe5622-build-cache)
#============================================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
KVER=${KVER:-6.12.69}
KTAGS=${KTAGS:-rk35xx}
IMAGE=${UWE5622_DOCKER_IMAGE:-uwe5622-builder:26.04}
CACHE=${CACHE:-uwe5622-build-cache}

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'
mount_source="${REPO}"
if command -v cygpath >/dev/null 2>&1; then
    mount_source="$(cygpath -m "${REPO}")"
fi

docker volume inspect "${CACHE}" >/dev/null 2>&1 || docker volume create "${CACHE}" >/dev/null
docker image inspect "${IMAGE}" >/dev/null 2>&1 ||
    docker build -t "${IMAGE}" "${REPO}/make-openwrt/uwe5622/docker"

exec docker run --rm \
    -e HOME=/tmp -e TMPDIR=/cache \
    -v "${mount_source}:/w" -v "${CACHE}:/cache" -w /w \
    "${IMAGE}" bash make-openwrt/uwe5622/build-kmods.sh -v "${KVER}" -t "${KTAGS}"
