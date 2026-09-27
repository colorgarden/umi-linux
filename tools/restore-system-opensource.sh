#!/usr/bin/env bash
# ============================================================
#  restore-system-opensource.sh —— 还原「干净整机系统镜像」
# ============================================================
#  镜像内容：设备 rootfs（Debian 13）本体
#    · 包含：内核模块 / 项目自加服务（panel-off、umi-venus-enable、umi-put、
#            umi-bcb-early、umi-gpu-maxfreq、battery-charge-limit、cpupower…）、
#            Mesa/Turnip/Vulkan、Venus 固件、/data 下的保命标志位
#    · 不含：宝塔面板（/www）、Docker/containerd（镜像与容器）、及其服务单元
#
#  ⚠️ 破坏性操作：
#     - 必须在 TWRP 恢复模式下运行（Linux 运行中不可覆盖根分区）
#     - 会**整个覆盖** userdata 分区（/dev/sda34，即 Debian 根）
#       → 现有系统的全部数据（含宝塔面板与 Docker 数据）都会消失
#     - 绝不碰 modemst/fsg/fsc/persist 等基带分区
#
#  用法: bash restore-system-opensource.sh
# ============================================================
set -euo pipefail
export MSYS_NO_PATHCONV=1

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAR="$DIR/../rootfs/umi-system-opensource-2026-09-27.tar.gz"
WANT="51f4b38d23b71d7d70b7472b3ef95e673c0e984f1f7c489c75305fc4fb2d645f"

# ---- adb 可配置：环境变量 ADB > PATH 里的 adb > MiFlash 自带 ----
ADB="${ADB:-}"
if [ -z "$ADB" ]; then
    if command -v adb >/dev/null 2>&1; then
        ADB="$(command -v adb)"
    elif [ -x "E:/data/mi10/MiFlash2020-3-14-0/Source/ThirdParty/Google/Android/adb.exe" ]; then
        ADB="E:/data/mi10/MiFlash2020-3-14-0/Source/ThirdParty/Google/Android/adb.exe"
    fi
fi
[ -n "$ADB" ] && [ -x "$ADB" ] || {
    echo "[X] 找不到 adb。请指定后再跑：  ADB=/path/to/adb bash $0"
    exit 1
}

say() { printf '\n=== %s\n' "$*"; }
die() { printf '\n[X] %s\n' "$*" >&2; exit 1; }

say "0/5  本地校验"
[ -f "$TAR" ] || die "找不到 $TAR"
GOT=$(sha256sum "$TAR" | awk '{print $1}')
[ "$GOT" = "$WANT" ] || die "本地 sha256 不匹配！期望 $WANT，实际 $GOT"
echo "本地镜像校验通过: $GOT  ($(stat -c%s "$TAR") B)"

cat <<'EOF'

⚠️  警告：即将**整盘覆盖**设备根文件系统（/dev/sda34 = userdata）。
    当前系统上的所有数据都会消失 —— 包括宝塔面板 /www 与 Docker 容器数据
    （这份镜像本来就是按"不含这些"导出的）。
    只读/需要保留的东西请先拷出来。

EOF
printf '确定继续？输入 yes 回车: '
read -r ANS
[ "$ANS" = "yes" ] || die "已取消，未做任何更改。"

say "1/5  检测设备（必须在 TWRP 模式）"
[ -x "$ADB" ] || die "找不到 adb: $ADB"
"$ADB" devices
STATE=$("$ADB" get-state 2>/dev/null || echo unknown)
[ "$STATE" = "recovery" ] || die "当前 adb 状态为 $STATE（非 recovery）。请重启至 TWRP 后再运行！"

say "2/5  推送镜像到设备 (2.1 GiB)…"
"$ADB" push "$TAR" /data/local/tmp/umi-system-opensource.tar.gz

say "3/5  设备端 sha256 复校"
DEV_SHA=$("$ADB" shell "sha256sum /data/local/tmp/umi-system-opensource.tar.gz" | awk '{print $1}' | tr -d '\r')
echo "设备端: $DEV_SHA"
[ "$DEV_SHA" = "$WANT" ] || die "设备端校验不一致，已中止，未覆盖任何数据！"

say "4/5  解包覆盖 rootfs"
"$ADB" shell "mount /data 2>/dev/null || true"
"$ADB" shell "tar xzf /data/local/tmp/umi-system-opensource.tar.gz -C /data --numeric-owner -p" || die "解包失败"
echo "解包完成"

say "5/5  校验关键文件 + 恢复保命标志 + 清理"
"$ADB" shell "for f in /data/etc/passwd /data/etc/systemd/system/umi-venus-enable.service /data/etc/systemd/system/panel-off.service /data/etc/systemd/system/umi-gpu-maxfreq.service /data/lib/firmware/qcom/sm8250/a650_zap.mbn /data/usr/local/sbin/umi-gpu-maxfreq.sh; do [ -e \$f ] && echo \"  [OK] \$f\" || echo \"  [!!] 缺失 \$f\"; done"
"$ADB" shell "for f in /data/www /data/var/lib/docker /data/var/lib/containerd; do [ -e \$f ] && echo \"  [!!] \$f 不该存在\" || echo \"  [OK] \$f 已按预期不含\"; done"
"$ADB" shell "mkdir -p /data/data && touch /data/data/AUTO_RECOVERY_OFF"
"$ADB" shell "rm -f /data/local/tmp/umi-system-opensource.tar.gz"

echo
echo "============================================================"
echo " 系统还原完成。配套 Boot 镜像请刷："
echo "   boot/boot-umi-csot-ovf-wifi6-gpu-oc-final.img"
echo "   （fastboot flash boot <该文件>）"
echo " 并用原厂 dtbo：fastboot flash dtbo <你底包>/images/dtbo.img"
echo " 开机后首启必做：passwd / passwd -l armbian / bash /root/wifi-connect.sh"
echo "============================================================"
