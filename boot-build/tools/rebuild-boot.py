#!/usr/bin/env python3
"""重打包 umi 的 boot 镜像：initrd 瘦身 + dtb 地址调整 + cmdline 重写 + ramoops 注入。

为什么需要它：
  - umi 的 initrd 里塞了**小米平板 5（elish）的 remoteproc 固件**
    （adsp.mbn 18.5MB + slpi.mbn 7.4MB + cdsp.mbn 5.8MB，共约 31.7MB 未压缩），
    导致 ramdisk 压缩后仍有 30.7MB，而 header 里 `dtb_addr = 0x1f00000`（31MB）
    只按 Android 惯例留了 15MB 空隙 → DTB 会被写进 initramfs 中段。
  - 无头服务器用不到音频/传感器 DSP，删掉这些固件既解决地址重叠，又能加快启动。

做的事（内核与 rootfs 完全不动）：
  1. 解包 ramdisk（gzip + cpio newc），按规则过滤条目（保留原始条目字节，只做裁剪）
  2. 重新压缩（gzip, mtime=0，输出可复现）
  3. 可选：DTB 注入 ramoops 节点（失败时能捞日志）
  4. 重写 cmdline
  5. 按 v2 header 重新打包，并把 `dtb_addr` 挪到与 ramdisk 不相交的位置

用法:
  # 先看看里面有什么
  python tools/rebuild-boot.py --src <boot.img> --list

  # 生成瘦身版
  python tools/rebuild-boot.py \
      --src output/Armbian-...csot.img \
      --out output/boot-umi-csot-slim.img \
      --strip-elish --ramoops --dtb-addr 0x4000000
"""

import argparse
import fnmatch
import gzip
import importlib.util
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

GZIP_MAGIC = b"\x1f\x8b"
ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"
LZ4_MAGIC = b"\x02\x21\x4c\x18"

# 无头服务器用不到的 elish 固件（删掉可显著缩小 initrd）
ELISH_STRIP = (
    "usr/lib/firmware/qcom/sm8250/xiaomi/elish/adsp.mbn",
    "usr/lib/firmware/qcom/sm8250/xiaomi/elish/slpi.mbn",
    "usr/lib/firmware/qcom/sm8250/xiaomi/elish/cdsp.mbn",
)

# --slim 预设：删掉在 ARM 手机上永远用不到的硬件资源。
# 实测 initrd 87.5MiB 里有 16.6MiB 是这类东西，直接吃掉 dtb_addr 的安全空隙。
SLIM_GLOBS = (
    # 小米平板5(elish)的音频/传感器/计算 DSP 固件（约 31.7MiB）
    "usr/lib/firmware/qcom/sm8250/xiaomi/elish/adsp.mbn",
    "usr/lib/firmware/qcom/sm8250/xiaomi/elish/slpi.mbn",
    "usr/lib/firmware/qcom/sm8250/xiaomi/elish/cdsp.mbn",
    # udev 硬件库（13.5MiB）——initramfs 阶段用不到，rootfs 里还有一份
    "usr/lib/udev/hwdb.bin",
    # Intel 服务器网卡驱动与固件（ice/i40e/ixgbe/igb/e1000e…，约 5.4MiB）
    "usr/lib/firmware/intel/ice/*",
    "usr/lib/modules/*/kernel/drivers/net/ethernet/intel/*",
    # LSI/Broadcom SAS 阵列卡（0.6MiB）
    "usr/lib/modules/*/kernel/drivers/scsi/mpt3sas/*",
    # btrfs（initramfs 用不到；根分区是 ext4，rootfs 里另有完整工具）
    "usr/lib/modules/*/kernel/fs/btrfs/*",
)


