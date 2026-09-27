#!/usr/bin/env bash
# ============================================================
#  publish-release.sh —— 把本发布的产物发到 releases 仓库（GitHub Release）
# ============================================================
#  安全设计：**默认 dry-run**，只打印将执行的命令；加 --yes 才真的发布。
#
#  用法:
#     REPO=<owner>/<repo> bash publish-release.sh <tag>            # 预览
#     REPO=<owner>/<repo> bash publish-release.sh <tag> --yes      # 真发
#
#     例: REPO=misaka/umi-linux bash publish-release.sh v2026-09-27
#
#  前置:
#     · 装好 gh（GitHub CLI）并 gh auth login
#     · 已重算 SHA256SUMS.txt（见 docs/04-发布与下载.md §三）
#     · 若单个附件 > 2 GiB，先跑 tools/split-for-release.sh 拆分
#
#  做的事:
#     1) 校验产物存在 + sha256 与脚本内记录一致
#     2) git tag（可选，--no-tag 跳过）
#     3) gh release create，把 boot / rootfs / SHA256SUMS / RELEASE-NOTES 作为附件
# ============================================================
set -euo pipefail
export MSYS_NO_PATHCONV=1

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REL="$(cd "$DIR/.." && pwd)"

TAG="${1:-}"
CONFIRM="${2:-}"
REPO="${REPO:-misaka-link/umi-linux}"
TITLE="${TITLE:-UmiLinux $TAG}"

BOOT="$REL/boot/boot-umi-csot-ovf-wifi6-gpu-oc-final.img"
ROOTFS="$REL/rootfs/umi-system-opensource-2026-09-27.tar.gz"
SUMS="$REL/SHA256SUMS.txt"
NOTES="$REL/docs/RELEASE-NOTES.md"

BOOT_SHA="a7e4d341e35a663683bf41a8fe99d472bc6b8568aa1b54b05901dc7e9f2d842a"
ROOTFS_SHA="51f4b38d23b71d7d70b7472b3ef95e673c0e984f1f7c489c75305fc4fb2d645f"
GITHUB_ASSET_LIMIT=2147483648        # 2 GiB / 附件

say() { printf '\n=== %s\n' "$*"; }
die() { printf '\n[X] %s\n' "$*" >&2; exit 1; }

[ -n "$TAG" ] || die "用法: bash publish-release.sh <tag> [--yes]    例: bash publish-release.sh v2026-09-27 --yes
  仓库默认 $REPO，可用 REPO=<owner>/<repo> 覆盖。"

say "1/4  校验产物"
for f in "$BOOT" "$ROOTFS" "$SUMS" "$NOTES"; do
    [ -f "$f" ] || die "找不到: $f"
done

check_sha() {
    local f="$1" want="$2" name="$3"
    local got; got=$(sha256sum "$f" | awk '{print $1}')
    if [ "$got" = "$want" ]; then
        echo "  ✓ $name  sha256 一致"
    else
        echo "  ✗ $name  sha256 不一致！"
        echo "      期望 $want"
        echo "      实际 $got"
        echo "      若你确实改过内容，请同步更新本脚本里的常量与 docs/04-发布与下载.md"
        return 1
    fi
}
check_sha "$BOOT"   "$BOOT_SHA"   "$(basename "$BOOT")"   || die "产物被改动过，已中止"
check_sha "$ROOTFS" "$ROOTFS_SHA" "$(basename "$ROOTFS")" || die "产物被改动过，已中止"

# 尺寸检查（GitHub 单附件 2 GiB 上限）
for f in "$BOOT" "$ROOTFS"; do
    sz=$(stat -c%s "$f")
    if [ "$sz" -gt "$GITHUB_ASSET_LIMIT" ]; then
        die "$(basename "$f") 有 $((sz/1024/1024)) MiB，超过 GitHub 单附件 2 GiB 上限。
  请先拆分：bash tools/split-for-release.sh \"$f\"
  并按 docs/04-发布与下载.md 的说明改为上传分片。"
    fi
done
echo "  ✓ 尺寸都在 GitHub 单附件上限内（rootfs 余量 $(( (GITHUB_ASSET_LIMIT - $(stat -c%s "$ROOTFS")) /1024/1024 )) MiB）"

say "2/4  发布计划"
cat <<EOF
  仓库    : $REPO
  Tag     : $TAG
  标题    : $TITLE
  附件    :
    $(basename "$BOOT")      ($(stat -c%s "$BOOT") B)
    $(basename "$ROOTFS")    ($(stat -c%s "$ROOTFS") B)
    SHA256SUMS.txt
  说明文件: docs/RELEASE-NOTES.md
EOF

if [ "$CONFIRM" != "--yes" ]; then
    say "DRY-RUN（没有做任何改动）"
    cat <<EOF
确认无误后加 --yes 真发：

  REPO=$REPO bash tools/publish-release.sh $TAG --yes

它会执行：
  gh release create $TAG \\
      "$BOOT" "$ROOTFS" "$SUMS" \\
      --repo $REPO --title "$TITLE" --notes-file "$NOTES"
EOF
    exit 0
fi

say "3/4  检查 gh"
command -v gh >/dev/null 2>&1 || die "没装 gh（GitHub CLI）。装好并 gh auth login 后再来。"
gh auth status >/dev/null 2>&1 || die "gh 未登录，先跑 gh auth login"

say "4/4  创建 Release 并上传"
gh release create "$TAG" \
    "$BOOT" "$ROOTFS" "$SUMS" \
    --repo "$REPO" \
    --title "$TITLE" \
    --notes-file "$NOTES"

echo
echo "完成。下载页： https://github.com/$REPO/releases/tag/$TAG"
