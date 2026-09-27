#!/bin/bash
#
# 在 WSL 里一键构建小米10 (umi) 的 Armbian minimal 镜像
#
# 用法（在 WSL 的 Ubuntu 里执行）：
#     bash <本脚本路径>
#
# 可选环境变量：
#     PORT_DIR   移植包目录（默认为本脚本所在目录）
#     BUILD_DIR  armbian/build 检出位置（默认 ~/armbian-build）
#     RELEASE    发行版（默认 trixie，可改 noble）
#     BRANCH     内核分支（默认 current = 6.18 LTS，可改 edge = 6.19）
#
set -euo pipefail

PORT_DIR="${PORT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
BUILD_DIR="${BUILD_DIR:-$HOME/armbian-build}"
RELEASE="${RELEASE:-trixie}"
BRANCH="${BRANCH:-current}"

echo "============================================================"
echo " 小米10 (umi) Armbian 镜像构建"
echo "============================================================"
echo "  移植包   : $PORT_DIR"
echo "  构建目录 : $BUILD_DIR"
echo "  发行版   : $RELEASE"
echo "  内核分支 : $BRANCH"
echo "============================================================"
echo

# ---------------------------------------------------------------- 前置检查
if [ "$(id -u)" -eq 0 ]; then
	echo "!! 不要用 root 跑 Armbian 构建（它自己会用 sudo）。请用普通用户执行。" >&2
	exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
	echo "!! 没有 sudo，无法继续。" >&2
	exit 1
fi

if [ ! -f "$PORT_DIR/apply-umi-port.sh" ]; then
	echo "!! 找不到移植包：$PORT_DIR/apply-umi-port.sh" >&2
	echo "   如果路径不同，用 PORT_DIR=/your/path 指定。" >&2
	exit 1
fi

# 提示：不要在 /mnt 下构建（跨文件系统极慢且 chroot 会出问题）
case "$BUILD_DIR" in
	/mnt/*)
		echo "!! BUILD_DIR 不能放在 /mnt 下（Windows 文件系统），会非常慢且可能失败。" >&2
		echo "   请改成 Linux 文件系统内的路径，例如 \$HOME/armbian-build" >&2
		exit 1
		;;
esac

# 磁盘空间检查（构建需要 ~50GB）
AVAIL_GB=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
echo "==> 可用空间：${AVAIL_GB} GB"
if [ "${AVAIL_GB:-0}" -lt 45 ]; then
	echo "!! 空间不足 45 GB，构建很可能中途失败。" >&2
	echo "   可以先清理： sudo apt clean; rm -rf $BUILD_DIR" >&2
	exit 1
fi

# ---------------------------------------------------------------- 1. 依赖
echo
echo "==> [1/4] 安装构建依赖"
sudo apt-get update -qq
sudo apt-get install -y \
	git curl wget ca-certificates \
	build-essential bc bison flex \
	device-tree-compiler \
	qemu-user-static binfmt-support \
	zstd xz-utils \
	python3 python3-pip \
	rsync unzip zip \
	uuid-runtime \
	|| { echo "!! 依赖安装失败" >&2; exit 1; }

# ---------------------------------------------------------------- 2. 检出
echo
echo "==> [2/4] 检出 armbian/build"
if [ -d "$BUILD_DIR/.git" ]; then
	echo "    已存在，执行 git pull 更新"
	git -C "$BUILD_DIR" pull --ff-only || echo "    更新失败（不影响使用现有版本）"
else
	# 用完整克隆（不是 --depth 1）：构建过程需要切分支/tag
	git clone https://github.com/armbian/build.git "$BUILD_DIR"
fi

echo
echo "    sm8250 family 的内核版本："
grep -A2 '^	current)' "$BUILD_DIR/config/sources/families/sm8250.conf" | grep KERNEL_MAJOR_MINOR || true

# ---------------------------------------------------------------- 3. 应用移植
echo
echo "==> [3/4] 应用 umi 移植"
bash "$PORT_DIR/apply-umi-port.sh" "$BUILD_DIR"

# ---------------------------------------------------------------- 4. 构建
echo
echo "==> [4/4] 开始构建（首次约 1~2 小时，请耐心等待）"
echo

cd "$BUILD_DIR"

./compile.sh build \
	BOARD=xiaomi-umi \
	BRANCH="$BRANCH" \
	RELEASE="$RELEASE" \
	BUILD_MINIMAL=yes \
	BUILD_DESKTOP=no \
	KERNEL_CONFIGURE=no \
	ENABLE_EXTENSIONS="docker-ce umi-usb-host umi-firstboot" \
	EXPERT=yes \
	2>&1 | tee "$HOME/umi-build.log"

echo
echo "============================================================"
echo " 构建结束"
echo "============================================================"
echo
echo "产物（在 $BUILD_DIR/output/images/）："
ls -lh "$BUILD_DIR/output/images/" 2>/dev/null | grep -i umi || echo "  （没有找到 umi 产物，请检查 $HOME/umi-build.log）"
echo
echo "刷机提示："
echo "  boot 镜像  -> fastboot flash boot  <..._boot_sm8250-xiaomi-umi-csot.img>"
echo "  rootfs     -> fastboot flash userdata <..._minimal.rootfs.img>"
echo "  （本机面板是 CSOT，所以用 csot 那个）"
echo
echo "完整日志：$HOME/umi-build.log"
