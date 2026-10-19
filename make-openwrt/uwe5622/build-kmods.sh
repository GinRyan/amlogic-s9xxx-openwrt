#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#============================================================================================
# https://github.com/ophub/amlogic-s9xxx-openwrt
#
# Build the out-of-tree Unisoc UWE5622 (AW859A) Wi-Fi/Bluetooth modules for an
# ophub kernel release, with the exact module ABI (vermagic) of that kernel.
#
# Why this is needed
# ------------------
# ./remake does not compile a kernel: it unpacks a prebuilt kernel from
# https://github.com/ophub/kernel, throws away the rootfs' /lib/modules and
# installs the kernel's own module tree.  The uwe5622 driver is not part of
# mainline and is not in those kernels, and a module built by the OpenWrt build
# system would have the wrong vermagic.  So the driver has to be compiled
# against the very kernel that will run on the board.
#
# How it is done
# --------------
#   * The ophub kernel package (<version>.tar.gz, ~140 MB) bundles a
#     "header-<release>.tar.gz" produced by the kernel build itself.  It contains
#     include/config/auto.conf, include/generated/autoconf.h,
#     include/config/kernel.release and Module.symvers, i.e. the exact
#     configuration and the exact exported symbol table of the shipped kernel.
#     We use it as the source of truth and also read the release name from it.
#   * The build machinery (Kconfig files, scripts/, host tools) is missing from
#     that archive, so we unpack the matching upstream source tree and drop the
#     header archive's configuration + Module.symvers into it.  Nothing is
#     re-derived from .config: olddefconfig keeps the exact same values and
#     Module.symvers lets modpost verify every symbol our driver imports.
#   * The result is checked against include/config/kernel.release, so a module
#     that would not load on the target kernel fails here instead of on the
#     board.
#
# Requirements (host): bash, curl, tar, xz, make, bc, bison, flex, libssl-dev,
#                      libelf-dev, python3 and an aarch64 cross compiler (unless
#                      running natively on arm64).
#
# Examples
#   ./build-kmods.sh                       # 6.12.69 from kernel_rk35xx
#   ./build-kmods.sh -v 6.1.174 -t rk35xx  # another rk35xx kernel
#   ./build-kmods.sh -v 6.12.69 -t stable  # kernel_stable release
#   ./build-kmods.sh -n 6.12.69-rk35xx-ophub -v 6.12.69 --source-dir ~/linux
#
# GitHub Actions (x86_64 runner):
#   sudo apt-get install -y build-essential gcc-aarch64-linux-gnu bc bison flex \
#        libssl-dev libelf-dev xz-utils python3
#   ./make-openwrt/uwe5622/build-kmods.sh -v 6.12.69
#
# The kernel is built by ophub with GCC 15, so prefer an Ubuntu 26.04 container
# for a byte-identical toolchain:
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:26.04 bash -c "apt-get update -qq &&
#     apt-get install -y -qq build-essential gcc-aarch64-linux-gnu bc bison flex
#     libssl-dev libelf-dev xz-utils python3 && ./make-openwrt/uwe5622/build-kmods.sh"
#============================================================================================
set -euo pipefail

script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kernel_repo="ophub/kernel"
kernel_tag="rk35xx"
kernel_version="6.12.69"
kernel_name=""
output_path=""
source_dir=""
keep_build="no"
arch="arm64"

if [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]]; then
    default_cross=""
else
    default_cross="aarch64-linux-gnu-"
fi
cross_compile="${CROSS_COMPILE-${default_cross}}"
jobs="$(nproc 2>/dev/null || echo 4)"

info() { echo -e "\033[32m[ INFO ]\033[0m $*"; }
warn() { echo -e "\033[33m[ WARN ]\033[0m $*"; }
die() { echo -e "\033[31m[ FAIL ]\033[0m $*" >&2; exit 1; }

usage() {
    awk 'NR > 3 && /^set -euo pipefail/ { exit } NR > 3 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
    echo
    echo "Options:"
    echo "  -v <version>   Kernel version, e.g. 6.12.69 (default: ${kernel_version})"
    echo "  -t <tag>       ophub kernel release tag without the 'kernel_' prefix"
    echo "                 (default: ${kernel_tag}); e.g. rk35xx, stable"
    echo "  -n <release>   Expected kernel release name, sanity checked against the"
    echo "                 kernel package (e.g. 6.12.69-rk35xx-ophub)"
    echo "  -o <dir>       Output directory (default: <script>/kmods)"
    echo "  -s <dir>       Use an existing kernel source tree instead of downloading it"
    echo "  -k             Keep the unpacked kernel tree after the build"
    echo "  -h             Show this help"
}

