# SPDX-License-Identifier: GPL-2.0
#
# Build environment for make-openwrt/uwe5622/build-kmods.sh.
#
# The ophub kernels are built with GCC 15, so the modules are compiled in
# Ubuntu 26.04 (gcc-aarch64-linux-gnu 15.2.0) instead of relying on whatever
# cross compiler the host happens to have.  Ubuntu 24.04's GCC 13 cannot even
# handle -fmin-function-alignment=4, which those kernels are built with.
#
# The base image is pinned by digest so the environment does not silently
# change.  Refresh the digest on purpose, e.g.:
#   docker buildx imagetools inspect ubuntu:26.04 --format '{{.Manifest.Digest}}'
#
# Build / use through the wrapper:  ./make-openwrt/uwe5622/docker/build-in-docker.sh
# Or manually:
#   docker build -t uwe5622-builder:26.04 make-openwrt/uwe5622/docker
#   docker run --rm -v "$PWD:/w" -w /w uwe5622-builder:26.04 \
#       bash make-openwrt/uwe5622/build-kmods.sh -v 6.12.69

ARG BASE_IMAGE=ubuntu:26.04@sha256:c098726dd9b9733f3e885f8de0ef375206a311b0a317eadc40d347b1115fb944

FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="amlogic-s9xxx-openwrt uwe5622 module builder"
LABEL org.opencontainers.image.description="Cross compiler and kbuild dependencies used by make-openwrt/uwe5622/build-kmods.sh (Ubuntu 26.04, GCC 15)"
LABEL org.opencontainers.image.source="https://github.com/GinRyan/amlogic-s9xxx-openwrt"

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/tmp

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        gcc-aarch64-linux-gnu \
        binutils-aarch64-linux-gnu \
        make \
        bc \
        bison \
        flex \
        libssl-dev \
        libelf-dev \
        xz-utils \
        python3 \
        curl \
        ca-certificates \
        kmod \
        device-tree-compiler \
        file \
        git \
 && rm -rf /var/lib/apt/lists/* \
 && dpkg-query -W -f='${Package}=${Version}\n' \
        build-essential gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
        make bc bison flex libssl-dev libelf-dev xz-utils python3 curl \
        kmod device-tree-compiler \
        > /opt/uwe5622-toolchain.txt \
 && mkdir -p /cache && chmod 1777 /cache

# Persisted downloads (kernel package + kernel source) live in /cache when the
# volume is mounted, see build-in-docker.sh.
ENV TMPDIR=/cache

WORKDIR /w
CMD ["bash", "make-openwrt/uwe5622/build-kmods.sh", "--help"]
