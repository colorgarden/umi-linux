#!/usr/bin/env python3
"""
为 ABL 的 dtbo overlay 生成"占位锚点"节点。

背景
----
ABL 引导时会把 dtbo 分区里匹配机型的 overlay 应用到 boot.img 的 base DTB 上
（日志: ApplyOverlay / ufdt apply overlay）。该 overlay 是符号引用式的：
每个 fragment 的 target 是 <0xffffffff>，靠 __fixups__ 列出的符号名去 base DTB
的 __symbols__ 里查路径。**只要有一个符号查不到路径，整个 apply 就失败**：

    ApplyOverlay: ufdt apply overlay failed
    Error: Dtb overlay failed
    Launching fastboot

我们的 DTB 是 mainline 编的，本来一个 __symbols__ 都没有，所以必然失败。

做法
----
在 base DTB 里额外挂一棵 abl_ovf 子树，为 overlay 需要的每个符号名建一个
**空的占位节点**，并把符号名本身用作它的 label。于是 `dtc -@` 生成的
__symbols__ 就包含全部符号，且全部指向真实存在的节点 -> apply 成功。

副作用是可控且有益的：overlay 的内容会被合并进这些占位节点，而**不会**
碰到我们真实的 soc / pinctrl / thermal 等节点，Linux 侧完全无感
（占位节点没有 compatible，内核不会 probe）。

用法: gen-ovf-nodes.py <输入 .dts> <fixups.json> <输出 .dts>
"""
import json
import re
import sys

ANCHOR = """	qcom_tzlog: tz-log@146bf720 {
		compatible = "qcom,tz-log";
		reg = <0x00 0x146bf720 0x00 0x3000>;
		qcom,hyplog-enabled;
		hyplog-address-offset = <0x410>;
		hyplog-size-offset = <0x414>;
	};
"""

LABEL_OK = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    src, fx_json, dst = sys.argv[1], sys.argv[2], sys.argv[3]

    names = json.load(open(fx_json))
    names = list(dict.fromkeys(names))          # 去重且保持顺序
    bad = [n for n in names if not LABEL_OK.match(n)]
    if bad:
        print("!! 有符号名不是合法 DTS label，无法用 label 方式处理:", bad)
        return 1

    txt = open(src, encoding="utf-8").read()
    if ANCHOR not in txt:
        print("!! 在输入 dts 里找不到锚点（qcom_tzlog 节点）。"
              "请先按文档在 timer 后插入 tzlog 节点再跑本脚本。")
        return 1
    if "abl_ovf" in txt:
        print("!! 输入 dts 里已经有 abl_ovf 子树了，避免重复插入")
        return 1

    # 每个符号 -> 一个空占位节点；label = 符号名
    lines = []
    lines.append("\t/* ---- ABL dtbo overlay 符号占位锚点（自动生成，勿手改）---- */")
    lines.append("\t/* 这些节点没有 compatible，Linux 不会 probe；作用仅仅是让")
    lines.append("\t * ABL 的 ufdt apply overlay 能在 __symbols__ 里解析到每一个符号。 */")
    lines.append("\tabl_ovf {")
    used = set()
    for i, n in enumerate(names):
        node = "ovf%d" % i
        while node in used:
            node += "_"
        used.add(node)
        lines.append("\t\t%s: %s { };" % (n, node))
    lines.append("\t};")
    block = "\n".join(lines) + "\n\n"

    out = txt.replace(ANCHOR, ANCHOR + "\n" + block, 1)
    open(dst, "w", encoding="utf-8", newline="\n").write(out)

    print("符号数            : %d" % len(names))
    print("生成占位节点      : %d 个（挂在 /abl_ovf 下）" % len(names))
    print("输出              : %s" % dst)
    print("前 5 个           : %s" % ", ".join(names[:5]))
    print("后 5 个           : %s" % ", ".join(names[-5:]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