while getopts ":v:t:n:o:s:kh" opt; do
    case "${opt}" in
        v) kernel_version="${OPTARG}" ;;
        t) kernel_tag="${OPTARG}" ;;
        n) kernel_name="${OPTARG}" ;;
        o) output_path="${OPTARG}" ;;
        s) source_dir="${OPTARG}" ;;
        k) keep_build="yes" ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

[[ -n "${output_path}" ]] || output_path="${script_path}/kmods"
driver_path="${script_path}/driver"
[[ -f "${driver_path}/Makefile" ]] || die "Driver source not found in [ ${driver_path} ]."
[[ -n "${kernel_version}" ]] || die "Kernel version is required."

# ---------------------------------------------------------------------------------------
# 1. Download the ophub kernel package and read the release name from its members
# ---------------------------------------------------------------------------------------
# Downloads are cached separately from the build tree so that a second run (or a
# different kernel of the same version) does not fetch ~290 MB again.
cache_path="${UWE5622_CACHE:-${TMPDIR:-/tmp}/uwe5622-cache}"
work_path="${TMPDIR:-/tmp}/uwe5622-build-${kernel_version}-${kernel_tag}"
mkdir -p "${cache_path}" "${work_path}"

# The kernel package (<version>.tar.gz) bundles boot/, modules/, dtb/ and
# header-<release>.tar.gz; the release name is only visible from the inside.
package_file="${cache_path}/kernel-${kernel_version}.tar.gz"
if [[ ! -s "${package_file}" ]]; then
    package_url="https://github.com/${kernel_repo}/releases/download/kernel_${kernel_tag}/${kernel_version}.tar.gz"
    info "Downloading the kernel package [ ${package_url} ] (~140 MB)"
    curl -fL --retry 3 --retry-delay 5 -o "${package_file}" "${package_url}" ||
        { rm -f "${package_file}"; die "Kernel package download failed for [ ${kernel_version} ] in tag [ kernel_${kernel_tag} ]."; }
fi

package_members="$(tar -tzf "${package_file}")" || die "Cannot read [ ${package_file} ]."
header_member="$(printf '%s\n' "${package_members}" |
    grep -E '(^|/)header-[A-Za-z0-9._-]*\.tar\.gz$' |
    sort -u | sed -n '1p' || true)"
[[ -n "${header_member}" ]] ||
    die "[ ${package_file} ] does not contain a header-*.tar.gz member."
package_release="${header_member##*/}"
package_release="${package_release#header-}"
package_release="${package_release%.tar.gz}"
if [[ -z "${kernel_name}" ]]; then
    kernel_name="${package_release}"
elif [[ "${kernel_name}" != "${package_release}" ]]; then
    die "Release name mismatch: requested [ ${kernel_name} ], package contains [ ${package_release} ]."
fi
info "Kernel release: [ ${kernel_name} ]"

# ---------------------------------------------------------------------------------------
# 2. Extract the kernel header archive (config + Module.symvers + release)
# ---------------------------------------------------------------------------------------
header_tree="${work_path}/header"
if [[ ! -f "${header_tree}/include/config/kernel.release" ]]; then
    rm -rf "${header_tree}" && mkdir -p "${header_tree}"
    info "Extracting [ ${header_member} ]."
    tar -xzf "${package_file}" -C "${work_path}" "${header_member}" || die "Header extraction failed."
    tar -xzf "${work_path}/${header_member}" -C "${header_tree}" || die "Header extraction failed."
fi
kernel_release="$(cat "${header_tree}/include/config/kernel.release")"
info "Kernel release string: [ ${kernel_release} ]"

# LOCALVERSION that the kernel was built with (e.g. "-rk35xx-ophub").
if [[ "${kernel_release}" == "${kernel_version}" ]]; then
    localversion=""
else
    localversion="${kernel_release#"${kernel_version}"}"
    if [[ "${localversion}" == "${kernel_release}" ]]; then
        warn "[ ${kernel_release} ] does not start with [ ${kernel_version} ], using LOCALVERSION=${localversion}."
    fi
fi
info "LOCALVERSION: [ ${localversion} ]"

# ---------------------------------------------------------------------------------------
# 3. Get the kernel source tree (build machinery; config comes from the header archive)
# ---------------------------------------------------------------------------------------
kernel_src=""
if [[ -n "${source_dir}" ]]; then
    [[ -f "${source_dir}/Makefile" ]] || die "[ ${source_dir} ] does not look like a kernel tree."
    kernel_src="$(cd "${source_dir}" && pwd)"
    info "Using existing kernel source tree [ ${kernel_src} ]."
