# boot 构建指南 —— 从 DTS 源到能开机的 boot 镜像

> 目标：让任何人都能**重建这个 boot 镜像**、理解每一处改动、知道**还缺什么**。
> 本文只讲 boot（内核 + initrd + DTB）；rootfs 侧的构建见 [`../rootfs-build/BUILD.md`](../rootfs-build/BUILD.md)。

---

## 〇、一句话结论

| 你想做的事 | 这个包够不够 | 说明 |
|---|---|---|
| **改 DTB → 重打包 boot → 刷进手机** | ✅ 完全够 | DTS 源、基线 DTB、补丁、编译/重打包工具、成品镜像全在 |
| **验证"我的构建 == 官方成品"** | ✅ 够，且**已实测可复现** | 见 §三，产物 sha256 与随包镜像**逐字节一致** |
| **从零（上游 Armbian 基线）重来** | ✅ 够 | 基线 DTB 与补丁都在；脚本会提示 v0→v2 的转换路径（§五） |
| **理解"为什么这么改"** | ✅ 够 | `dts.patch`（基线 → 当前，219 个 hunk）+ `CHANGELOG-2026-09-27.md` |

**唯一必须自备的东西：原厂 `dtbo.img`**（ABL 的板级 overlay，不能替换、不能留空）。

---

## 一、这个目录里有什么

```
boot-build/
├── BUILD.md                    ← 本文件
├── build-boot.sh               ← 一键重建 boot 镜像（前置检查 + 校验 + 重打包 + 打印 sha256）
├── dts.patch                   ← baseline DTS → 当前 DTS 的完整补丁（219 hunk / 2932 行）
├── baseline/
│   ├── armbian-baseline-umi-csot.dtb   ← Armbian 原始 DTB（未改过，补丁基准）
│   ├── armbian-baseline-umi-csot.dts   ← 上面那个的反编译
│   └── BASELINE-INFO.txt               ← 基线镜像名 / 大小 / sha256
├── tools/
│   ├── replace-dtb.py          ← ★ 只替换 boot 镜像的 dtb 段（kernel/ramdisk 不动）
│   ├── rebuild-boot.py         ← 上游 v0 → v2 重打包器（瘦身 / 禁用 DSP / 注入 ramoops）
│   └── gen-ovf-nodes.py        ← 按 dtbo fixups 生成 /abl_ovf 锚点树
└── CHANGELOG-2026-09-27.md     ← 当前这版 DTS 的改动说明
```

**DTS 源码在上一级**：`../dtb/slim-ovf-wifi6-gpu-oc-final.dts`（与其编译产物 `.dtb`）。

**最小依赖**：

| 工具 | 用途 | 安装 |
|---|---|---|
| `dtc` / `fdtget` | 编译、校验 DTB | `apt install device-tree-compiler` |
| `python3` | 跑 `replace-dtb.py` 等 | 系统自带 |
| `patch` | 应用 `dts.patch` | 系统自带 |
| WSL / Linux | Windows 上建议在 WSL 里跑 | — |

---

## 二、自己构建（一条命令）

```bash
cd <本发布根目录>
bash boot-build/build-boot.sh                    # 用随包成品当基底，编译 ../dtb 里的 DTS
# 或指定基底与输出：
bash boot-build/build-boot.sh <基底boot.img> <输出boot.img>
```

脚本会做六件事，任何一步不合格就**立即中止**：

1. 前置检查 `dtc` / `fdtget` / `python3` / `sha256sum`
2. 确认基底是 **header v2**（有独立 dtb 段）
3. `dtc -@` 编译 DTS（**`-@` 必须有**，否则没有 `__symbols__`）
4. 校验三件事：`__symbols__.arch_timer` 能解析、**`/abl_ovf` 锚点数 ≥ 152**、`model` 正确
5. `replace-dtb.py` 把 DTB 塞回（**只改 dtb 段，kernel / ramdisk 逐字节不动**，脚本会自检）
6. 打印 sha256，并与官方成品对比

---

## 三、可复现性：已实测（2026-09-27）

