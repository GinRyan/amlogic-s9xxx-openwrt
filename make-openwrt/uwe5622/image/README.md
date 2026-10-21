# 镜像构建（ImageBuilder + remake）

本目录包含把 ImmortalWrt rootfs 打包成 **可刷写 Orange Pi 3B 镜像** 的全部脚本与
文件；`../docker/` 只负责交叉编译驱动模块，本目录负责 image 组装。

## 文件

| 文件 | 作用 |
| --- | --- |
| `Dockerfile` | `openwrt-image-builder:1` 镜像：在 `uwe5622-builder:26.04` 上加 loop 设备/mkfs/parted/rsync 等 `remake` 运行时依赖 |
| `build-image.sh` | ImageBuilder 生成 rootfs（含 Argon/Docker/passwall/EasyTier ipk）→ `remake` 打内核/u-boot/DTB → 输出 `*.img.gz` |
| `finalize-image.sh` | 校验镜像（模块 vermagic、dtb、包）、注入 `extra-rootfs/`、设 root 密码、重新压缩并算 sha256 |
| `fetch-easytier-ipks.sh` | 从 `EasyTier/luci-app-easytier` 的 release 下载 `easytier-noweb`/`luci-app-easytier` ipk 和 zh-cn 翻译 |
| `rebuild-kmods.sh` | 在固定容器里重编 `sprdwl_ng.ko` 等（等价于 `../docker/build-in-docker.sh`） |
| `extra-rootfs/` | 注入镜像的额外文件（见下） |

## 完整流程

```bash
# 0) 一次性：构建两个容器镜像
docker build -t uwe5622-builder:26.04    make-openwrt/uwe5622/docker
docker build -t openwrt-image-builder:1  make-openwrt/uwe5622/image

# 1) 编译（换内核版本后必做）
./make-openwrt/uwe5622/image/rebuild-kmods.sh          # KVER=6.12.69

# 2) 下载 EasyTier 的预编译 ipk（首次/换版本时）
./make-openwrt/uwe5622/image/fetch-easytier-ipks.sh    # 默认放到 <repo>/../easytier-luci/ipk

# 3) 生成镜像（容器内跑，需要 --privileged 和 loop 设备）
docker run --rm --privileged \
    -v "$PWD/..:/work" -v "$PWD/../out:/out" -v openwrt-imgbuild:/build \
    openwrt-image-builder:1 \
    bash /work/amlogic-s9xxx-openwrt/make-openwrt/uwe5622/image/build-image.sh

# 4) 收尾（注入数据分区脚本、设密码、压缩）
docker run --rm --privileged \
    -v "$PWD/..:/work" -v "$PWD/../out:/out" \
    openwrt-image-builder:1 \
    bash /work/amlogic-s9xxx-openwrt/make-openwrt/uwe5622/image/finalize-image.sh
```

输出：`out/openwrt_immortalwrt_orangepi-3b_k6.12.69_wpad-passwall-wifi-v9.img.gz`。

`build-image.sh` 的环境变量：`WORK`（默认 `/work`）、`REPO`、`OUT`、`IB`、
`IPK_DIR`、`KVER`（`6.12.69`）、`ROOTFS_MB`（`4096`）、`TAG`（`v9`）。

## extra-rootfs 里是什么

| 文件 | 说明 |
| --- | --- |
| `etc/config/dockerd` | Docker 的 UCI 配置：`storage_driver=btrfs`（根文件系统是 btrfs）、`data_root=/opt/docker`（最终是指向数据分区的符号链接）、只阻断 wan 方向 |
| `etc/init.d/data-partition` | 首次启动（S90）调用下面的脚本建数据分区 |
| `usr/sbin/setup-data-partition` | `sgdisk -e` 修正 GPT 备份头 → `sgdisk -n 3:0:0` 用剩余空间建第 3 分区 → `mkfs.btrfs -L DATA` → 挂 `/mnt/data` → `/opt/docker` 软链到 `/mnt/data/docker`，并写 fstab。幂等，可手动执行（可传 `/dev/mmcblk0`） |
| `usr/lib/lua/luci/i18n/easytier.zh-cn.lmo` | EasyTier LuCI 中文翻译（i18n ipk 与 app 包有文件冲突，只取翻译文件） |

## 版本说明

- **v7**：3 GiB rootfs，预装 Argon + Docker；
- **v8**：rootfs 直接做成 54 GiB（整盘镜像，刷写慢）；
- **v9（当前方案）**：rootfs 只 4 GiB，首次启动用 `setup-data-partition` 把 eMMC
  剩余空间建成 btrfs 的 `DATA` 分区并让 Docker 使用它。

> v7/v8 的镜像里当然没有 `setup-data-partition`——它是 v9 才引入的；早期版本的
> rootfs 是固定大小（3 GiB / 54 GiB），没有"剩余空间"这一步。