else
    kernel_src="${work_path}/linux"
    if [[ ! -f "${kernel_src}/Makefile" ]]; then
        src_file="${cache_path}/linux-${kernel_version}.tar.xz"
        if [[ ! -s "${src_file}" ]]; then
            # kernel.org keeps every 6.x release under v6.x/ (not v6.12.x/)
            kernel_series="v$(echo "${kernel_version}" | cut -d. -f1).x"
            for mirror in "https://cdn.kernel.org/pub/linux/kernel" "https://mirrors.edge.kernel.org/pub/linux/kernel"; do
                src_url="${mirror}/${kernel_series}/linux-${kernel_version}.tar.xz"
                info "Downloading [ ${src_url} ]"
                curl -fL --retry 3 --retry-delay 5 -o "${src_file}" "${src_url}" && break
                rm -f "${src_file}"
            done
            [[ -s "${src_file}" ]] || die "Kernel source download failed for [ ${kernel_version} ]."
        fi
        info "Extracting the kernel source."
        rm -rf "${kernel_src}" && mkdir -p "${kernel_src}"
        tar -xf "${src_file}" -C "${kernel_src}" --strip-components=1 || die "Kernel source extraction failed."
    fi
fi
[[ -f "${kernel_src}/Makefile" ]] || die "Kernel source tree is missing."

# ---------------------------------------------------------------------------------------
# 4. Toolchain sanity check
# ---------------------------------------------------------------------------------------
cc_bin="${cross_compile}gcc"
command -v "${cc_bin}" >/dev/null 2>&1 || die "Compiler [ ${cc_bin} ] not found. Install it or set CROSS_COMPILE."
info "Compiler: $(command -v "${cc_bin}") ($("${cc_bin}" -dumpfullversion 2>/dev/null || "${cc_bin}" -dumpversion))"

declare -a extra_args=()
if ! "${cc_bin}" -fmin-function-alignment=4 -E -x c /dev/null >/dev/null 2>&1; then
    warn "This compiler does not support -fmin-function-alignment=4 (GCC>=14 kernels use it)."
    warn "Building with CONFIG_FUNCTION_ALIGNMENT=0; that only changes code alignment, not the ABI."
    extra_args+=("CONFIG_FUNCTION_ALIGNMENT=0")
fi

declare -a make_common=(
    "ARCH=${arch}"
    "CROSS_COMPILE=${cross_compile}"
    "LOCALVERSION=${localversion}"
)

# ---------------------------------------------------------------------------------------
# 5. Configure the tree with the exact configuration of the shipped kernel
# ---------------------------------------------------------------------------------------
info "Configuring the kernel tree with the shipped kernel configuration."
cp -f "${header_tree}/include/config/auto.conf" "${kernel_src}/.config"
make -C "${kernel_src}" "${make_common[@]}" olddefconfig >/dev/null ||
    die "olddefconfig failed."
make -C "${kernel_src}" "${make_common[@]}" "modules_prepare" "-j${jobs}" >/dev/null ||
    die "modules_prepare failed."

built_release="$(cat "${kernel_src}/include/config/kernel.release" 2>/dev/null || true)"
[[ "${built_release}" == "${kernel_release}" ]] ||
    die "Release mismatch: kernel tree yields [ ${built_release} ], the shipped kernel is [ ${kernel_release} ]."

# Verify that the generated configuration is the one the kernel was built with.
# Extra symbols (BSP drivers added by ophub patches) are harmless, a changed value
# of a common symbol would mean a different ABI.
if command -v python3 >/dev/null 2>&1 && [[ -f "${header_tree}/include/generated/autoconf.h" ]]; then
    python3 - "${kernel_src}/include/generated/autoconf.h" "${header_tree}/include/generated/autoconf.h" <<'EOF' || true
import re, sys

def parse(path):
    data = {}
    with open(path, errors="replace") as fp:
        for line in fp:
            line = line.strip()
            m = re.match(r"#define\s+(CONFIG_[A-Za-z0-9_]+)\s+(.*)", line)
            if m:
                data[m.group(1)] = m.group(2).strip()
            m = re.match(r"/\* #undef (CONFIG_[A-Za-z0-9_]+) \*/", line)
            if m:
                data[m.group(1)] = "n"
    return data

ours = parse(sys.argv[1])
shipped = parse(sys.argv[2])
changed = {k: (ours[k], shipped[k]) for k in set(ours) & set(shipped) if ours[k] != shipped[k]}
added = set(shipped) - set(ours)
missing = set(ours) - set(shipped)
print("  common symbols: %d, shipped-only: %d, build-only: %d, value changes: %d"
      % (len(set(ours) & set(shipped)), len(added), len(missing), len(changed)))
for key in sorted(changed)[:20]:
    print("  value change: %s ours=%s shipped=%s" % (key, changed[key][0], changed[key][1]))
