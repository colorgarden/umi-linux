# 2026-09-27 更新（开源侧 / 自行构建）

> 📌 **路径说明**：本文是开发期的实测记录，文中的 `backup/…`、`output/…` 是当时工作树里的位置。
> 在**本仓库**里的对应关系：构建材料 → `boot-build/`、成品镜像 → `boot/`、rootfs 侧配置 → `rootfs-config/`。

> 本文件说明 **本次快照相对 2026-09-26 版更新了什么**，以及**如何精确复现当前状态**。
> 备份/归档侧的完整改动汇总见 `../../CHANGELOG-2026-09-27.md`。

---

## 0. 这次快照新增了什么（关键）

| 内容 | 位置 | 状态 |
|---|---|---|
| **完整的基线 DTS**（由官方基线 DTB 反编译，未改过） | `baseline/armbian-baseline-umi-csot.dts` | ✅ 新增 |
| **当前使用的 DTS**（含全部改动，可编译） | `dts/slim-ovf-wifi6-gpu-oc-final.dts` | ✅ 新增 |
| 上者编译产物 | `dts/ovf-wifi6-gpu-oc-final.dtb`（142,803 B） | ✅ 新增 |
| **完整的 DTS 补丁**（基线 → 当前，`-p0` 可用） | `dts.patch`（2932 行 / 219 hunk） | ✅ **已重生成**（旧的只到 WiFi 阶段） |
| 本次改动说明 | 本文件 | ✅ 新增 |

**可复现性已验证**：用 `dts/slim-ovf-wifi6-gpu-oc-final.dts` 在设备上
`dtc -@ -I dts -O dtb` 编译，产物与**当前手机里刷着的 DTB 逐字节一致**
（sha256 `b0e48ef96880567160182be4d31dc5721fa33ce3b3551909388b8e50612a99c2`）。

> ⚠️ 行尾说明：本目录的 DTS 统一为 **LF**。此前用 Windows 文本模式生成的部分 `.dts` 曾是 CRLF
> （对 DTB 无影响，因为由设备端 dtc 编译、字符串未被污染），已全部归一化，以免 `diff`/`patch` 失效。

---

## 1. 当前 DTS 相对基线改了哪几类东西

1. **ABL overlay 相关**（2026-09-26 已有）：加 `__symbols__`（含 `arch_timer`、`qcom_tzlog`）、
   152 个 `/abl_ovf` 占位锚点 —— **不加则 ABL apply overlay 失败 → 秒进 fastboot**。
2. **WiFi（QCA6390）**（9-26 已有）：pcie0 补 `assigned-clocks`/修 `iommu-map` 长度、新增 `wifi@0` 子节点（ath11k 靠它请求 PMU LDO）、
   删蓝牙/PHY 上假的 `power-domains`、`vreg_s2f_0p95` 加 `regulator-always-on`。
3. **GPU / 显示**（9-26 已有）：`display-subsystem@ae00000` 置 `okay`；zap-shader 指向
   `qcom/sm8250/a650_zap.mbn`；**内核 Image 另外需要原位补丁**（`kernel-patch/patch_kernel.py`，
   把 `"qcom,sm8250\0"` 换成 `"qcom,kona\0\0\0"` 以匹配 ABL 覆盖后的 compatible）。
4. **⭐ Venus OPP 修复（2026-09-27 新增）**：venus `opp-table` 的 `opp-hz` 由
   `240/338/366/444 MHz` 改为 **`720/1014/1098/1332 MHz`**，`required-opps` 用
   `low_svs / svs / svs_l1 / nom`（本机写成两条，对应 mx/mmcx，同档最保险），
   4 个 `power-domains`（含 mmcx）原样保留。
   **为什么**：驱动把 OPP 表绑在 `"core"` 时钟（`mvs0_clk_src` **÷2**）上，而原表数值是
   `mvs0_clk_src` **÷3**（vcodec0_core 域），导致请求被取整到 507 MHz > 表上限 444 → `-ERANGE`，
   高档位永远设不进去，且 `decide_core()` 的并发预算被砍到 1/3。
   修复后 8 路 1080p 硬编由 5/8 → **8/8**，三类报错归零。
