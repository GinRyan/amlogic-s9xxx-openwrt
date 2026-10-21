# SPDX-License-Identifier: GPL-2.0
#
# Runtime container used by image/build-image.sh to assemble a flashable
# Orange Pi 3B image (ImmortalWrt rootfs + ophub kernel + patched dtb).
#
# It extends the pinned module build image (see ../docker/Dockerfile) with the
# tools ./remake needs: loop devices, mkfs.{vfat,ext4,btrfs}, parted, rsync.
#
#   docker build -t uwe5622-builder:26.04     make-openwrt/uwe5622/docker
#   docker build -t openwrt-image-builder:1  make-openwrt/uwe5622/image
#
# The image builder must run privileged (loop devices + mounts):
#   docker run --rm --privileged \
#       -v "$PWD:/work" -v "$PWD/out:/out" -v openwrt-imgbuild:/build \
#       openwrt-image-builder:1 bash /work/make-openwrt/uwe5622/image/build-image.sh

FROM uwe5622-builder:26.04

LABEL org.opencontainers.image.title="amlogic-s9xxx-openwrt image builder"
LABEL org.opencontainers.image.description="remake runtime dependencies on top of the uwe5622 build image"
LABEL org.opencontainers.image.source="https://github.com/GinRyan/amlogic-s9xxx-openwrt"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        parted \
        gdisk \
        dosfstools \
        e2fsprogs \
        btrfs-progs \
        util-linux \
        rsync \
        jq \
 && rm -rf /var/lib/apt/lists/*

CMD ["bash", "-c", "make-openwrt/uwe5622/image/build-image.sh --help 2>/dev/null || true; exec bash"]
