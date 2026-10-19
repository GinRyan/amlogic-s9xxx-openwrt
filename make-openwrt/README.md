# Directory Description

[English Instructions](README.md) | [中文说明](README.cn.md)

The related directories contain files required for compiling OpenWrt.

## openwrt-files

This directory contains files needed when packaging OpenWrt. The `common-files` directory holds universal files, the `platform-files` directory contains platform-specific files, and the `different-files` directory stores device-specific differential files.

- System files are automatically downloaded from the [ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian/tree/main/build-armbian/armbian-files) repository to the `platform-files` and `different-files` directories.

- Firmware files are automatically downloaded from the [ophub/firmware](https://github.com/ophub/firmware) repository to the `common-files/lib/firmware` directory.

- Installation/update scripts are automatically downloaded from the [ophub/luci-app-amlogic](https://github.com/ophub/luci-app-amlogic) repository to the `common-files/usr/sbin` directory.

## kernel

Create version-specific folders under the `kernel` directory, such as `stable/5.10.125`. For multiple kernels, create directories sequentially and place the corresponding kernel files in each. Kernel files can be downloaded from the [kernel](https://github.com/ophub/kernel) repository, or you can [compile them yourself](https://github.com/ophub/amlogic-s9xxx-armbian/tree/main/compile-kernel). If kernel files are not manually downloaded, the build script will automatically download them from the kernel repository during compilation.

## u-boot

System bootloader files that are automatically handled by the installation/update scripts as needed, based on the kernel version. The required u-boot files are automatically downloaded from the [ophub/u-boot](https://github.com/ophub/u-boot) repository to the `u-boot` directory.

## scripts

When executing `remake`, the required dependency packages for the current server environment are installed automatically. Other script files assist with compiling or building the OpenWrt system.

## uwe5622

Out-of-tree Unisoc UWE5622 (AW859A) Wi-Fi/Bluetooth driver for the Orange Pi 3B v1.1 (RK3566): driver sources, a device tree overlay for the prebuilt board dtb and a script that builds the kernel modules for a specific ophub kernel release. See [uwe5622/README.md](./uwe5622/README.md).

用于 Orange Pi 3B v1.1（RK3566）的 UWE5622（AW859A）无线/蓝牙驱动：驱动源码、给预编译 dtb 用的设备树 overlay，以及按 ophub 内核版本编译模块的脚本。详见 [uwe5622/README.md](./uwe5622/README.md)。
