#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#============================================================================================
# Run build-kmods.sh inside the pinned build container of this directory.
#
# The container (ubuntu:26.04 pinned by digest, GCC 15) is the same toolchain
# the ophub kernels are built with, so the modules are not affected by whatever
# compiler the host ships.  All arguments are passed to build-kmods.sh, e.g.:
#
#   ./make-openwrt/uwe5622/docker/build-in-docker.sh -v 6.12.69 -t rk35xx
#   ./make-openwrt/uwe5622/docker/build-in-docker.sh -h
#
# Environment:
#   UWE5622_DOCKER_IMAGE   image tag to build/use   (default: uwe5622-builder:26.04)
#   UWE5622_DOCKER_CACHE   docker volume for the downloads (default: uwe5622-build-cache)
#   UWE5622_DOCKER_REBUILD set to "no" to skip "docker build" and use the image as is
#   UWE5622_DOCKER_BASE    override the pinned base image (e.g. ubuntu:26.04)
#============================================================================================
set -euo pipefail

script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_path}/../../.." && pwd)"
image="${UWE5622_DOCKER_IMAGE:-uwe5622-builder:26.04}"
cache_volume="${UWE5622_DOCKER_CACHE:-uwe5622-build-cache}"
rebuild="${UWE5622_DOCKER_REBUILD:-yes}"

# Git Bash / MSYS rewrites arguments that look like POSIX paths, which breaks
# "-w /w", "-e TMPDIR=/cache" and the bind mount.  Disable that and hand docker a
# native path for the mount source.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'
mount_source="${repo_root}"
user_args=()
if command -v cygpath >/dev/null 2>&1; then
    mount_source="$(cygpath -m "${repo_root}")"
    # The host uid is not meaningful on a Windows bind mount; keeping --user
    # there only makes existing files unwritable for the container user.
else
    user_args=(--user "$(id -u):$(id -g)")
fi

info() { echo -e "\033[32m[ INFO ]\033[0m $*"; }
die() { echo -e "\033[31m[ FAIL ]\033[0m $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker is required."
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon."

image_exists="no"
docker image inspect "${image}" >/dev/null 2>&1 && image_exists="yes"

if [[ "${rebuild}" == "yes" || "${image_exists}" != "yes" ]]; then
    info "Building the build image [ ${image} ] (cached layers are reused)."
    build_args=()
    [[ -n "${UWE5622_DOCKER_BASE:-}" ]] && build_args+=(--build-arg "BASE_IMAGE=${UWE5622_DOCKER_BASE}")
    docker build "${build_args[@]}" -t "${image}" "${script_path}" || die "docker build failed."
else
    info "Using the existing build image [ ${image} ]."
fi

docker volume inspect "${cache_volume}" >/dev/null 2>&1 ||
    { info "Creating the download cache volume [ ${cache_volume} ]."; docker volume create "${cache_volume}" >/dev/null; }

info "Toolchain in the image: $(docker run --rm "${image}" grep -m1 '^gcc-aarch64-linux-gnu=' /opt/uwe5622-toolchain.txt)"

docker_args=(
    --rm
    "${user_args[@]}"
    -e HOME=/tmp
    -e TMPDIR=/cache
    -v "${mount_source}:/w"
    -v "${cache_volume}:/cache"
    -w /w
)

exec docker run "${docker_args[@]}" "${image}" bash make-openwrt/uwe5622/build-kmods.sh "$@"
