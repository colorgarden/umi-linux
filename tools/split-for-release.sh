#!/usr/bin/env bash
# ============================================================
#  split-for-release.sh —— 把大文件拆成可上传的分片
# ============================================================
#  为什么需要：GitHub 对**单个 Release 附件**上限 2 GiB。
#  本项目的整机镜像 tar.gz ≈ 1.98 GiB，余量只剩 ~22 MiB，
#  一旦超过就必须拆分上传。
#
#  用法:
#     bash split-for-release.sh <文件> [每片大小]
#     例: bash split-for-release.sh rootfs/umi-system-opensource-2026-09-27.tar.gz
#         bash split-for-release.sh rootfs/*.tar.gz 300M
#
#  产物: <文件所在目录>/parts/<文件名>.part-aa, -ab, ...
#        以及 parts/<文件名>.parts.sha256（分片的校验清单）
#
#  下载方合并方式:
#     cat <文件名>.part-* > <文件名>
#     sha256sum -c SHA256SUMS.txt      # 校验原始文件
# ============================================================
set -euo pipefail

FILE="${1:-}"
SIZE="${2:-500M}"

die() { printf '\n[X] %s\n' "$*" >&2; exit 1; }

[ -n "$FILE" ] || die "用法: bash split-for-release.sh <文件> [每片大小，默认 500M]"
[ -f "$FILE" ] || die "找不到文件: $FILE"

DIR="$(cd "$(dirname "$FILE")" && pwd)"
BASE="$(basename "$FILE")"
OUT="$DIR/parts"

rm -rf "$OUT"; mkdir -p "$OUT"

echo "=== 拆分 $FILE"
echo "    每片大小: $SIZE"
echo "    输出目录: $OUT"

# 记下原始文件的 sha256，供合并后核对
ORIG_SHA=$(sha256sum "$FILE" | awk '{print $1}')
ORIG_SIZE=$(stat -c%s "$FILE")

split -b "$SIZE" -d -a 2 "$FILE" "$OUT/$BASE.part-"

cd "$OUT"
sha256sum "$BASE".part-* > "$BASE.parts.sha256"

{
    echo "# 分片清单 —— $BASE"
    echo "# 原始文件大小 : $ORIG_SIZE B"
    echo "# 原始文件 sha256: $ORIG_SHA"
    echo "# 每片大小     : $SIZE"
    echo "# 合并命令     : cat $BASE.part-* > $BASE"
    echo "# 合并后校验   : sha256sum $BASE   # 应等于上面的 sha256"
} > "$BASE.README.txt"

echo
echo "完成。分片："
ls -l "$OUT" | sed 's/^/  /'
echo
echo "合并后请核对 sha256 = $ORIG_SHA"
