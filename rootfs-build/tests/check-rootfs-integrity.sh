#!/usr/bin/env bash
# check-rootfs-integrity.sh —— 校验 rootfs.img 的文件系统完整性与校验值
#
# 用法: OUT=<镜像目录> bash check-rootfs-integrity.sh
#       （OUT 默认取当前目录；镜像名可用 IMG 指定）
set -uo pipefail

OUT="${OUT:-$PWD}"
IMG="${IMG:-$OUT/Armbian-unofficial_26.11.0-trunk_Xiaomi-umi_trixie_current_6.18.52_minimal.rootfs.img"}

[ -f "$IMG" ] || { echo "找不到 rootfs 镜像: $IMG"; echo "请用 IMG=<路径> 或 OUT=<目录> 指定"; exit 1; }

echo "=== 1. 文件系统完整性（只读检查，不修改）==="
e2fsck -fn "$IMG"
RC=$?
echo "e2fsck 返回码：$RC   （0 = 干净）"

echo
echo "=== 2. 重新计算 sha256 并与 .sha 文件比对 ==="
cd "$OUT"
sha256sum -c *.sha

echo
echo "=== 3. 确认关键文件确实在新镜像里 ==="
MNT=/mnt/umi-verify
mkdir -p "$MNT"
LOOP=$(losetup -f --show "$IMG")
mount -o ro "$LOOP" "$MNT"
ls -l "$MNT/usr/local/bin/battery-charge-limit" \
      "$MNT/usr/local/bin/panel-power" \
      "$MNT/usr/local/bin/panel-hold" \
      "$MNT/root/wifi-connect.sh"
echo "--- battery-charge-limit 是否含新版 decide() ---"
grep -c '^decide()' "$MNT/usr/local/bin/battery-charge-limit"
echo "--- 自启链接 ---"
ls -l "$MNT/etc/systemd/system/multi-user.target.wants/" | grep -E 'panel-off|battery-charge-limit'
umount "$MNT"
losetup -d "$LOOP"
