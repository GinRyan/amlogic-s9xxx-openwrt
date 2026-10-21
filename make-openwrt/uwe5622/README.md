# Orange Pi 3B (RK3566) + UWE5622 / AW859A 无线网卡移植

把 Armbian 的 [uwe5622](https://github.com/armbian/uwe5622) 驱动移植到
[amlogic-s9xxx-openwrt](https://github.com/GinRyan/amlogic-s9xxx-openwrt)（immortalwrt 打包流程），
让 Orange Pi 3B v1.1 上的 UWE5622（AW859A）Wi‑Fi/蓝牙模块在 OpenWrt 下工作。

---

## 1. 为什么不能只"加一个 kmod 包"

本仓库 `remake` 的打包流程和普通 OpenWrt 构建**完全不同**：

```
immortalwrt 源码 (armsr/armv8 通用配置) ──编译──► *rootfs.tar.gz
                                                     │  只用 rootfs，内核不要
                                                     ▼
remake ──► 解包 rootfs ──► 删除 /lib/modules/* ──► 换成 ophub/kernel 的预编译内核+模块
                 │                                   │
                 └── 写 dtb / u-boot / extlinux ──────┘
```

由此产生三个硬约束：

1. **内核是 ophub 预编译的**（如 `6.12.69-rk35xx-ophub`，来自
   [ophub/kernel](https://github.com/ophub/kernel) 的 `kernel_rk35xx` release），
   uwe5622 不在 mainline 里，所以**内核里没有这个驱动**，其配置中也没有任何
   `UWE5622`/`SPARD_WLAN` 符号。
2. rootfs 里的 `/lib/modules/*` 会被整个删除并替换。所以在 immortalwrt 里编译一个
   `kmod-uwe5622` 包毫无意义 —— 它与 ophub 内核 **vermagic 不匹配**，加载时报
   `invalid module format`。
3. **设备树也不完整**：ophub 的 `rk3566-orangepi-3b.dtb` 来自 mainline，只有 SDIO 控制器
   （`&sdmmc1`）和给模块供电的 `sdio_pwrseq`，没有驱动要用的 `uwe-bsp` / `sprd-mtty` 节点。
   （mainline 只给 v2.1 板加了 brcmfmac 的 wifi 节点；v1.1 用的 UWE5622 一直没有 mainline 驱动。）

因此移植分成两件事，都在打包前/打包时完成：

| 步骤 | 做什么 | 由谁完成 |
| --- | --- | --- |
| A | 针对 **特定内核版本** 编译出 vermagic 精确匹配的三个 `.ko` | `build-kmods.sh` |
| B | 打包镜像时把 dtb 打 overlay，并把 `.ko` 装进 `/lib/modules/<release>/extra/` | `remake` 的板级钩子 |

---

## 2. 目录结构

```
make-openwrt/
├── uwe5622/
│   ├── README.md                 ← 本文件
│   ├── build-kmods.sh            ← 为指定 ophub 内核版本编译模块
│   ├── docker/                   ← 固定构建环境（Dockerfile + 包装脚本）
│   │   ├── Dockerfile
│   │   └── build-in-docker.sh
│   ├── driver/                   ← Armbian 驱动源码（上游 commit 见 driver/UPSTREAM）
│   ├── dts/
│   │   ├── orangepi-3b-uwe5622-overlay.dts        ← 给预编译 dtb 用的 overlay
│   │   └── board-orangepi3b-add-uwe5622-wifi-bt-nodes.patch ← 自编内核时用
│   └── kmods/<kernel release>/   ← 编译产物（3 个 .ko + build-info.txt）
└── openwrt-files/different-files/orangepi-3b/rootfs/etc/
    ├── openwrt-board-release.conf   ← 板级打包钩子（打 dtb + 装模块）
    └── modules.d/50-uwe5622         ← 开机自动加载
```

镜像内的最终布局：

```
/boot/dtb/rockchip/rk3566-orangepi-3b.dtb     ← 已注入 uwe-bsp / sprd-mtty
/lib/modules/<release>/extra/uwe5622_bsp_sdio.ko
/lib/modules/<release>/extra/sprdwl_ng.ko
/lib/modules/<release>/extra/sprdbt_tty.ko
/lib/firmware/uwe5622/wcnmodem.bin            ← 来自 ophub/firmware
/lib/firmware/uwe5622/wifi_2355b001_1ant.ini  ← 来自 ophub/firmware
/etc/modules.d/50-uwe5622
```

---

## 3. 快速开始

### 3.1 编译内核模块（换内核版本就要重做一次）

在 Linux 主机（或容器）上：

```bash
sudo apt-get update
sudo apt-get install -y build-essential gcc-aarch64-linux-gnu \
     bc bison flex libssl-dev libelf-dev xz-utils python3 curl

# 默认 6.12.69 / kernel_rk35xx，产物在 make-openwrt/uwe5622/kmods/
./make-openwrt/uwe5622/build-kmods.sh

# 指定版本 / release tag
./make-openwrt/uwe5622/build-kmods.sh -v 6.1.174 -t rk35xx
./make-openwrt/uwe5622/build-kmods.sh -v 6.12.69 -t stable

# 已有内核源码树时（比如自己给内核打过补丁）
./make-openwrt/uwe5622/build-kmods.sh -v 6.12.69 -s ~/linux-6.12.69
```

脚本做的事：

1. 从 `kernel_<tag>` release 下载内核包 `<version>.tar.gz`（~140 MB，和 `remake`
   用的是同一个文件），并从里面取出 `header-<release>.tar.gz`。
   这个内部包是内核构建时产出的，含 **`include/config/auto.conf`、
   `include/generated/autoconf.h`、`include/config/kernel.release`、`Module.symvers`**，
   也就是那颗内核真实的配置和导出符号表；release 名（如 `rk35xx-ophub`）也从这里读出来。
2. 下载对应的上游源码 `linux-<version>.tar.xz`（~150 MB，kernel.org），
   把上面的配置写进 `.config`，`olddefconfig` + `modules_prepare`
   （header 包里没有 Kconfig/scripts，源码树用来提供构建机制）。
3. 把 header 包的 `Module.symvers` 拷进源码树 —— modpost 会用它检查**每个被引用的符号
   在目标内核里确实存在**，缺符号会直接编译失败，而不是留到板子上 `insmod` 才报错。
4. 用 `CONFIG_RK_WIFI_DEVICE_UWE5622=y`、`CONFIG_WLAN_UWE5622=m`、
   `CONFIG_TTY_OVERY_SDIO=m` 编译三个模块。
5. 校验每个 `.ko` 的 `vermagic` 与 `include/config/kernel.release` 完全一致，
   并把 `build-info.txt` 一起写进输出目录。

> **工具链**：ophub 用 GCC 15 编译内核。Ubuntu 24.04 自带 GCC 13 不支持内核使用的
> `-fmin-function-alignment=4`，脚本会自动检测并退回 `CONFIG_FUNCTION_ALIGNMENT=0`
> （只影响函数对齐，不影响 ABI）。

### 3.1.1 用固定镜像编译（推荐）

```bash
# 构建/复用固定镜像 uwe5622-builder:26.04，并在容器里执行 build-kmods.sh
./make-openwrt/uwe5622/docker/build-in-docker.sh -v 6.12.69 -t rk35xx
```

镜像定义在 [docker/Dockerfile](./docker/Dockerfile)：

- 基础镜像 `ubuntu:26.04` **按 digest 固定**（`@sha256:c098726d...`），上游 tag
  重新推送也不会改变构建环境；要升级时显式改 digest（见 Dockerfile 顶部注释）；
- 预装 GCC 15 交叉工具链（`gcc-aarch64-linux-gnu`，与编内核的 15.3.1 同代）和 kbuild
  依赖（bc/bison/flex/libssl-dev/libelf-dev/xz/python3），以及 `dtc`/`kmod`（打 dtb、depmod 时用得上）；
- 镜像内 `/opt/uwe5622-toolchain.txt` 记录了实际装上的包版本，随时可以查：
  ```bash
  docker run --rm uwe5622-builder:26.04 cat /opt/uwe5622-toolchain.txt
  ```
- 内核包与内核源码的下载缓存放在 docker volume `uwe5622-build-cache`（挂载到 `/cache`），
  同一版本第二次构建无需重下 ~290 MB；不用容器时缓存默认在 `${TMPDIR:-/tmp}/uwe5622-cache`，
  可用 `UWE5622_CACHE` 改位置；
- 容器以当前 uid/gid 运行（`--user`），写回仓库的 `.ko` 不会变成 root 所有。

可调环境变量：`UWE5622_DOCKER_IMAGE`、`UWE5622_DOCKER_CACHE`、
`UWE5622_DOCKER_REBUILD=no`（跳过 `docker build`，直接用已有镜像）、
`UWE5622_DOCKER_BASE`（临时换基础镜像，例如离线环境里的内网镜像）。

> Windows 下用 Git Bash 也能直接跑这个包装脚本（已处理 MSYS 的路径自动转换问题）；

> 说明：digest 固定的是**基础镜像**，其中的 apt 归档仍可能随 Ubuntu 更新而变。
> 需要连 apt 包版本也完全固定时，把 Dockerfile 里的 `archive.ubuntu.com` 指向
> `snapshot.ubuntu.com` 的时间戳仓库即可。

### 3.2 打包镜像

```bash
sudo ./remake -b orangepi-3b              # 和平时一样
sudo ./remake -b orangepi-3b -k 6.12.69   # 固定内核版本
```

打包时板级钩子（`different-files/orangepi-3b/rootfs/etc/openwrt-board-release.conf`，
由 `remake` 的 `adjust_kernel_files` 钩子在 `replace_kernel()` 末尾调用）会自动：

* 用 `dtc` + `fdtoverlay` 把 overlay 合进 `/boot/dtb/rockchip/rk3566-orangepi-3b.dtb`
  以及同目录的 `-v1.1.dtb`，并反编译校验 `uwe-bsp` 节点确实存在；
  v2.1（AP6256/brcmfmac）的 dtb 不动。
* 把 `kmods/<release>/*.ko` 拷到 `/lib/modules/<release>/extra/`，
  临时移除内核包为每个模块铺的扁平软链接后跑 `depmod -b <rootfs> <release>`，
  再把软链接按原样恢复（避免同一模块在 `modules.dep` 里出现两次）。

依赖：打包主机需要 `device-tree-compiler`（`dtc`/`fdtoverlay`）和 `kmod`（`depmod`），
两者都已在 `make-openwrt/scripts/ubuntu*-make-openwrt-depends` 里。

> 若目标内核版本没有对应模块，打包会**直接失败**并提示需要执行的命令，避免产出一个
> "看着正常但没有 Wi‑Fi"的镜像。确实要跳过时用 `uwe5622_allow_missing_kmods=yes`。

### 3.3 可刷写的镜像在哪里

`build-kmods.sh` **只产出内核模块**，不产出镜像。镜像由 `remake` 在 Linux 上生成
（immortalwrt rootfs + ophub 内核 + u-boot + 打过补丁的 dtb）。

**本地构建**（Linux 主机，需要 root、loop 设备、btrfs）：

```bash
# 1) 准备一个 armsr/armv8 的 rootfs（remake 会在 openwrt-armsr/ 里找 *rootfs.tar.gz）
mkdir -p openwrt-armsr
wget -O openwrt-armsr/immortalwrt-24.10.2-armsr-armv8-rootfs.tar.gz \
  https://downloads.immortalwrt.org/releases/24.10.2/targets/armsr/armv8/immortalwrt-24.10.2-armsr-armv8-rootfs.tar.gz

# 2) 为要用的内核编模块
./make-openwrt/uwe5622/build-kmods.sh -v 6.12.69 -t rk35xx

# 3) 打包（首次会自动下载 u-boot/内核/固件，约 1~2 GB）
sudo ./remake -b orangepi-3b -k 6.12.69
```

> ⚠️ rootfs 里必须带无线的用户态包，否则镜像能起、驱动也能加载，但 `wifi` 命令和
> LuCI 的"无线"页面都不可用（armsr 默认包集合不含它们）。最少需要：
> `wpad-openssl wifi-scripts iwinfo iw`。用 ImageBuilder 构建时把这几个加进
> `PACKAGES=` 即可。

产物路径（`remake` 的 `out_path`）：

```
openwrt/out/openwrt_<源代号>_rockchip_orangepi-3b_k<内核版本>_<YYYY.MM.DD>.img
# 例如 openwrt/out/openwrt_immortalwrt_rockchip_orangepi-3b_k6.12.69_2026.10.20.img
```

打包日志里应能看到板级钩子的输出，确认驱动真的进了镜像：

```
[ INFO ] uwe5622: patching [ rk3566-orangepi-3b.dtb ] with the uwe-bsp/sprd-mtty nodes.
[ INFO ] uwe5622: installed modules for [ 6.12.69-rk35xx-ophub ]:
```

**GitHub Actions**：跑 `Build OpenWrt system image`（source 选 `immortalwrt_master`，
board 选 `orangepi-3b`），产物在 Release 里（tag `OpenWrt_<branch>_<storage>_<YYYY.MM>`）。

> ⚠️ 注意：本仓库 3 个打包 workflow 原先写的是
> `uses: ophub/amlogic-s9xxx-openwrt@main`，那会用**上游**的 `remake`/`make-openwrt`
> 打包 —— 我们的 `uwe5622` 钩子根本不会执行，镜像里没有驱动。现在已改为本地 action
> `uses: ./`，确保用的是本仓库的打包逻辑。

**关于在 Windows + Docker 里构建**：Docker Desktop 的 WSL2 内核**自带 btrfs**，
`remake` 可以在特权容器里跑通；唯一需要处理的是容器内没有 udev，`losetup -P` 之后
`/dev/loopXpN` 不会自动出现，需要一个 `losetup` 包装脚本按 `/sys/class/block/...`
建好节点。arm64 模块仍然按 `3.1` 交叉编译。

### 3.4 v7 / v8 镜像附带的额外组件（Argon / Docker / EasyTier）

v7 在 v6（驱动修复版）的基础上预装了：

| 组件 | 包 / 文件 | 备注 |
| --- | --- | --- |
| LuCI Argon 主题 | `luci-theme-argon`、`luci-app-argon-config`、`luci-i18n-argon-config-zh-cn` | 来自 luci feed；LuCI → 系统 → 语言和界面里选 Argon |
| Docker | `docker`、`dockerd`、`containerd`、`docker-compose`、`luci-app-dockerman` | 内核 6.12.69 的 cgroup2/namespace/overlay/veth/netfilter 模块齐全 |
| cgroup 挂载 | `cgroupfs-mount` | 容器内 OpenWrt 默认不挂 cgroup2，这个包负责挂载 |

v8 在 v7 之上：

| 组件 | 包 / 文件 | 备注 |
| --- | --- | --- |
| EasyTier 核心 | `easytier-noweb`（官方 ipk，来自 `EasyTier/luci-app-easytier` 的 `aarch64_generic-22.03.7` 构建） | ImmortalWrt 官方 feed 里没有 easytier，用上游仓库的预编译 ipk（opkg 格式） |
| EasyTier LuCI | `luci-app-easytier`（同源 ipk） | 菜单：服务 → EasyTier；含状态/CLI/日志/上传等页面 |
| 中文翻译 | `easytier.zh-cn.lmo`（从 `luci-i18n-easytier-zh-cn` 中只取翻译文件） | i18n ipk 自带的 uci-defaults 与 app 包冲突，故只注入 `.lmo` |
| 分区工具 | `parted`、`sgdisk` | 方便在板上调整分区 |
| rootfs 容量 | `remake -s 55296`（54 GiB） | 适配 64 GB eMMC，Docker 数据不再挤在小分区里 |

> ⚠️ v8 的镜像解压后约 **54 GiB**，刷写时整盘写入（`gunzip -c … | dd … bs=4M`），
> 别用只支持小镜像的工具；64 GB 的 eMMC 能放下还留 ~5 GiB 余量。

v9 又改成"小镜像 + 首次启动自动建数据分区"（日常推荐用它）：

| 项目 | 说明 |
| --- | --- |
| 镜像大小 | `remake -s 4096`，raw 约 4.4 GiB / `.img.gz` 约 346 MB |
| 首次启动 | `/etc/init.d/data-partition`（S90）调用 `/usr/sbin/setup-data-partition`：`sgdisk -e` 修正 GPT 备份头到磁盘末端，再 `sgdisk -n 3:0:0` 把剩余空间建成第 3 分区，`mkfs.btrfs -L DATA`，挂到 `/mnt/data` |
| Docker 数据 | `/opt/docker` 变成指向 `/mnt/data/docker` 的符号链接，Docker 的数据自然落在数据分区 |
| 后续启动 | `/etc/config/fstab` 里已写入 `LABEL=DATA → /mnt/data`，开机自动挂载；脚本本身幂等（已格式化就只挂载） |
| 手动触发 | `setup-data-partition`（无参数自动识别根盘，也可传 `/dev/mmcblk0` 等） |

> 数据分区的创建只在"镜像比介质小"时有意义；如果刷到正好大小的卡上，脚本会因
> 没有剩余空间而退出（日志在 `/tmp/setup-data.log`），不影响系统启动。

Docker 的 `/etc/config/dockerd` 已预置 `option storage_driver 'btrfs'`（根文件系统是
btrfs，避免 overlay-on-btrfs 的坑），`data_root` 默认 `/opt/docker/`。开启：

```sh
/etc/init.d/dockerd enable && /etc/init.d/dockerd start
docker run --rm hello-world
```

EasyTier 在 LuCI 的「服务 → EasyTier」里配置并启用（底层是 `/etc/init.d/easytier`
+ `/etc/config/easytier`，命令行方式同样可用）：

```sh
/etc/init.d/easytier enable && /etc/init.d/easytier start
/usr/bin/easytier-cli peer        # 查看组网状态
```

---

## 4. 实现细节

### 4.1 设备树 overlay

`dts/orangepi-3b-uwe5622-overlay.dts` 给根节点补两个节点（与 Armbian 的
`board-orangepi3b-add-uwe5622-wifi-bt-nodes.patch` 等价）：

```dts
sprd-mtty { compatible = "sprd,mtty"; sprd,name = "ttyBT"; };

uwe-bsp {
    compatible = "unisoc,uwe_bsp";
    wl-reg-on         = <&gpio0 27 0>;   /* RK_PD3 */
    bt-reg-on         = <&gpio2 15 0>;   /* RK_PB7 */
    wl-wake-host-gpio = <&gpio0 30 0>;   /* RK_PD6 */
    bt-wake-host-gpio = <&gpio2 16 0>;   /* RK_PC0 */
    sdio-ext-int-gpio = <&gpio2 17 0>;   /* RK_PC1 */
    data-irq;
    blksz-512;
    keep-power-on;
};
```

* `uwe-bsp` 由 `sdiohal_parse_dt()` / `wcn_boot.c` 用 `of_find_node_by_name()` 查找，
  只在 `CONFIG_RK_BOARD`（= `CONFIG_RK_WIFI_DEVICE_UWE5622`）时启用 DTS 解析。
* `data-irq` 表示用 SDIO 带内中断（`&sdmmc1` 上的 `cap-sdio-irq`），不需要外部中断脚。
* 供电/复位由 mainline 已有的 `sdio_pwrseq`（`gpio0 RK_PD3`）负责，驱动只做
  `keep-power-on`；因此 `wl-reg-on` 与 pwrseq 共用 GPIO 导致驱动申请失败也不影响工作
  （与 Armbian 行为一致）。
* overlay 里的 `&gpio0`/`&gpio2` 由 `fdtoverlay` 在合并时解析成真实 phandle，不写死数值。

如果走"自己编译内核"的路线（例如给 ophub/kernel fork 加 patch），用
`dts/board-orangepi3b-add-uwe5622-wifi-bt-nodes.patch`（取自 Armbian，已用 `git apply`
对 mainline 的 `rk3566-orangepi-3b-v1.1.dts` 验证过），它和上面的 overlay 等价。
对应内核配置：

```
CONFIG_SPARD_WLAN_SUPPORT=y
CONFIG_RK_WIFI_DEVICE_UWE5622=y
CONFIG_WLAN_UWE5622=m
CONFIG_TTY_OVERY_SDIO=m
```

（树内编译时还要在 `drivers/net/wireless/Makefile` 里加
`obj-$(CONFIG_SPARD_WLAN_SUPPORT) += uwe5622/`，并在 `drivers/net/wireless/Kconfig`
里 source 驱动的 `Kconfig`。）

### 4.2 内核模块

`CONFIG_RK_WIFI_DEVICE_UWE5622=y` 在 `unisocwcn/Makefile` 里展开为：

```
-DCONFIG_RK_BOARD -DCONFIG_WCN_PARSE_DTS -DCONFIG_WCN_SDIO -DCONFIG_WCN_SLP
-DCONFIG_WCN_SWD -DCONFIG_WCN_BOOT -DCONFIG_WCN_UTILS -DCONFIG_CHECK_DRIVER_BY_CHIPID
```

另外通过 `UNISOC_WIFI_CUS_CONFIG=/lib/firmware/uwe5622` 把 Wi‑Fi 板级 ini 的查找目录指到
`/lib/firmware/uwe5622`（默认 `/lib/firmware`），与 `wcnmodem.bin` 放一起：

* `wcn_boot.c`：固件路径取 `UNISOC_FW_PATH_CONFIG`（驱动顶层 Makefile 固定为
  `/lib/firmware/uwe5622/`），失败回退 `/lib/firmware/`。
* `rf_marlin3.c`：从 `WIFI_BOARD_CFG_PATH` 读 `wifi_<chipid>_<ant>ant.ini`，
  UWE5622 即 `wifi_2355b001_1ant.ini`。

三个模块的依赖关系（`modules.dep`，由 `modprobe --show-depends` 验证过）：

```
sprdwl_ng.ko      -> uwe5622_bsp_sdio.ko, kernel/net/wireless/cfg80211.ko
sprdbt_tty.ko     -> uwe5622_bsp_sdio.ko
uwe5622_bsp_sdio.ko -> (无)
```

### 4.3 固件

`ophub/firmware` 里已有 `firmware/uwe5622/wcnmodem.bin` 与
`firmware/uwe5622/wifi_2355b001_1ant.ini`，`remake` 会整目录拷进 rootfs 的
`/lib/firmware/`。换其它来源的固件时保持这两个文件在同一目录即可。

### 4.4 开机自动加载

`/etc/modules.d/50-uwe5622`：

```
uwe5622_bsp_sdio
sprdwl_ng
sprdbt_tty
```

`uwe5622_bsp_sdio` 必须先加载（注册 SDIO 驱动、建立 wcn 总线），`sprdwl_ng` 依赖
`cfg80211`（ophub 内核里是模块，kmodloader 会按 `modules.dep` 自动带出）。

### 4.5 与 Armbian 的差异

| 项目 | Armbian | 本移植 |
| --- | --- | --- |
| 驱动形态 | 编进内核树 `drivers/net/wireless/uwe5622/` | 树外模块，按目标内核编译 |
| 设备树 | 打内核 DTS patch 后重编 dtb | 打包阶段用 dtbo + `fdtoverlay` 合并进现成 dtb |
| 内核 | Armbian 自编 | ophub 预编译（不可改） |
| 蓝牙 | systemd + `hciattach_opi` | 只提供 `sprdbt_tty` 与 `sprd-mtty` 节点，attach 需另配 |

---

### 4.6 对上游驱动的修改（cfg80211 建/删接口死锁）

上游 `unisocwifi/main.c` 在 `add_virtual_intf` 回调里直接调 `register_netdevice()`，
而这条路径是 cfg80211 持着 wiphy 锁进来的；`register_netdevice()` 触发的
`cfg80211_netdev_notifier_call` 又要拿同一把锁 → 自死锁（内核报 hung task，
`netifd`/`ucode`/`linkwatch`/`reg_check_chans_work` 全部卡在 `rtnl_lock`）。
表现就是：**只要 hostapd/netifd 建或删一个虚拟接口，整个网络栈就死掉**
（OpenWrt 首次启动会自动建一个默认 AP 接口，所以新镜像会"起得来但没有 IP"）。
删除接口路径（`unregister_netdevice()`）是同一个问题。

本移植的改法（`unisocwifi/main.c`、`unisocwifi/sprdwl.h`、`unisocwifi/cfg80211.c`）：

```c
/* 来自 cfg80211 op 时（内核 >= 6.5）用 cfg80211 的注册/注销接口：
 * 它们会先把 wdev 标记为 registering/registered，notifier 便不再抢锁 */
if (cfg80211_ctx)
    ret = cfg80211_register_netdevice(ndev);
else
    ret = register_netdevice(ndev);            /* probe 时仍用原路径 */

if (cfg80211_ctx)
    cfg80211_unregister_wdev(&vif->wdev);
else
    unregister_netdevice(vif->ndev);
```

`cfg80211_ctx` 由调用方传入：`sprdwl_cfg80211_add_iface()`/`del_iface()` 传 `true`，
probe 和卸载路径传 `false`。这样既不改变首次注册的行为，又消除了运行期死锁。

### 4.7 让 LuCI 显示信号/速率/站点列表

libiwinfo（LuCI 的无线页面）取信号强度、协商速率和"已连接站点"列表，走的都是
`NL80211_CMD_GET_STATION` + `NLM_F_DUMP`，也就是驱动的 `dump_station` 回调；
Tx-Power 则走 `get_tx_power`。上游驱动这两个回调都没实现，所以：

* 客户端模式下 `iwinfo` 显示 `Signal: unknown`、`Bit Rate: unknown`；
* AP 模式下"已连接站点"永远为空；
* `Tx-Power` 恒为 0 dBm。

本移植补了三处（`unisocwifi/cfg80211.c`、`unisocwifi/sprdwl.h`）：

1. `.dump_station`：客户端模式返回所连 AP 的 BSSID + 固件上报的信号/速率；
   AP 模式遍历 `sprdwl_report_softap()` 里维护的对端 MAC 表；
2. `.get_tx_power`：返回射频配置的 20 dBm（固件不回读实际功率）；
3. `struct sprdwl_vif` 增加 `sta_addr[]`/`sta_count`，在 `sprdwl_report_softap()`
   里维护 AP 模式的关联站点表。

改完后 `iwinfo` 输出示例（真机）：

```
phy0-sta0 ESSID: "Gin6-5G"
          Tx-Power: 20 dBm  Link Quality: 70/70
          Signal: -39 dBm  Noise: unknown
          Bit Rate: 390.0 MBit/s
```

> ⚠️ 接收速率是**估算值**：固件 `WIFI_CMD_GET_STATION` 只回一个 rate（发送速率），RX 描述符
> 里也没有 rate 字段，所以 `dump_station` 把 TX rate 镜像到 `rxrate`
> （`NL80211_STA_INFO_RX_BITRATE`），让 iwinfo/LuCI 的 "RX Rate" 不再是 0/unknown。
> 这是显示兜底，不是接收链路的实测速率。

---

## 5. 板上验证

```sh
# 1) 模块
lsmod | grep -E 'uwe5622|sprdwl|sprdbt'
dmesg | grep -iE 'uwe|wcn|sprdwl|sdiohal'

# 2) 无线接口
iw dev                       # 期望出现 wlan0
ip link show wlan0

# 3) 扫描
iw wlan0 scan | head -30

# 4) 配置
uci set wireless.radio0.disabled=0
wifi config                  # /etc/config/wireless 缺失时生成
wifi reload
```

正常启动时 dmesg 里应能看到：

```
sdiohal: ...
adma_tx:0, adma_rx:0, pwrseq:0, irq type:data, ...
wifi ini path = /lib/firmware/uwe5622/wifi_2355b001_1ant.ini
```

---

## 6. 故障排查

| 现象 | 排查 |
| --- | --- |
| `invalid module format ... vermagic` | `.ko` 与镜像内核实测版本不符；用 `uname -r` 的版本重跑 `build-kmods.sh` |
| `module not found in modules.dep` | 打包时被 `uwe5622_allow_missing_kmods=yes` 跳过；检查 `/lib/modules/$(uname -r)/extra/` |
| dmesg: `dts node not found` | dtb 没打补丁：`dtc -I dtb -O dts /boot/dtb/rockchip/rk3566-orangepi-3b.dtb \| grep uwe-bsp` |
| 没有 `sdiohal_probe` 日志 | SDIO 没枚举：确认板子是 v1.1（UWE5622）而不是 v2.1（AP6256/brcmfmac），`&sdmmc1` 为 `okay` |
| 固件下载失败 | 确认 `/lib/firmware/uwe5622/wcnmodem.bin` 存在且非空 |
| 能扫到 AP 但连不上 | 看 `wifi_2355b001_1ant.ini` 是否在 `/lib/firmware/uwe5622/`；`dmesg \| grep ini` |
| 蓝牙没有 `/dev/ttyBT0` | 需要 `sprdbt_tty` 已加载 + overlay 的 `sprd-mtty`；attach 还需 Armbian 的 `hciattach_opi` |

---

## 7. 换内核 / 升级

`remake` 默认挑 `kernel_rk35xx` 的最新版本。升级前先给目标版本编模块：

```bash
# 看 kernel_rk35xx 里最新的 6.12.x
curl -fsSL https://github.com/ophub/kernel/releases/expanded_assets/kernel_rk35xx \
  | grep -oP '6\.12\.[0-9]+(?=\.tar\.gz)' | sort -urV | head -1

./make-openwrt/uwe5622/build-kmods.sh -v <version> -t rk35xx
```

---

## 8. 已验证 / 已知限制

**已验证**（在 x86_64 + Ubuntu 26.04 容器里，交叉编译 arm64）：

* `build-kmods.sh` 能针对 `6.12.69-rk35xx-ophub` 编出三个模块；
* `vermagic` 与目标内核模块完全一致：`6.12.69-rk35xx-ophub SMP mod_unload aarch64`；
* 用目标内核的 `Module.symvers` 做 modpost，**没有未解析符号**（符号全部存在于目标内核）；
* 生成的 `include/generated/autoconf.h` 与目标内核相比：5280 个公共符号中仅 11 处不同，
  且都是与 ABI 无关的项（编译器版本串、`CONFIG_DEFAULT_HOSTNAME`、`CONFIG_LSM` 顺序、
  NLS 字符集、`CONFIG_ANDROID_BINDER_DEVICES` 等）；其余差异是 ophub 打的 Rockchip BSP
  驱动多出来的符号；
* overlay + `fdtoverlay` 合并后 dtb 里确实出现 `uwe-bsp`/`sprd-mtty`，v2.1 的 dtb 不受影响；
* `depmod` + `modprobe --show-depends sprdwl_ng` 给出的加载顺序是
  `cfg80211 → uwe5622_bsp_sdio → sprdwl_ng`，与 `/etc/modules.d/50-uwe5622` 一致。

**已验证（Orange Pi 3B v1.1 真机，ImmortalWrt 24.10.2 + `6.12.69-rk35xx-ophub`）**：

* SDIO 枚举成功：`mmc2:8800:1`，`new ultra high speed SDR104 SDIO card at address 8800`，
  总线 148.5 MHz，`DRIVER=sdiohal`；
* 芯片识别 `chipid: 0x2355b001`，与固件 `wifi_2355b001_1ant.ini` 对应；
* 固件下载成功：`marlin_firmware_write finish and successful` →
  `then marlin download finished and run ok`，CP 版本
  `MARLIN3_19B_W21.05.3~sc2355_marlin3_lite_ott`；
* 射频校准：`cali_ini_need_download return 1`、`get_board_ant_num [one_ant]`、
  `wifi ini path = /lib/firmware/uwe5622/wifi_2355b001_1ant.ini`；
* 注册出 `phy0` / `wlan0`（MAC 由 efuse 读出），`iw dev wlan0 scan` 能扫到多个 AP
  （实测 8 个，信号 -30 ~ -70 dBm，RSN/WPA2 解析正常）——**STA 模式可用**。

**限制**：

* 只针对 Orange Pi 3B **v1.1**（UWE5622/AW859A）。v2.1 用 AP6256，走 brcmfmac，
  不需要（也打不上）这个 overlay。
* **AP 模式**：新建/删除虚拟接口在**上游驱动里会死锁**（原因见 4.6）；
  本仓库已按 4.6 打了补丁（`cfg80211_register_netdevice()` /
  `cfg80211_unregister_wdev()`），需要重新编译模块并重新验证。
* 蓝牙未打通：`sprdbt_tty` 注册 `ttyBT0` 时报 `-EEXIST`（`mtty probe ... failed with
  error -17`），且 Armbian 的 `hciattach_opi` 未随本移植分发。
* rootfs 必须带 `wpad-openssl wifi-scripts iwinfo iw`，否则 `wifi`/LuCI 无线页不可用；
  这些包在板子上属于 **`aarch64_generic`** 架构（不是 `aarch64_cortex-a53`）。
* ophub 的内核是 mainline + Rockchip BSP 补丁。若某次 BSP 补丁改动了 MMC/cfg80211
  等公共结构体，理论上会影响模块 ABI；用 `-s <内核源码树>` 针对打过补丁的树编译即可消除。
* 树外模块与内核版本强绑定：仓库里提交的 `.ko` 只对应 `build-info.txt` 里记录的那个版本。
