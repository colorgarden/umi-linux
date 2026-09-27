#!/usr/bin/env bash
# ============================================================
#  build-boot.sh —— 从 DTS 源重建 boot 镜像
# ============================================================
#  用法:
#     bash build-boot.sh [基底boot.img] [输出boot.img]
#
#   不传参数时：以本发布自带的成品 boot 镜像为基底、编译 dtb/ 里的当前 DTS，
#   产物应当与官方成品**逐字节一致**（sha256 a7e4d341…）—— 这是可复现性自检。
#
#  做的事:
#     1) 前置检查（dtc / fdtget / python3 / sha256sum）
#     2) 校验基底镜像是 Android boot header v2（有独立 dtb 段）
#     3) dtc -@ 编译 DTS  →  DTB      （★ -@ 必须有，否则没有 __symbols__）
#     4) 校验 DTB：__symbols__.arch_timer / abl_ovf 锚点数 / model
#     5) replace-dtb.py 只替换 boot 镜像的 dtb 段（kernel / ramdisk 逐字节不动）
#     6) 打印 sha256，并与官方成品对比
#
#  ⚠️ 本脚本只产出 boot.img，不写任何分区。
# ============================================================
set -euo pipefail
export MSYS_NO_PATHCONV=1

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REL="$(cd "$DIR/.." && pwd)"

DTS="${DTS:-$REL/dtb/slim-ovf-wifi6-gpu-oc-final.dts}"
BASE="${1:-$REL/boot/boot-umi-csot-ovf-wifi6-gpu-oc-final.img}"
OUT="${2:-$DIR/out/boot-rebuilt.img}"
OUTDIR="$DIR/out"
DTB_OUT="$OUTDIR/rebuilt.dtb"
LOG="$OUTDIR/dtc.log"

EXPECT_DTB="b0e48ef96880567160182be4d31dc5721fa33ce3b3551909388b8e50612a99c2"
EXPECT_BOOT="a7e4d341e35a663683bf41a8fe99d472bc6b8568aa1b54b05901dc7e9f2d842a"
MIN_ANCHORS=152

say() { printf '\n=== %s\n' "$*"; }
die() { printf '\n[X] %s\n' "$*" >&2; exit 1; }

say "1/6  前置检查"
for t in dtc fdtget python3 sha256sum; do
    command -v "$t" >/dev/null 2>&1 || die "缺少工具: $t
  Debian/Ubuntu/WSL: sudo apt install device-tree-compiler python3
  Windows 用户建议在 WSL 里跑本脚本"
done
[ -f "$DTS" ] || die "找不到 DTS: $DTS"
[ -f "$BASE" ] || die "找不到基底 boot 镜像: $BASE"
echo "DTS   : $DTS"
echo "基底  : $BASE  ($(stat -c%s "$BASE") B)"
echo "输出  : $OUT"
echo "dtc   : $(dtc --version 2>&1 | head -1)"

# ---- header 版本检查 ----
# Android boot header 的 header_version 在偏移 40。
# 上游 Armbian 原始镜像多为 v0（DTB 追加在 kernel.gz 之后，没有独立 dtb 段），
# 而 replace-dtb.py 需要 v2。
HDR=$(od -An -tu4 -j 40 -N 4 "$BASE" 2>/dev/null | tr -d ' ')
if [ "$HDR" != "2" ]; then
    die "基底镜像是 header v${HDR:-?}，不是 v2（缺独立 dtb 段），replace-dtb.py 用不了。

  两条路：
  A) 用本发布自带的成品 boot 镜像当基底（它已经是 v2，改 DTB 迭代最方便）：
       bash build-boot.sh \"$REL/boot/boot-umi-csot-ovf-wifi6-gpu-oc-final.img\"

  B) 从上游 Armbian v0 基线从零来 —— 先用重打包器转成 v2：
       python3 \"$DIR/tools/rebuild-boot.py\" \\
           --src <Armbian基线boot.img> --out /tmp/v2.img --slim --disable-dsp --ramoops
     再把 /tmp/v2.img 当第 1 个参数传进来。"
fi
echo "header: v2  ✓"

mkdir -p "$OUTDIR"

say "2/6  dtc -@ 编译 DTS"
if ! dtc -@ -I dts -O dtb -o "$DTB_OUT" "$DTS" 2>"$LOG"; then
    cat "$LOG"; die "dtc 编译失败"
fi
if grep -qiE '\b(error|fatal)' "$LOG"; then
    echo "[!] dtc 报告了 error，请检查 $LOG"; cat "$LOG"; exit 1
fi
echo "DTB 已生成: $(stat -c%s "$DTB_OUT") B   （warning 可忽略，见 $LOG）"

say "3/6  校验 DTB（ABL overlay 能否应用的前提）"
SYM=$(fdtget "$DTB_OUT" /__symbols__ arch_timer 2>/dev/null || echo "")
[ "$SYM" = "/timer" ] || die "__symbols__.arch_timer 解析失败（得到 '$SYM'）—— 十有八九忘了 dtc -@"
ANCHORS=$(fdtget -l "$DTB_OUT" /abl_ovf 2>/dev/null | wc -l)
[ "$ANCHORS" -ge "$MIN_ANCHORS" ] || die "abl_ovf 锚点数不足（$ANCHORS < $MIN_ANCHORS）。
  ABL 的 dtbo overlay 会应用失败 → 设备秒进 fastboot。"
MODEL=$(fdtget "$DTB_OUT" / model 2>/dev/null || echo "")
echo "  __symbols__.arch_timer = $SYM  ✓"
echo "  abl_ovf 锚点数         = $ANCHORS  (需要 >= $MIN_ANCHORS)  ✓"
echo "  model                  = $MODEL"

DTB_SHA=$(sha256sum "$DTB_OUT" | awk '{print $1}')
if [ "$DTB_SHA" = "$EXPECT_DTB" ]; then
    echo "  DTB sha256 与随包 DTB 一致  ✓  ($DTB_SHA)"
else
    echo "  DTB sha256 = $DTB_SHA"
    echo "  （与随包 DTB $EXPECT_DTB 不同 → 说明你改了 DTS，或 dtc 版本差异较大，正常）"
fi

say "4/6  替换 boot 镜像的 dtb 段"
python3 "$DIR/tools/replace-dtb.py" "$BASE" "$DTB_OUT" "$OUT"

say "5/6  结果"
SHA=$(sha256sum "$OUT" | awk '{print $1}')
echo "输出镜像 : $OUT"
echo "大小     : $(stat -c%s "$OUT") B"
echo "sha256   : $SHA"
if [ "$SHA" = "$EXPECT_BOOT" ]; then
    echo
    echo "✅ 与官方成品 boot 镜像**逐字节一致** —— 构建链可复现，未被污染。"
else
    echo
    echo "ℹ️  与官方成品不同（你确实改了东西，或 dtc 版本差异）。"
    echo "    若要发版，请把新的 sha256 同步到 SHA256SUMS.txt 与发布说明。"
fi

say "6/6  下一步"
cat <<EOF
刷机（只写 boot 分区，绝不碰基带）：
  adb reboot bootloader
  fastboot flash boot "$OUT"
  fastboot reboot

回滚：重新刷回随包的官方 boot
  fastboot flash boot "$REL/boot/boot-umi-csot-ovf-wifi6-gpu-oc-final.img"
EOF
