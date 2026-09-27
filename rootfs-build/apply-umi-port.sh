#!/bin/bash
# 把 umi 移植文件应用到 armbian/build 检出
#
# 用法：
#   ./apply-umi-port.sh /path/to/armbian/build
#   ./apply-umi-port.sh                      # 默认 ../armbian/build
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-../armbian/build}"

if [ ! -d "$DEST" ]; then
	echo "错误：找不到目录 $DEST" >&2
	echo "用法：$0 /path/to/armbian/build" >&2
	exit 1
fi

if [ ! -f "$DEST/compile.sh" ] || [ ! -d "$DEST/config/boards" ]; then
	echo "错误：$DEST 看起来不是 armbian/build 检出（缺少 compile.sh 或 config/boards）" >&2
	exit 1
fi

echo "==> 目标检出：$DEST"

# ---------------------------------------------------------------- 1. 板级配置
echo
echo "==> [1/5] 安装板级配置"
if [ -e "$DEST/config/boards/xiaomi-umi.conf" ]; then
	echo "    已存在同名板级配置，备份为 xiaomi-umi.conf.bak"
	cp -f "$DEST/config/boards/xiaomi-umi.conf" "$DEST/config/boards/xiaomi-umi.conf.bak"
fi
install -Dm644 "$SRC/config/boards/xiaomi-umi.conf" "$DEST/config/boards/xiaomi-umi.conf"
echo "    -> config/boards/xiaomi-umi.conf"

# ---------------------------------------------------------------- 2. 设备树
echo
echo "==> [2/5] 安装设备树"
FAMILY_CONF="$DEST/config/sources/families/sm8250.conf"
if [ ! -f "$FAMILY_CONF" ]; then
	echo "错误：$DEST 里没有 sm8250 family（config/sources/families/sm8250.conf）" >&2
	echo "      这个移植依赖官方 sm8250 family（它自带 qcom_fg / pm8150b_charger 补丁）" >&2
	exit 1
fi

CURRENT_KVER=$(awk '/^[[:space:]]*current\)/{f=1;next} f&&/KERNEL_MAJOR_MINOR/{print;exit}' "$FAMILY_CONF" \
	| sed -n 's/.*="\([0-9][0-9.]*\)".*/\1/p')
CURRENT_KVER="${CURRENT_KVER:-6.18}"
echo "    sm8250 family 的 current 内核版本：$CURRENT_KVER"

DT_DIR="$DEST/patch/kernel/archive/sm8250-$CURRENT_KVER/dt"
mkdir -p "$DT_DIR"

echo "    检查依赖补丁："
for pat in "0027-arm64-dts-qcom-pm8150b-Add-fuel-gauge.patch" \
           "0029-From-Teguh-Sobirin" \
           "0037-power-supply-qcom_pm8150b_charger-adds-charging-cont.patch" \
           "0038-arm64-dts-qcom-sm8250-oneplus-instantnoodlep-adds-us.patch" ; do
	if ls "$DEST/patch/kernel/archive/sm8250-$CURRENT_KVER/" 2>/dev/null | grep -q "$pat"; then
		echo "      OK  $pat"
	else
		echo "      !!  未找到 $pat —— 相关功能可能不可用"
	fi
done

for f in sm8250-xiaomi-umi-common.dtsi sm8250-xiaomi-umi-csot.dts sm8250-xiaomi-umi-sms.dts ; do
	install -Dm644 "$SRC/patch/kernel/archive/sm8250-6.18/dt/$f" "$DT_DIR/$f"
done
echo "    -> patch/kernel/archive/sm8250-$CURRENT_KVER/dt/sm8250-xiaomi-umi-{common.dtsi,csot.dts,sms.dts}"
echo "    （dt/ 里的文件会被 Armbian 自动复制到内核 arch/arm64/boot/dts/qcom/，"
echo "      Makefile 也会自动打补丁，不需要手写 Makefile 补丁）"

# ---------------------------------------------------------------- 3. BSP 脚本
echo
echo "==> [3/5] 安装 BSP 脚本"
install -Dm755 "$SRC/packages/bsp/xiaomi-umi/zz-update-abl-kernel" \
	"$DEST/packages/bsp/xiaomi-umi/zz-update-abl-kernel"
echo "    -> packages/bsp/xiaomi-umi/zz-update-abl-kernel"

if [ -d "$DEST/packages/bsp/usb-gadget-network" ]; then
	echo "    OK  公共包 packages/bsp/usb-gadget-network 存在"
else
	echo "    !!  缺少 packages/bsp/usb-gadget-network —— USB 网络共享会失败"
fi

# ---------------------------------------------------------------- 4. userpatches
echo
echo "==> [4/5] 安装 userpatches（扩展 + 镜像定制）"

install -Dm644 "$SRC/userpatches/extensions/umi-usb-host.sh" \
	"$DEST/userpatches/extensions/umi-usb-host.sh"
install -Dm644 "$SRC/userpatches/extensions/umi-firstboot.sh" \
	"$DEST/userpatches/extensions/umi-firstboot.sh"
install -Dm644 "$SRC/userpatches/extensions/umi-kernel-tweaks.sh" \
	"$DEST/userpatches/extensions/umi-kernel-tweaks.sh"
echo "    -> userpatches/extensions/umi-usb-host.sh      （USB host/键鼠 内核选项）"
echo "    -> userpatches/extensions/umi-firstboot.sh     （首次启动预设，root 密码=root）"
echo "    -> userpatches/extensions/umi-kernel-tweaks.sh （AppArmor 激活 + 服务器向选项）"

if [ -e "$DEST/userpatches/customize-image.sh" ]; then
	echo "    已存在 customize-image.sh，备份为 customize-image.sh.bak"
	cp -f "$DEST/userpatches/customize-image.sh" "$DEST/userpatches/customize-image.sh.bak"
fi
install -Dm755 "$SRC/userpatches/customize-image.sh" "$DEST/userpatches/customize-image.sh"
echo "    -> userpatches/customize-image.sh           （chroot 内：root 密码 / SSH / 工具）"

# overlay：chroot 里可以从 /tmp/overlay 访问，customize-image.sh 会把它拷到目标位置
if [ -d "$SRC/userpatches/overlay" ]; then
	mkdir -p "$DEST/userpatches/overlay"
	cp -a "$SRC/userpatches/overlay/." "$DEST/userpatches/overlay/"
	echo "    -> userpatches/overlay/root/wifi-connect.sh （WiFi 连接向导，装到 /root）"
fi

# ---------------------------------------------------------------- 5. 汇总
echo
echo "==> [5/5] 完成。改动清单："
echo "    config/boards/xiaomi-umi.conf"
echo "    patch/kernel/archive/sm8250-$CURRENT_KVER/dt/sm8250-xiaomi-umi-{common.dtsi,csot.dts,sms.dts}"
echo "    packages/bsp/xiaomi-umi/zz-update-abl-kernel"
echo "    userpatches/extensions/umi-usb-host.sh"
echo "    userpatches/extensions/umi-firstboot.sh"
echo "    userpatches/customize-image.sh"
echo
echo "下一步构建（在 $DEST 里执行）："
echo
echo "  ./compile.sh build \\"
echo "      BOARD=xiaomi-umi BRANCH=current RELEASE=trixie \\"
echo "      BUILD_MINIMAL=yes BUILD_DESKTOP=no KERNEL_CONFIGURE=no \\"
echo "      ENABLE_EXTENSIONS=\"docker-ce umi-usb-host umi-firstboot\" EXPERT=yes"
echo
echo "详见 BUILD.md"