5. **⭐ GPU OPP 扩档（2026-09-27 新增）**：GPU `opp-table` 扩成 **12 档**：
   `900(level 0x140) / 870(0x140) / 800 / 750 / 700 / 670 (0x100) / 587 / 525 / 490 / 441.6 / 400 / 305`，
   全部 `opp-supported-hw = <0x0f>`（打开原被 speed-bin 屏蔽的 670 MHz 档）。
   **为什么能行**：内核开机把 `(频率kHz, RPMh 电压票)` 表经 HFI `H2F_MSG_PERF_TABLE` 交给 GMU 固件，
   任意频率只要 GMU 的时钟编程能生成即可；`opp-level` 决定电压票，必须落在平台 CMD-DB 的 `gfx.lvl` 列表内
   （本机实测 `0x140` 可用）。**GMU 上限 16 档**。
   实测稳定上限 **900 MHz（需 0x140 加压）**；标准电压下 **800 MHz**；**1 GHz 不可达**（长烤崩）。
   表中**不留不稳定档**（820/850/1000 已剔除）——因为调速器会在 `[min,max]` 内自行挑档。

---

## 2. 如何复现当前状态（照抄即可）

### 2.1 只要 DTB（验证过逐字节一致）

```bash
# 用本目录自带的 DTS（LF）
dtc -@ -I dts -O dtb -o /tmp/current.dtb dts/slim-ovf-wifi6-gpu-oc-final.dts
# 期望 sha256 = b0e48ef96880567160182be4d31dc5721fa33ce3b3551909388b8e50612a99c2
```

或从基线自己打补丁（结果是同一个 DTS）：

```bash
mkdir -p /tmp/w && cd /tmp/w && mkdir -p baseline dts
cp <open>/baseline/armbian-baseline-umi-csot.dts baseline/
patch -p0 -o dts/slim-ovf-wifi6-gpu-oc-final.dts < <open>/dts.patch
# 注意：不加 -o 时 patch 会默认去改 "---" 那侧（baseline/…dts），把基线文件覆盖掉
```

### 2.2 做出当前 boot 镜像

当前镜像 = **黄金版 boot（含内核原位补丁 + 瘦身 initrd + ramoops）** 换入上面的 DTB：

```bash
# 基底：黄金版
#   backup/releases/boot-wifi6-gpu-venus-2026-09-26/boot/boot-umi-csot-ovf-wifi6-gpu.img
# 只换 dtb 段（kernel/ramdisk 逐字节不动，脚本自带自检）
python3 tools/replace-dtb.py \
    boot-wifi6-gpu-venus-2026-09-26/boot/boot-umi-csot-ovf-wifi6-gpu.img \
    dts/ovf-wifi6-gpu-oc-final.dtb \
    boot-current.img
# 期望 sha256 = a7e4d341e35a663683bf41a8fe99d472bc6b8568aa1b54b05901dc7e9f2d842a
```

> 从**上游 Armbian 原始镜像**从零构建的完整链条见 `BUILD.md` §2.2
> （先 `tools/rebuild-boot.py --slim --disable-dsp --ramoops` 转 v2，再 dtc，再 replace-dtb）。

### 2.3 rootfs 侧需要配套的三个东西

| 功能 | 文件 | 默认值 |
|---|---|---|
| **GPU 频率默认上限**（超频档存在时的安全阀） | `/usr/local/sbin/umi-gpu-maxfreq.sh` + `umi-gpu-maxfreq.service` + `/etc/default/umi-gpu-maxfreq` | `GPU_MAX_FREQ=800000000` |
| **CPU 高性能** | `/etc/default/cpupower`（注意 `cpupower.service` 读的是**这个文件**，不是 `cpufrequtils`） | `GOVERNOR="performance"` |
| **充电区间 70/65** | `/etc/default/battery-charge-limit`（实现是既有脚本 `/usr/local/bin/battery-charge-limit`，在 `sources/armbian-umi-port/userpatches/overlay/`） | `UPPER=70 LOWER=65 INTERVAL=30` |