if not changed:
    print("  configuration matches the shipped kernel (ABI safe)")
EOF
fi

# The exported symbol table of the shipped kernel: modpost uses it to verify
# that every symbol our modules import really exists in that kernel.
cp -f "${header_tree}/Module.symvers" "${kernel_src}/Module.symvers"
info "Using the shipped kernel's Module.symvers ($(grep -c . "${kernel_src}/Module.symvers") symbols)."

# ---------------------------------------------------------------------------------------
# 6. Build the modules
# ---------------------------------------------------------------------------------------
# CONFIG_RK_WIFI_DEVICE_UWE5622 : rockchip support (-DCONFIG_RK_BOARD,
#                                 -DCONFIG_WCN_PARSE_DTS, SDIO transport)
# CONFIG_WLAN_UWE5622           : builds unisocwifi/sprdwl_ng.ko
# CONFIG_TTY_OVERY_SDIO         : builds tty-sdio/sprdbt_tty.ko (Bluetooth)
# UNISOC_WIFI_CUS_CONFIG        : look for wifi_<chipid>_<ant>ant.ini in
#                                 /lib/firmware/uwe5622 next to wcnmodem.bin
info "Building the uwe5622 modules for [ ${kernel_release} ]."
make -C "${kernel_src}" \
    "${make_common[@]}" \
    "M=${driver_path}" \
    "CONFIG_RK_WIFI_DEVICE_UWE5622=y" \
    "CONFIG_WLAN_UWE5622=m" \
    "CONFIG_TTY_OVERY_SDIO=m" \
    "UNISOC_WIFI_CUS_CONFIG=/lib/firmware/uwe5622" \
    "-j${jobs}" \
    "${extra_args[@]}" \
    "modules" || die "Module build failed."

# ---------------------------------------------------------------------------------------
# 7. Collect and verify the result
# ---------------------------------------------------------------------------------------
dest_path="${output_path}/${kernel_release}"
mkdir -p "${dest_path}"
declare -a built_modules=()
for ko in \
    "${driver_path}/unisocwcn/uwe5622_bsp_sdio.ko" \
    "${driver_path}/unisocwifi/sprdwl_ng.ko" \
    "${driver_path}/tty-sdio/sprdbt_tty.ko"; do
    [[ -f "${ko}" ]] || die "Module [ ${ko} ] was not produced."
    vermagic="$(strings "${ko}" | grep -m 1 '^vermagic=' || true)"
    [[ "${vermagic}" == "vermagic=${kernel_release} "* ]] ||
        die "vermagic mismatch in [ $(basename "${ko}") ]: [ ${vermagic} ] != [ vermagic=${kernel_release} ... ]"
    cp -f "${ko}" "${dest_path}/"
    # Drop the debug information; that is what an installed kernel does too and
    # it keeps the repository small.  Relocations and .modinfo are preserved.
    if command -v "${cross_compile}strip" >/dev/null 2>&1; then
        "${cross_compile}strip" --strip-debug "${dest_path}/$(basename "${ko}")" || true
    fi
    built_modules+=("$(basename "${ko}")")
    info "Built [ $(basename "${ko}") ] ($(stat -c%s "${dest_path}/$(basename "${ko}")") bytes)"
done

# Write through a temporary file: the destination may be an existing file the
# current user cannot open for writing (e.g. a bind mount with foreign ownership).
info_tmp="${dest_path}/.build-info.txt.tmp"
{
    echo "kernel_release=${kernel_release}"
    echo "kernel_tag=kernel_${kernel_tag}"
    echo "kernel_version=${kernel_version}"
    echo "driver_upstream=$(head -n 2 "${driver_path}/UPSTREAM" 2>/dev/null | tr '\n' ' ')"
    echo "compiler=$("${cc_bin}" --version | head -n 1)"
    echo "build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for name in "${built_modules[@]}"; do
        echo "${name}: $(strings "${dest_path}/${name}" | grep -m 1 '^vermagic=')"
    done
} >"${info_tmp}" && mv -f "${info_tmp}" "${dest_path}/build-info.txt" ||
    die "Cannot write [ ${dest_path}/build-info.txt ]."

info "Modules are in [ ${dest_path} ]:"
ls -l "${dest_path}"

# Clean the driver tree so a later run starts from pristine sources.
make -C "${kernel_src}" "${make_common[@]}" "M=${driver_path}" clean >/dev/null 2>&1 || true
if [[ "${keep_build}" != "yes" ]]; then
    rm -rf "${work_path}"
fi

info "Done. Keep [ ${dest_path} ] under make-openwrt/uwe5622/kmods/ for the packaging step."