```
$ dtc -@ -I dts -O dtb -o rebuilt.dtb ../dtb/slim-ovf-wifi6-gpu-oc-final.dts
$ python3 tools/replace-dtb.py ../boot/boot-umi-csot-ovf-wifi6-gpu-oc-final.img \
                               rebuilt.dtb out/boot-rebuilt.img

重建产物 DTB : b0e48ef96880567160182be4d31dc5721fa33ce3b3551909388b8e50612a99c2
随包   DTB : b0e48ef96880567160182be4d31dc5721fa33ce3b3551909388b8e50612a99c2   ✓ 一致
重建产物 BOOT: a7e4d341e35a663683bf41a8fe99d472bc6b8568aa1b54b05901dc7e9f2d842a
随包   BOOT: a7e4d341e35a663683bf41a8fe99d472bc6b8568aa1b54b05901dc7e9f2d842a   ✓ 一致
```

也就是说 **`DTS 源 + dtc -@ + replace-dtb.py` 这条链是确定性的**，换台机器跑得到同一个镜像
（本次实测用的 `dtc 1.6.1`，与制作镜像时设备上的 `dtc 1.7.2` 结果一致）。

另外 **`dts.patch` 也已验证**：对基线 DTS 应用后，与随包 DTS **逐字节一致**。

```bash
cd boot-build
patch -p0 -o /tmp/current.dts baseline/armbian-baseline-umi-csot.dts < dts.patch
diff -q /tmp/current.dts ../dtb/slim-ovf-wifi6-gpu-oc-final.dts    # 应当无输出
```

---

## 四、`dts.patch` 里到底改了什么（219 个 hunk 的关键项）

补丁基准是 **Armbian 原始 DTB 的反编译**（`baseline/armbian-baseline-umi-csot.dts`），
不是任何中间版本。改动按性质分五类：

| # | 改动 | 为什么 |
|---|---|---|
| ① | **新增 `/abl_ovf` 锚点树（152 个符号占位节点）** | 小米的 ABL 会往 base DTB 上打 dtbo overlay，靠符号表定位。**不加就过不了 ABL —— 设备秒进 fastboot** |
| ② | pcie0 补 `assigned-clocks`（aux 19.2 MHz）+ 修 `iommu-map` 长度（10→8 格） | 原本漏设，且长度非法报 `Bad iommu-map length` |
| ③ | pcieport0 下新增 **`wifi@0`（QCA6390）** | **ath11k 靠它请求 PMU 内部 LDO —— 这是芯片真正的供电来源** |
| ④ | 删掉 `bluetooth` / `phy@1c06000` 上假的 `power-domains = <&qca639x>` | 那些节点 compatible 少 `-pmu`，上游 `pwrseq_qcom_wcn` 不认 → 永久 defer |
| ⑤ | 假的 `qca639x` 节点 → 正确的 **`qca6390-pmu`**；`vreg_s2f_0p95` 加 `regulator-always-on` | 芯片是 QCA6390，用上游 elish 的配方；WLAN 的 PMU/dig 供电轨要常开 |
| ⑥ | **`display-subsystem@ae00000` 置 `okay`** | GPU 需要 DRM master 才能作为 component 绑定 |
| ⑦ | GPU：`status = "okay"` + zap shader 指向 `qcom/sm8250/a650_zap.mbn` | 上游 umi 的 DTS 把 `status` 写成了 `tatus`（dtc 只警告）→ GPU 静默 disabled |
| ⑧ | **GPU OPP 表：12 档（305 → 900 MHz）**，含超频档与 `opp-supported-hw` | 频率集合只能来自 DTB（开机喂给 GMU 固件），加档位必须刷一次 boot |
| ⑨ | **Venus OPP 表改回 `720/1014/1098/1332 MHz`** + `required-opps` 用 low_svs/svs/svs_l1/nom | 基线里的错表（240/338/366/444 = mvs0÷3，属 vcodec0_core 域）与驱动绑定的 `core`（÷2）不匹配 → `-ERANGE`，并发预算被砍到 1/3 |
| ⑩ | 3 个 DSP 节点置 `disabled`、去掉无关外设 | 服务器用不上，减小 DTB 与 initrd |

> ① 可以用 `tools/gen-ovf-nodes.py` 按原厂 dtbo 的 fixups 列表**自动重新生成**（换内核/换基线时跑它）。
> ⑨ 的详细诊断见 `CHANGELOG-2026-09-27.md`。

---

## 五、从零重来（上游 Armbian → 可用镜像）

⚠️ **一个关键坑：上游 Armbian 的 boot 镜像不是 v2 header。**
它是 **header v0**，DTB 按老惯例**追加在 `kernel.gz` 之后**，没有独立 dtb 段 → `replace-dtb.py` 用不了。
必须先用重打包器转成 v2：

