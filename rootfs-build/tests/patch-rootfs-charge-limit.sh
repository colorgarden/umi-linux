#!/usr/bin/env bash
#
# patch-rootfs-charge-limit.sh —— 把更新后的 battery-charge-limit 直接写进已有的
# rootfs.img（不重建整个镜像），并当场用单测验证写入结果。
#
# 在 WSL 里以 root 运行：
#   sudo OUT=<镜像目录> bash patch-rootfs-charge-limit.sh
#   （OUT 默认取当前目录，可覆盖；NEW/TEST 也可用环境变量覆盖）
#
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="$(cd "$SELF/.." && pwd)"           # 本移植包根目录
BASE="${BASE:-$PWD}"
OUT="${OUT:-$BASE/output}"
IMG="${IMG:-$OUT/Armbian-unofficial_26.11.0-trunk_Xiaomi-umi_trixie_current_6.18.52_minimal.rootfs.img}"
NEW="${NEW:-$PORT/userpatches/overlay/usr/local/bin/battery-charge-limit}"
TEST="${TEST:-$SELF/test-charge-limit.sh}"
MNT=/mnt/umipatch

say() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31m错误：%s\033[0m\n' "$*" >&2; exit 1; }

[ -f "$IMG" ] || die "找不到 $IMG"
[ -f "$NEW" ] || die "找不到 $NEW"

say "0. 前置信息"
ls -l "$IMG"
echo "新脚本 sha256: $(sha256sum "$NEW" | cut -d' ' -f1)"

# ---------------------------------------------------------------- 文件系统探测
say "1. 探测文件系统"
MAGIC=$(dd if="$IMG" bs=1 skip=1080 count=2 2>/dev/null | od -A n -t x1 | tr -d ' \n')
echo "offset 0x438 魔数: [$MAGIC]（ext2/3/4 应为 53ef）"

OFFSET=0
if [ "$MAGIC" != "53ef" ]; then
	echo "偏移 0 不是 ext 超级块，尝试找分区表…"
	sfdisk -l "$IMG" 2>/dev/null || true
	# 常见情况：整盘镜像 + 分区。取第一个 Linux 分区的起点（扇区 → 字节）
	START=$(sfdisk -l -o Start,Type "$IMG" 2>/dev/null | awk '$2 ~ /^83$/ {print $1; exit}')
	[ -n "${START:-}" ] || die "没找到 ext 超级块，也解析不出 Linux 分区"
	OFFSET=$(( START * 512 ))
	echo "使用偏移：$OFFSET 字节（起始扇区 $START）"
fi

# ---------------------------------------------------------------- 挂载
say "2. 挂载（只读先看）"
mkdir -p "$MNT"
LOOP=$(losetup -f --show -o "$OFFSET" "$IMG")
echo "loop 设备：$LOOP"
cleanup() {
	umount "$MNT" 2>/dev/null || true
	losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

mount -o ro "$LOOP" "$MNT"
echo "--- 目标文件现状 ---"
ls -l "$MNT/usr/local/bin/battery-charge-limit"
echo "旧脚本 sha256: $(sha256sum "$MNT/usr/local/bin/battery-charge-limit" | cut -d' ' -f1)"
echo "--- 相关文件 ---"
ls -l "$MNT/etc/systemd/system/battery-charge-limit.service" \
      "$MNT/etc/default/battery-charge-limit" 2>&1 || true

umount "$MNT"

# ---------------------------------------------------------------- 可写挂载并替换
say "3. 可写挂载并替换"
mount -o rw "$LOOP" "$MNT"
install -Dm755 "$NEW" "$MNT/usr/local/bin/battery-charge-limit"
sync
echo "写入后 sha256: $(sha256sum "$MNT/usr/local/bin/battery-charge-limit" | cut -d' ' -f1)"

say "4. 就地跑单测（纯 bash，与架构无关）"
if bash "$TEST" "$MNT/usr/local/bin/battery-charge-limit"; then
	echo "单测通过 ✅"
else
	die "单测失败，已中止（镜像未同步）—— 请勿把这次改动当成生效"
fi

say "5. 顺带核对 systemd 单元与默认配置"
echo "--- battery-charge-limit.service ---"
cat "$MNT/etc/systemd/system/battery-charge-limit.service"
echo "--- /etc/default/battery-charge-limit ---"
cat "$MNT/etc/default/battery-charge-limit" 2>/dev/null || echo "(不存在)"
echo "--- 是否已 enable ---"
ls -l "$MNT/etc/systemd/system/multi-user.target.wants/" 2>/dev/null | grep -i battery || \
	echo "(multi-user.target.wants 里没有 battery，稍后确认 WantedBy)"

sync
umount "$MNT"
losetup -d "$LOOP"
trap - EXIT

say "6. 重新生成校验值"
cd "$OUT"
for f in *.img; do
	sha256sum "$f" > "$f.sha"
done
cat *.sha

say "完成 ✅"
echo "rootfs.img 已更新为含新版 battery-charge-limit 的版本（文件名未变，校验值已更新）"