三者的文件副本都在 `backup/releases/boot-wifi6-gpu-oc-2026-09-27/rootfs-config/`，
镜像定制的默认值在 `sources/armbian-umi-port/userpatches/customize-image.sh`。

---

## 3. 复现时的坑（都踩过）

1. **`dtc` 必须带 `-@`**，否则 `__symbols__` 缺失 → ABL apply overlay 失败 → 秒进 fastboot。
   编译后确认：`__symbols__` **154 条**（152 个 `abl_ovf` 锚点 + `arch_timer` + `qcom_tzlog`）。
2. **保留原厂 `dtbo.img`**（不能替换、不能清空）。
3. **测 GPU 负载别用 `glClear`**：Adreno 是 TBDR，`glClear` 会被优化成"快清"，不吃算力也不随频率变化，
   会得出"频率不影响性能"的错误结论。用带重片元着色器 + 像素回读校验的负载（参考
   `backup/releases/boot-wifi6-gpu-oc-2026-09-27/tools/gpu-stress.py`）。
4. **OC 稳定性必须长烤**：1000 MHz 在 6 秒短跑下完全正常（0 花屏），60 秒就崩。
5. **⚠️ 不要读 `/sys/bus/nvmem/devices/qfprom0/nvmem`（efuse）** —— qfprom 电源域开机后断电，
   访问其 MMIO 会**异步 SError → Kernel panic**（本次实测崩过一次）。想读 GPU speed bin 请用
   OPP 过滤结果的差异反推，不要直接读 efuse。
6. **开机 zap 报错是无害的**：`error -22 initializing firmware qcom/sm8250/a650_zap.mbn` +
   `gpu hw init failed` + `a6xx_gmu_set_oob Timeout` —— 驱动 probe 早于 rootfs 挂载，
   首次打开 `/dev/dri/renderD128` 时会重试并成功（`gpu-initialized: 1`）。不要据此判断"GPU 坏了"。

---

## 4. 详细报告

**本快照自带（`open/docs/`，自包含）**

| 主题 | 文件 |
|---|---|
| Venus OPP 诊断与修复（根因/证据/修法/回滚） | `docs/venus-opp-诊断-2026-09-27.md` |
| GPU 超频 + CPU 高性能（含压测方法学、稳定性结论） | `docs/GPU超频与CPU高性能-报告-2026-09-27.md` |

**仓库内其他相关文件（`output/`，属工作产物目录）**

| 主题 | 文件 |
|---|---|
| GPU 频率体检（机制与天花板分析） | `output/gpu-频率体检-2026-09-27.md` |
| 充电区间控制说明 | `output/charge-limit/README.md` |
| 当天全部改动汇总（备份侧） | `backup/releases/CHANGELOG-2026-09-27.md` |

---

## 5. 配套的「整机系统镜像」

本目录只负责 **DTS / boot 侧**的构建材料。想直接拿到**可刷的整套系统**，见配套发布：

```
backup/releases/umi-system-opensource-2026-09-27/
├── rootfs/umi-system-opensource-2026-09-27.tar.gz   整机 Debian 系统镜像（1.98 GB）
├── boot/boot-umi-csot-ovf-wifi6-gpu-oc-final.img    配套 boot（与本目录的 DTS 一致）
├── docs/   ← 快速开始 / 使用指南 / 自行构建 / 发布与下载
└── tools/  ← 还原 / 拆片 / 发布脚本
```

- 镜像是设备的完整 Debian rootfs，**不含任何个人信息**（不含宝塔面板与容器数据）。
- 首启必做：`passwd`（改默认密码）、`passwd -l armbian`（锁掉第二个可登录账号）、`/root/wifi-connect.sh`（配 WiFi）。