```bash
# ① 上游 Armbian v0  →  v2（顺带瘦身 initrd、挪 dtb_addr 避开重叠、注入 ramoops）
python3 boot-build/tools/rebuild-boot.py \
    --src <Armbian ...boot_sm8250-xiaomi-umi-csot.img> \
    --out /tmp/v2.img \
    --slim --disable-dsp --ramoops

# ② 基线 DTB → 当前 DTS → 编译
dtc -I dtb -O dts -o baseline.dts boot-build/baseline/armbian-baseline-umi-csot.dtb
patch -p0 -o current.dts baseline.dts < boot-build/dts.patch
dtc -@ -I dts -O dtb -o current.dtb current.dts        # ★ -@ 必须有

# ③ 塞回 v2 镜像
python3 boot-build/tools/replace-dtb.py /tmp/v2.img current.dtb boot-umi.img
```

`rebuild-boot.py` 常用开关：

| 开关 | 作用 |
|---|---|
| `--slim` | 瘦身预设（删 elish 的 adsp/slpi/cdsp 固件、hwdb、intel 网卡、mpt3sas、btrfs） |
| `--disable-dsp` | 把 3 个 DSP 节点置 `disabled` |
| `--ramoops` | 注入 ramoops 节点（崩溃时能捞日志） |
| `--dtb-addr <hex>` | 改 DTB 加载地址（默认 `0x1F00000`，与瘦身后的 ramdisk 不重叠） |
| `--cmdline "..."` | 整条替换 cmdline（原版残留 `slot_suffix=_b`，A-only 设备不该有） |
| `--list` | 只列 initrd 内容 |

脚本自带三项自检：回读 DTB 一致性、被删条目确不存在、**ramdisk 与 dtb 区间重叠检查**。

---

## 六、刷机顺序（完整恢复链）

```
① fastboot flash boot    boot/boot-umi-csot-ovf-wifi6-gpu-oc-final.img   # 本包
② fastboot flash dtbo    <原厂底包>/images/dtbo.img                      # ★ 必须原厂
③ rootfs：进 TWRP → bash tools/restore-system-opensource.sh              # 解包到 userdata
④ 开机后：passwd / passwd -l armbian / bash /root/wifi-connect.sh        # 首启必做
```

⚠️ **绝不碰基带分区**：`modemst1/2`、`fsg`、`fsc`、`persist`、`mdm1m9kefs*`。

---

## 七、怎么确认成功了

```bash
# 1) ABL 没把它踢到 fastboot（否则说明 DTB 缺 __symbols__ / 锚点不足）
#    正常表现：约 40~60 秒后 USB 网卡出现、ssh 能连

# 2) WiFi 是否起来
lspci -nn | grep 17cb            # 期望 01:00.0 ... QCA6390 [17cb:1101]
dmesg | grep ath11k              # 期望 qca6390 hw2.0 / MSI vectors: 32
ip -br link | grep wlan0
iw dev wlan0 link

# 3) GPU / 编解码
ls /dev/dri/                     # 期望 renderD128 card1
ls /dev/video*                   # 期望 video0 video1

# 4) 系统健康
systemctl --failed
```

> ⚠️ **`dmesg` 里约 1.95 s 的 `qcom-pcie 1c00000.pcie: Phy link never came up` 是无害的**：
> 控制器先探测（芯片还没上电），pwrseq 在 7.7 s 才拉 `wlan-en` + 上 PMU LDO，链路随后自动建立。
> **判断看后面有没有 `01:00.0` 端点 / `wlan0`，不要看这条。**

---

## 八、许可与出处

| 内容 | 出处 / 许可 |
|---|---|
| DTS/DTB、内核 | Armbian `sm8250` family（基于 sm8250-mainline）→ **GPL-2.0** |
| `qca6390-pmu` 配方 | 上游 `sm8250-xiaomi-elish` 补丁（Jianhua Lu，2024，已进主线）→ GPL-2.0 |
| `pwrseq_qcom_wcn` | 主线 `drivers/power/sequencing/` → GPL-2.0 |
| `tools/*.py`、`build-boot.sh` | 本项目原创 |
| 原厂 ROM 片段（`dtbo.img` 等） | 小米官方，**未包含**在本发布内 |
