#!/usr/bin/env python3
"""
只替换 Android v2 boot 镜像里的 DTB 段。
kernel / ramdisk / second 段逐字节原样保留，只改 header 的 dtb_size 字段。

用途：boot.img 的 DTB 缺 __symbols__ 时，ABL 的 ApplyOverlay 会报
      "ApplyOverlay: ufdt apply overlay failed" -> "Error: Dtb overlay failed"
      -> 秒进 fastboot。把用 `dtc -@` 重新编译的 DTB 塞回去即可。

用法: replace-dtb.py <原 boot.img> <新 DTB> <输出 boot.img>
"""
import hashlib
import struct
import sys

FDT_MAGIC = bytes.fromhex("d00dfeed")


def pages(n, ps):
    return (n + ps - 1) // ps


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    src, dtb_path, dst = sys.argv[1], sys.argv[2], sys.argv[3]

    b = open(src, "rb").read()
    dtb_new = open(dtb_path, "rb").read()

    if b[:8] != b"ANDROID!":
        print("!! 源文件不是 Android boot 镜像")
        return 1
    (ks, ka, rs, ra, ss, sa, tags, ps, hv, osv) = struct.unpack_from("<10I", b, 8)
    if hv < 2:
        print("!! 需要 v2 header（才有独立 dtb 段），当前 header_version=%d" % hv)
        return 1
    hs = struct.unpack_from("<I", b, 1644)[0]
    dsz_old, daddr = struct.unpack_from("<2I", b, 1648)

    koff = ps
    roff = koff + pages(ks, ps) * ps
    soff = roff + pages(rs, ps) * ps
    doff = soff + pages(ss, ps) * ps

    print("源镜像   : %s (%d B)" % (src, len(b)))
    print("  header_version=%d  page_size=%d  header_size=%d" % (hv, ps, hs))
    print("  kernel  %9d B @0x%08x" % (ks, koff))
    print("  ramdisk %9d B @0x%08x" % (rs, roff))
    print("  second  %9d B @0x%08x" % (ss, soff))
    print("  dtb     %9d B @0x%08x  (dtb_addr=0x%x)" % (dsz_old, doff, daddr))

    old = b[doff:doff + dsz_old]
    if old[:4] != FDT_MAGIC:
        print("!! 原 dtb 段位置推算错误，头 4 字节 = %s（应为 d00dfeed）" % old[:4].hex())
        return 1
    print("  校验: 原 dtb 段 FDT magic 正确 ✓")
    if dtb_new[:4] != FDT_MAGIC:
        print("!! 新 DTB 头 4 字节 = %s，不是合法 FDT" % dtb_new[:4].hex())
        return 1

    out = bytearray(b[:doff]) + bytearray(dtb_new)
    # 保持页对齐：Android boot 镜像各段按 page_size 对齐，
    # 有些 fastboot/ABL 实现会按页读取，尾部补 0 更保险。
    pad = (-len(dtb_new)) % ps
    out += bytes(pad)
    struct.pack_into("<I", out, 1648, len(dtb_new))

    # 防御性断言：确认没动别的段
    assert bytes(out[koff:koff + ks]) == b[koff:koff + ks], "kernel 段被改动"
    assert bytes(out[roff:roff + rs]) == b[roff:roff + rs], "ramdisk 段被改动"
    assert struct.unpack_from("<I", out, 1648)[0] == len(dtb_new), "dtb_size 回读不一致"
    assert bytes(out[doff:doff + len(dtb_new)]) == dtb_new, "dtb 段回读不一致"

    open(dst, "wb").write(out)

    print()
    print("输出     : %s (%d B, %+d)" % (dst, len(out), len(out) - len(b)))
    print("  dtb_size: %d -> %d" % (dsz_old, len(dtb_new)))
    print("  新 DTB  : __symbols__ x%d   arch_timer x%d   qcom_tzlog x%d"
          % (dtb_new.count(b"__symbols__"), dtb_new.count(b"arch_timer"),
             dtb_new.count(b"qcom_tzlog")))
    print("  自检通过：kernel / ramdisk 段逐字节未变 ✓")
    print("  sha256  : %s" % hashlib.sha256(out).hexdigest())
    return 0


if __name__ == "__main__":
    sys.exit(main())