def load_mkdiag():
    """复用 mk-diag-boot.py 里的 Fdt / boot image 读写 / ramoops 注入。"""
    spec = importlib.util.spec_from_file_location(
        "mkdiag", os.path.join(HERE, "mk-diag-boot.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def align4(n):
    return (n + 3) & ~3


FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9


def parse_all_nodes(f):
    """把 Fdt 的 struct_blk 一次性解析成 {节点路径: {属性名: 值}}。"""
    sb, strings = f.struct_blk, f.strings_blk
    pos, names, curstack, nodes = 0, [], [], {}
    cur = None
    while pos < len(sb):
        tok = struct.unpack_from(">I", sb, pos)[0]
        pos += 4
        if tok == FDT_BEGIN_NODE:
            e = sb.find(b"\x00", pos)
            name = sb[pos:e].decode("utf-8", "replace")
            pos = (e + 4) & ~3
            names.append(name)
            path = "/" + "/".join(x for x in names if x)
            d = nodes.setdefault(path, {})
            curstack.append(cur)
            cur = d
        elif tok == FDT_END_NODE:
            if names:
                names.pop()
            cur = curstack.pop() if curstack else None
        elif tok == FDT_PROP:
            ln, noff = struct.unpack_from(">II", sb, pos)
            pos += 8
            e2 = strings.find(b"\x00", noff)
            pname = strings[noff:e2].decode("utf-8", "replace")
            if cur is not None:
                cur[pname] = bytes(sb[pos:pos + ln])
            pos = (pos + ln + 3) & ~3
        elif tok == FDT_NOP:
            pass
        elif tok == FDT_END:
            break
    return nodes


def fdt_set_prop(f, path, name, value):
    """设置/新增节点属性，允许值长度变化（先删旧的，再在属性区末尾插入新的）。"""
    tok_off = f.find_node_token_offset(path)
    pos = tok_off + 4
    e = f.struct_blk.find(b"\x00", pos)
    pos = (e + 4) & ~3                      # 属性区起点

    target_pos = target_len = None
    scan = pos
    while True:
        tok = struct.unpack_from(">I", f.struct_blk, scan)[0]
        if tok == FDT_PROP:
            ln, noff = struct.unpack_from(">II", f.struct_blk, scan + 4)
            e2 = f.strings_blk.find(b"\x00", noff)
            pname = f.strings_blk[noff:e2].decode("utf-8", "replace")
            plen = 12 + ((ln + 3) & ~3)
            if pname == name:
                target_pos, target_len = scan, plen
            scan += plen
        elif tok == FDT_NOP:
            scan += 4
        else:
            break                            # 第一个子节点 / 节点结束

    area_end = scan
    if target_pos is not None:
        del f.struct_blk[target_pos:target_pos + target_len]
        area_end -= target_len

    noff = f.str_off(name)
    prop = struct.pack(">III", FDT_PROP, len(value), noff) + value
    prop += b"\x00" * ((4 - len(value) % 4) % 4)
    f.struct_blk[area_end:area_end] = prop
    return f


def align_to(n, a):
    return (n + a - 1) // a * a


# ============================================================
# cpio (newc) 遍历
# ============================================================
class Entry:
    __slots__ = ("name", "raw", "size", "mode", "is_dir")

    def __init__(self, name, raw, size, mode):
        self.name = name
        self.raw = raw
        self.size = size
        self.mode = mode
        self.is_dir = (mode & 0o170000) == 0o040000


def iter_cpio(buf):
    """按条目切分 cpio newc 归档，yield Entry（raw 为该条目完整字节）。

    保留原始字节而不重建，等于「只裁剪不重写」——元数据（uid/mode/mtime）不会丢。
    """
    pos, n = 0, len(buf)
    while pos + 110 <= n:
        hdr = buf[pos:pos + 110]
        if hdr[:6] not in (b"070701", b"070702"):
            break
        try:
            f = [int(hdr[6 + i * 8:6 + (i + 1) * 8], 16) for i in range(13)]
        except ValueError:
            break
        mode = f[1]
        filesize = f[6]
        namesize = f[11]
        if namesize == 0 or namesize > 4096:
            break
        name = buf[pos + 110:pos + 110 + namesize - 1].decode("utf-8", "replace")
        total = align4(110 + namesize) + align4(filesize)
        if pos + total > n:
            # 末尾不完整（可能是填充），停止
            break
        yield Entry(name, buf[pos:pos + total], filesize, mode)
        pos += total
        if name == "TRAILER!!!":
            break


def decompress_ramdisk(raw):
    if raw[:2] == GZIP_MAGIC:
        return gzip.decompress(raw), "gzip"
    if raw[:4] == ZSTD_MAGIC:
        try:
            import zstandard
        except ImportError:
            raise SystemExit("ramdisk 是 zstd 压缩，请先 pip install zstandard")
        return zstandard.ZstdDecompressor().decompress(raw), "zstd"
    if raw[:4] == LZ4_MAGIC:
        try:
            import lz4.frame
        except ImportError:
            raise SystemExit("ramdisk 是 lz4 压缩，请先 pip install lz4")
        return lz4.frame.decompress(raw), "lz4"
    return raw, "none"


def compress_ramdisk(data, kind):
    if kind == "gzip":
        return gzip.compress(data, compresslevel=9, mtime=0)
    if kind == "zstd":
        import zstandard
        return zstandard.ZstdCompressor(level=19).compress(data)
    if kind == "lz4":
        import lz4.frame
        return lz4.frame.compress(data, compression_level=12)
    return data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--out", default=None)
    ap.add_argument("--list", action="store_true", help="只列出 ramdisk 内容，不产出")
    ap.add_argument("--top", type=int, default=25, help="--list 时按体积显示前 N 项")
    ap.add_argument("--strip-elish", action="store_true",
                    help="删除 elish 的 adsp/slpi/cdsp 固件（约 31.7MB）")
    ap.add_argument("--strip-hwdb", action="store_true",
                    help="删除 usr/lib/udev/hwdb.bin（约 13.5MB）")
    ap.add_argument("--slim", action="store_true",
                    help="应用无头服务器瘦身预设（删 elish DSP 固件 / hwdb / x86 网卡驱动 / btrfs）")
    ap.add_argument("--strip", action="append", default=[],
                    help="额外删除的精确路径（可多次）")
    ap.add_argument("--strip-prefix", action="append", default=[],
                    help="额外删除的路径前缀（可多次）")
    ap.add_argument("--strip-glob", action="append", default=[],
                    help="额外删除的 fnmatch 模式（可多次）")
    ap.add_argument("--dtb-addr", default=None, type=lambda s: int(s, 0),
                    help="覆盖 header 里的 dtb_addr（如 0x4000000）")
    ap.add_argument("--ramoops", action="store_true",
                    help="往 DTB 注入 ramoops 节点（保留原 DTB 其余内容）")
    ap.add_argument("--no-ramoops", action="store_true")
    ap.add_argument("--disable-dsp", action="store_true",
                    help="把 DTB 里所有 remoteproc(-pas) 节点设为 disabled "
                         "（配合删除 elish 固件，避免 probe 失败拖慢启动）")
    ap.add_argument("--cmdline", default=None, help="整条覆盖 cmdline")
    ap.add_argument("--uuid", default="02232280-925f-4edc-984f-24e466d3b6f1")
    ap.add_argument("--kernel-raw", action="store_true",
                    help="把内核解压成未压缩的 ARM64 Image 再放回去。"
                         "【2026-09-26 实机证伪，勿用】原以为 ABL 需要 ARM64 头，"
                         "但 logfs 里的 'Decompressing kernel image total time: 406 ms' "
                         "证明 gzip 内核能被 ABL 正常解压；改用 rawk 后仍进 fastboot。"
                         "保留仅为对照实验。")
    ap.add_argument("--kernel-image", default=None,
                    help="直接用一个外部文件当内核（如已导出的 Image）")
    ap.add_argument("--dump-kernel", default=None,
                    help="把当前内核导出到该路径（配合 --kernel-raw 可先看再改）")
    ap.add_argument("--dtb", default=None,
                    help="用外部 DTB 文件整体替换镜像自带的 DTB。"
                         "通常配合 `dtc -@` 重新编译的 DTB 使用——"
                         "注意必须带 -@（生成 __symbols__），否则 ABL 的 "
                         "ApplyOverlay 会报 'ufdt apply overlay failed'。")
    ap.add_argument("--board-id", default=None,
                    help="改写 DTB 根节点的 qcom,board-id，空格分隔的十六进制，"
                         "如 '0x0 0x0'（原厂 boot.img 用的通配值）或 '0x2b 0x0'")
    args = ap.parse_args()

    mk = load_mkdiag()
    info = mk.parse_bootimg(args.src)
    page = info["page"]

    print("源镜像: %s" % args.src)
    print("  kernel   = %d 字节" % len(info["kernel"]))
    print("  ramdisk  = %d 字节 (%.1f MiB, 压缩态)" % (len(info["ramdisk"]), len(info["ramdisk"]) / 1048576))
    print("  dtb      = %d 字节" % len(info["dtb"]))
    print("  dtb_addr = 0x%x  (%.1f MiB)" % (info["dtaddr"], info["dtaddr"] / 1048576))
    print("  cmdline  = %s" % info["cmdline"])
    print()

    cpio, kind = decompress_ramdisk(info["ramdisk"])
    print("ramdisk 压缩格式 = %s，解压后 = %d 字节 (%.1f MiB)" % (kind, len(cpio), len(cpio) / 1048576))
    entries = list(iter_cpio(cpio))
    print("cpio 条目数 = %d" % len(entries))
    print()

    if args.list:
        print("按体积排序（前 %d 项）:" % args.top)
        for e in sorted(entries, key=lambda x: -x.size)[:args.top]:
            tag = "dir " if e.is_dir else "    "
            print("  %s%10d  %s" % (tag, e.size, e.name))
        total = sum(e.size for e in entries if not e.is_dir)
        print()
        print("普通文件合计 = %d 字节 (%.1f MiB)" % (total, total / 1048576))
        return 0

    if not args.out:
        raise SystemExit("需要 --out（或加 --list 只看内容）")

    # ---------- 过滤 ----------
    strip_exact = set(args.strip)
    if args.strip_elish:
        strip_exact.update(ELISH_STRIP)
    if args.strip_hwdb:
        strip_exact.add("usr/lib/udev/hwdb.bin")
    strip_prefix = tuple(args.strip_prefix)
    strip_globs = list(args.strip_glob)
    if args.slim:
        strip_globs.extend(SLIM_GLOBS)

    def should_strip(name):
        if name in strip_exact:
            return True
        if any(name.startswith(p) for p in strip_prefix):
            return True
        return any(fnmatch.fnmatchcase(name, g) for g in strip_globs)

    kept, removed = [], []
    trailer = None
    for e in entries:
        if e.name == "TRAILER!!!":
            trailer = e
            continue
        if should_strip(e.name):
            removed.append(e)
        else:
            kept.append(e)

    if removed:
        rm_total = sum(x.size for x in removed)
        print("已删除 %d 个条目，合计 %.1f MiB（未压缩）:"
              % (len(removed), rm_total / 1048576))
        for e in sorted(removed, key=lambda x: -x.size)[:15]:
            print("  - %10d  %s" % (e.size, e.name))
        if len(removed) > 15:
            print("  ... 其余 %d 个条目省略" % (len(removed) - 15))
        print()
    else:
        print("没有条目被删除（未指定 --strip-*）")
        print()

    if trailer is None:
        raise SystemExit("cpio 里没找到 TRAILER!!!")

    new_cpio = b"".join(e.raw for e in kept) + trailer.raw
    new_cpio += b"\x00" * ((-len(new_cpio)) % 512)

    new_ramdisk = compress_ramdisk(new_cpio, kind)
    print("新 ramdisk: %d -> %d 字节 (%.1f MiB)，压缩掉 %.1f MiB"
          % (len(info["ramdisk"]), len(new_ramdisk),
             len(new_ramdisk) / 1048576,
             (len(info["ramdisk"]) - len(new_ramdisk)) / 1048576))

    # ---------- DTB ----------
    dtb = info["dtb"]
    if args.dtb:
        with open(args.dtb, "rb") as _fh:
            dtb = _fh.read()
        print("DTB 使用外部文件 %s -> %d 字节" % (args.dtb, len(dtb)))
        print("  __symbols__ x%d   根节点 model=%s"
              % (dtb.count(b"__symbols__"),
                 (dtb[dtb.find(b"model") + 6:dtb.find(b"model") + 40].split(b"\x00")[0]
                  .decode("utf-8", "replace") if b"model" in dtb else "?")))
    if args.ramoops and not args.no_ramoops:
        dtb = mk.add_ramoops(dtb)
        print("DTB 注入 ramoops -> %d 字节" % len(dtb))
    if args.disable_dsp:
        f = mk.Fdt(dtb)
        nodes = parse_all_nodes(f)
        targets = [p for p, pr in nodes.items() if b"-pas" in pr.get("compatible", b"")]
        for p in targets:
            comp = nodes[p].get("compatible", b"").rstrip(b"\x00").decode("utf-8", "replace")
            fdt_set_prop(f, p, "status", b"disabled\x00")
            print("  DSP 节点关闭: %-40s (%s)" % (p, comp))
        if not targets:
            print("  [warn] DTB 里没找到 remoteproc(-pas) 节点")
        f.validate()
        dtb = f.tobytes()
        print("DTB 关闭 %d 个 DSP 节点 -> %d 字节" % (len(targets), len(dtb)))

    if args.board_id is not None:
        cells = [int(x, 0) for x in args.board_id.replace(",", " ").split()]
        f = mk.Fdt(dtb)
        nodes_all = parse_all_nodes(f)
        old = nodes_all.get("/", {}).get("qcom,board-id")
        old_s = " ".join("0x%x" % struct.unpack_from(">I", old, o)[0]
                         for o in range(0, len(old) - 3, 4)) if old else "(无)"
        val = b"".join(struct.pack(">I", c) for c in cells)
        fdt_set_prop(f, "/", "qcom,board-id", val)
        f.validate()
        dtb = f.tobytes()
        new_s = " ".join("0x%x" % c for c in cells)
        print("DTB 根节点 qcom,board-id: %s -> %s  (%d 字节)"
              % (old_s, new_s, len(dtb)))

    # ---------- 内核 ----------
    kernel_payload = info["kernel"]
    def kernel_kind(k):
        if k[:2] == b"\x1f\x8b":
            return "gzip"
        if k[:4] == b"\x04\x22\x4d\x18":
            return "lz4"
        if k[:4] == b"\x28\xb5\x2f\xfd":
            return "zstd"
        if len(k) > 60 and k[56:60] == b"ARM\x64":
            return "ARM64 Image (未压缩)"
        return "未知(%s)" % k[:4].hex()

    print("内核格式 = %s" % kernel_kind(kernel_payload))
    if args.dump_kernel:
        open(args.dump_kernel, "wb").write(kernel_payload)
        print("  已导出内核 -> %s (%d 字节)" % (args.dump_kernel, len(kernel_payload)))

    if args.kernel_image:
        kernel_payload = open(args.kernel_image, "rb").read()
        print("内核 <- %s (%d 字节, %s)" % (args.kernel_image, len(kernel_payload),
                                            kernel_kind(kernel_payload)))
    elif args.kernel_raw:
        if kernel_payload[:2] == GZIP_MAGIC:
            kernel_payload = gzip.decompress(kernel_payload)
        elif kernel_payload[56:60] == b"ARM\x64":
            print("  [info] 内核本来就是未压缩 Image，保持不变")
        else:
            raise SystemExit("内核既不是 gzip 也不是 ARM64 Image，无法自动解压")
        if kernel_payload[56:60] != b"ARM\x64":
            raise SystemExit("解压后仍找不到 ARM64 头 magic，请人工检查")
        import struct as _s
        print("  内核已未压缩化 -> %d 字节 (%.1f MiB)  text_offset=0x%x  image_size=0x%x  flags=0x%x"
              % (len(kernel_payload), len(kernel_payload) / 1048576,
                 _s.unpack_from("<Q", kernel_payload, 8)[0],
                 _s.unpack_from("<Q", kernel_payload, 16)[0],
                 _s.unpack_from("<Q", kernel_payload, 24)[0]))
    print()

    # ---------- cmdline ----------
    cmdline = args.cmdline or mk.DEFAULT_CMDLINE.format(uuid=args.uuid)

    # ---------- dtb_addr ----------
    if args.dtb_addr is not None:
        info["dtaddr"] = args.dtb_addr

    # ---------- 地址重叠检查 ----------
    rd_start, rd_end = info["raddr"], info["raddr"] + len(new_ramdisk)
    d_start, d_end = info["dtaddr"], info["dtaddr"] + len(dtb)
    print()
    print("内存布局检查:")
    print("  ramdisk  : 0x%08x .. 0x%08x" % (rd_start, rd_end))
    print("  dtb      : 0x%08x .. 0x%08x" % (d_start, d_end))
    if d_start < rd_end and rd_start < d_end:
        print("  ⚠️ 仍然重叠！请用 --dtb-addr 挪开或继续瘦身")
    else:
        print("  ✅ 不重叠")

    out = mk.build_bootimg(info, kernel_payload, new_ramdisk, dtb, cmdline)
    open(args.out, "wb").write(out)
    print()
    print("已写出 %s (%d 字节, %.1f MiB)" % (args.out, len(out), len(out) / 1048576))

    # ---------- 自检 ----------
    chk = mk.parse_bootimg(args.out)
    assert chk["kernel"] == kernel_payload, "回读内核不一致"
    assert chk["dtb"] == dtb, "回读 DTB 不一致"
    cpio2, _ = decompress_ramdisk(chk["ramdisk"])
    names = {e.name for e in iter_cpio(cpio2)}
    for e in removed:
        assert e.name not in names, "该删的没删掉: %s" % e.name
    print("自检: 条目数 %d，被删项确认不存在，DTB %d 字节，dtb_addr=0x%x"
          % (len(names), len(chk["dtb"]), chk["dtaddr"]))
    print("自检: cmdline = %s" % chk["cmdline"])
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
