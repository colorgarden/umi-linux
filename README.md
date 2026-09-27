# UmiLinux —— 让小米 10 跑原生 Debian 的完整开源方案

> **Xiaomi Mi 10（代号 `umi`，Qualcomm Snapdragon 865 / SM8250，A-only 分区）** 上刷入
> **纯 Linux**（Debian 13 trixie + 内核 6.18.52 LTS），**彻底不要 Android**，无桌面、无 GUI，
> 当一台**无头 ARM 小服务器 / 常驻终端**用。
>
> 本仓库是**完整可复现的开源包**：整机系统镜像 + 配套 boot 镜像 + 设备树源码 + 全部系统服务与配置
> + 构建脚本 + 实测报告。
>
> 版本：`v2026-09-27`　｜　许可：[GPL-2.0](LICENSE)　｜　状态：**真机验证可用，不含个人信息**　｜
> 面板：本方案针对 **CSOT（华星光电）** 面板的机器

---

## 📦 下载（就两个文件）

镜像体积大，放在 **Releases** 里，不进 git 仓库：

```bash
# ① 配套 boot 镜像（27 MiB）→ 放 boot/
curl -LO https://github.com/misaka-link/umi-linux/releases/download/v2026-09-27/boot-umi-csot-ovf-wifi6-gpu-oc-final.img
mv boot-umi-csot-ovf-wifi6-gpu-oc-final.img boot/

# ② 整机系统镜像（1.98 GiB）→ 放 rootfs/
curl -LO https://github.com/misaka-link/umi-linux/releases/download/v2026-09-27/umi-system-opensource-2026-09-27.tar.gz
mv umi-system-opensource-2026-09-27.tar.gz rootfs/

# ③ 校验
sha256sum -c SHA256SUMS.txt
```

| 产物 | 大小 | sha256 |
|---|---|---|
| `boot-umi-csot-ovf-wifi6-gpu-oc-final.img` | 28,209,152 B | `a7e4d341e35a663683bf41a8fe99d472bc6b8568aa1b54b05901dc7e9f2d842a` |
| `umi-system-opensource-2026-09-27.tar.gz` | 2,123,920,669 B | `51f4b38d23b71d7d70b7472b3ef95e673c0e984f1f7c489c75305fc4fb2d645f` |

> 下载完**先做 §5 的 4 步加固**（改密码 / 锁默认账号 / 换主机密钥 / 配 WiFi）再联网。

---

## ⚡ 三件事先记住（30 秒速览）

| 你要问的 | 答案 |
|---|---|
| **是"刷完就能用"吗？** | **是**，但有前提：BootLoader 已解锁 + `dtbo` 用**原厂**镜像 + 面板是 **CSOT**；rootfs 必须在 **TWRP 里解包**（它是 tar.gz 根文件系统，不是 `fastboot flash` 的 img）。刷完约 40~60 秒，插上 USB 就有网卡和串口，**立刻能登进去用**（GPU / 编解码 / 息屏 / 充电控制 / Docker 都已就绪） |
| **默认账号密码是什么？** | **`root` / `umi10linux`**（串口免密，SSH 要密码）。⚠️ **另外还有一个 `armbian` / `armbian`** —— 它在 `sudo` **和** `docker` 组里，**等于第二把 root 钥匙**，必须锁掉，见 §五 |
| **开箱没配好的东西？** | **WiFi 凭据**（镜像里不含，要用 WiFi 必须自己配一次）；`umi-put`（8080 无鉴权文件服务）**默认不自启** |

> 账号的完整清单（含已锁定的系统账号）与权限分析见 §五；这三点是"拿到包第一分钟就该知道"的。

---

## 一、这是什么

一句话：**把一台小米 10 变成一台跑 Debian 13 的 ARM 小服务器。**

不装 Android，不留双系统，整块 UFS 都给 Linux。项目从引导链（ABL → boot → 内核 → rootfs）
一路做到用户态服务，把这块 SM8250 板子上能点的硬件全部点亮：**WiFi 6、USB 有线网卡、
USB 串口控制台、Adreno 650 GPU（OpenGL / Vulkan）、Venus 视频硬编解码、PM8150B 电量计与充电控制、真息屏**。

它**不是**手机系统，也不是"能启动就算成功"的 demo —— 这是一台**已经在跑、开机自连 WiFi、
可以 SSH 进去跑 Docker / ffmpeg 硬解 / GPU 计算**的机器，镜像就是从这台机器上导出的。

| 项 | 值 |
|---|---|
| 机型 | Xiaomi Mi 10（`umi`）/ 骁龙 865 / SM8250 |
| 面板 | **CSOT（华星光电）** —— 本仓库的 DTB 针对它；`sms` 面板需换 `rootfs-build/patch/.../sm8250-xiaomi-umi-sms.dts` 重编 DTB |
| 底包要求 | MIUI `V12.5.10.0.RJBCNXM`（或其他 SM8250 umi 底包，仅用于提供分区表与原厂 `dtbo`） |
| 发行版 | **Debian 13 trixie**（minimal，无桌面） |
| 内核 | **6.18.52 LTS**（Armbian `sm8250` family 的 `current` 分支） |
| init | systemd（`multi-user.target`） |
| 图形栈 | Mesa 25.0.7 / Freedreno / Turnip（Vulkan 1.3.305） |
| 存储 | 整块 UFS 归 Linux（系统盘） |
| 启动方式 | 直接刷 `boot` 分区，**不依赖 recovery、不依赖 BCB 切槽** |
| 必须解锁 | BootLoader 必须解锁；**必须保留原厂 `dtbo.img`** |

---

## 二、能力矩阵：能用什么，不能用什么

### ✅ 能用（都经真机实测）

| 子系统 | 状态 |
|---|---|
| **CPU / 内存** | 8 核（4×A55 1.80 GHz + 3×A77 2.42 GHz + 1×A77 2.84 GHz）+ LPDDR5。默认 `schedutil`，可切 `performance` |
| **UFS 存储** | 整盘可用，`resize2fs` 后可把 UFS 全部给根文件系统 |
| **WiFi（QCA6390 / ath11k）** | **WiFi 6（802.11ax，2.4/5 GHz）**，`wlan0`，开机自连（配好后），支持改 MAC |
| **USB 有线网卡（NCM）** | 插上电脑即出网卡，**Windows 免驱**（自带 `usbncm.inf`）。设备 `172.16.42.1`，实测 **426 Mbps** |
| **USB 串口控制台（ACM）** | 同一根 USB 线同时出串口，115200，**免登录进 root shell**（救砖通道） |
| **GPU（Adreno 650）** | `/dev/dri/renderD128` + `card1`；**Vulkan 1.3**（Turnip）、**OpenGL 4.6 Core**、**GLES 3.2**、EGL 1.5（GBM/surfaceless/Wayland）；devfreq 多档调频 |
| **视频编解码（Venus）** | `/dev/video0`（解码）+ `/dev/video1`（编码）；**H.264 / HEVC 硬解、H.264 硬编**（NV12）；实测 **8 路 1080p30 并发编码** 全绿 |
| **电池 / 充电** | PM8150B 电量计 + SMB2 充电器；电量可读、**充电区间可控**（默认充到 70% 停、掉到 65% 复充） |
| **屏幕（不亮但有用）** | 无面板驱动，但通过 GPIO 给面板**彻底断电**（真息屏，防烧屏、省功耗） |
| **Docker / 容器** | 内核选项齐（含 AppArmor 进 `CONFIG_LSM`） |
| **远程调试** | 开机自动采集 `dmesg`/`journalctl` 快照到 `/data/diag/` |

### ❌ 不能用（或者别指望）

| 能力 | 原因 |
|---|---|
| **屏幕显示 / 桌面 / GUI** | **没有面板驱动**（本机是 CSOT DSC 面板）。屏幕只有 ABL 留下的 framebuffer，然后被 `panel-off` 断电 → **开机后屏幕一直黑/灰是正常的**，别接显示器幻想有输出 |
| **触摸屏** | 无驱动 |
| **蜂窝基带（打电话 / 短信 / SIM 上网）** | 未启用。**基带分区绝对不许擦**（见 §六）；这台机器就是一台没有"电话"功能的 Linux 主机 |
| **摄像头 / 指纹 / NFC / 红外** | 无驱动 |
| **蓝牙** | 固件与驱动已就位，但本项目**只验证了 WiFi，蓝牙未验证** |
| **音频出声** | ADSP/CDSP 起来了，但音频编解码链路（soundwire / va_macro）未验证 |
| **USB Host（外接键鼠 / U 盘）** | USB 口默认被用作 **gadget**（网卡 + 串口）。内核已开 `CONFIG_USB_ROLE_SWITCH`，但要真插键鼠得停掉 gadget 服务再切 host 角色，本包未提供现成脚本 |
| **休眠 / 深度待机** | 内核支持 `s2idle`，但本项目主动 **mask 了 sleep/suspend**（服务器要常在线）；实测从未休眠过。WiFi 省电也**关闭** |
| **超过 ~8 路 1080p30 的并发编码** | 硬件吞吐上限（额定约 500 MP/s ≈ 4K@60）；12/16 路会被驱动拒绝 |
| **GPU 超频档的过热保护** | 超频到 800/900 MHz 超出熔丝（speed-bin）验证范围，而**本内核没注册 GPU cooling device → 无过热降频保护**。默认上限 800 MHz，可改回 587 |
| **Android 应用 / Google 服务 / 双系统** | 这个方案就是**不要 Android** |

---

## 三、它是怎么引导、怎么启动的

这是整个项目最"硬"的部分 —— SM8250 刷 Linux 的坑几乎全在引导链上。

```
① 上电
   │
   ├─ BootROM / XBL（高通）
   │
② ABL（小米引导程序，BL 解锁后才能从 fastboot 刷 boot）
   │   读 boot 分区：Android boot header **v2** = kernel + initrd + **DTB**
   │   ★ 若 base DTB 不合格 → overlay 应用失败 → 设备「秒进 fastboot」
   │
   ├─ 加载 **原厂 dtbo.img** 里的 device-tree overlay，叠加到 base DTB 上
   │   ★ 所以：① base DTB 必须用 `dtc -@` 编译（带 __symbols__）
   │           ② 必须含 `/abl_ovf` 锚点树（152 个符号占位节点）
   │           ③ 原厂 dtbo.img 绝不能删、不能空、不能替换
   │   ★ ABL 还会把根节点 compatible 覆写成 `qcom,kona-mtp / qcom,kona / qcom,mtp`
   │
③ 内核 6.18.52 LTS（本项目的 Image 内有一处等长字节补丁，见下）
   │
④ initrd（本项目已瘦身：删掉无关固件/hwdb/网卡驱动，并让 dtb 加载地址
   │        与 ramdisk 不重叠）
   │
⑤ rootfs = **userdata 分区**（`/dev/sda34`，ext4）= Debian 13 trixie
   │
⑥ systemd 起服务：
      usb-gadget-umi   → USB 网卡(172.16.42.1) + USB 串口(autologin root)
      wpa_supplicant@wlan0 + systemd-networkd → WiFi 自连
      panel-off        → 给屏幕断电（真息屏）
      umi-venus-enable → MMCX 上电 + 加载 Venus（视频硬编解）
      umi-gpu-maxfreq  → 设定 GPU 频率上限
      battery-charge-limit → 充电区间滞回控制
      umi-bcb-early    → 【保命网】写 misc 分区，异常重启/崩溃直接落 TWRP
```

### 三个必须知道的"引导硬约束"

1. **DTB 必须带 `__symbols__` 与 `/abl_ovf` 锚点树。**
   ABL 用 overlay 往 base DTB 上打补丁，靠的就是符号表。我们的 DTB 里塞了 **152 个
   `abl_ovf` 占位锚点**（按原厂 dtbo 的 fixups 列表生成）。少了 → **机器会秒进 fastboot**，
   连内核都不会启动。构建脚本 `boot-build/build-boot.sh` 会自动校验这一点。
2. **内核 Image 里有一处"一个字符串"的补丁。**
   ABL 覆写后的 compatible 是 `qcom,kona*`，而内核 `ubwc_config.c` 的表里只登记了
   `qcom,sm8250` → 匹配失败（`EINVAL`）→ mdss/GPU 全都初始化不了。
   我们在内核 Image 里**等长替换**了 `"qcom,sm8250"` → `"qcom,kona"`（12 字节原位替换，
   零偏移变动）。这是 **GPU 能点亮的关键前提**。
3. **`dtbo` 分区必须是原厂镜像。** 它提供 ABL 需要的那份 overlay。本方案**不含**
   厂商二进制，请从你自己的机器底包里保留（见 §六 刷机说明）。

---

## 四、这个项目做了什么（都在真机上验证过）

| # | 做了什么 | 实测结果 |
|---|---|---|
| 1 | **引导链打通**：ABL overlay 所需的 `__symbols__` + 152 锚点 + 内核 compatible 补丁 + initrd 瘦身与地址去重叠 | 从"秒进 fastboot / 黑屏 panic"到稳定进系统 |
| 2 | **WiFi 6 适配（QCA6390）** | 补 PCIe/PHY 的时钟与电源域、新增 `wifi@0` 节点让 ath11k 拿到 PMU 内部 LDO → `wlan0` 起来、开机自连 |
| 3 | **USB 双通道**（NCM 网卡 + ACM 串口） | Windows 免驱 426 Mbps；串口 autologin root，成为救砖通道 |
| 4 | **GPU（Adreno 650）点亮** | 内核补丁 + 启用 mdss + 小米签名 zap shader → `renderD128`；**Vulkan 1.3 / GL 4.6 / GLES 3.2** 真硬件跑通 |
| 5 | **Venus 视频硬编解 + 动态调频修复** | 修掉 DTB 里 OPP 频率放错时钟域的问题（`-ERANGE`）→ **8 路 1080p 硬编 8/8 通过**（修复前 5/8） |
| 6 | **GPU 超频**（可用、可关） | 60 秒长烤：800 MHz **+34.8%**、900 MHz **+53.0%** vs 原厂 587 MHz；1 GHz 不稳定（已剔除） |
| 7 | **电池与充电保护** | PM8150B 电量计接入；`battery-charge-limit` 滞回区间（70/65）带 37 项单测；停充实测电流归零 |
| 8 | **息屏 / 功耗** | GPIO 给面板断电，杜绝白耗电；`consoleblank` 兜底 |
| 9 | **保命与可诊断** | 异常重启自动落 TWRP；每次启动自动采集诊断快照 |
| 10 | **整机镜像打包** | 从设备导出完整 rootfs，做成可直接分发的整机镜像（不含任何个人信息） |

> 细节报告：`boot-build/CHANGELOG-2026-09-27.md`、`docs/02-使用指南.md`

---

## 五、快速开始

> 完整刷机流程见 **[`docs/01-快速开始.md`](docs/01-快速开始.md)**；下载与发布说明见
> **[`docs/04-发布与下载.md`](docs/04-发布与下载.md)**。

### 5.1 刷完是什么状态（开箱三态）

| 状态 | 内容 |
|---|---|
| ✅ **刷完就有** | 能开机进系统（约 40~60 秒）；**USB 网卡** `172.16.42.1`（Windows 免驱）+ **USB 串口**（免密 root shell）；GPU（`renderD128`，Vulkan 1.3）；视频硬编解（`/dev/video0/1`）；息屏；充电区间控制（70/65）；电池读数；Docker；WiFi 的 DHCP 客户端（`25-wlan.network`）已配好；`/data/AUTO_RECOVERY_OFF` 已带上 → **默认重启回 Linux 而不是 TWRP** |
| ⚠️ **要你做一步** | ① 改 root 密码 ② **锁掉 `armbian` 账号** ③ 重新生成 SSH 主机密钥（可选） ④ 配 WiFi（凭据已剔除，**不配就没有 WiFi**） |
| 📦 **刷之前必须先满足** | BootLoader 已解锁；`dtbo` 用**原厂**镜像；面板是 **CSOT**；电脑有 `adb`/`fastboot`（用 MiFlash2020 自带的新版）；rootfs 在 **TWRP** 里解包 |

### 5.2 默认账号与密码（已从镜像里逐项核对）

| 账号 | 密码 | 能否登录 | 权限 / 说明 |
|---|---|---|---|
| **`root`** | **`umi10linux`** | ✅ 串口（免密）/ SSH / 本地 | uid 0。SSH 侧 `PermitRootLogin yes` + `PasswordAuthentication yes`，所以**拿到镜像就知道密码 = 人人可登** |
| **`armbian`** | **`armbian`** | ✅ SSH / 本地 | uid 1000，**在 `sudo`、`docker`、`adm`、`disk`、`tty`、`render` 等组** → `sudo` 一下就是 root，**风险与 root 同级** |
| `www` | — | ❌ **已锁定**（`!`） | 宝塔面板残留账号（已无面板），无法登录，可 `userdel www` |
| `sync` | — | ❌ 已锁定（`*`） | 系统账号，shell 是 `/bin/sync` |
| 其余 21 个系统账号（`daemon`/`sshd`/`systemd-*`/`_apt`/`nobody`…） | — | ❌ 全部锁定（`*` 或 `!`） | 密码字段是锁定位，shell 为 nologin/false |

> 以上是**实际镜像里**的状态（`/etc/passwd`、`/etc/shadow`、`/etc/group` 逐项核对）。
> 串口是 `agetty --autologin root`，**插上 USB 串口就是 root shell，不需要密码** —— 这也是为什么"改密码"不能省。

**刷完请立刻执行这 4 步**（用串口或 SSH 登进去）：

```bash
passwd                      # ① 改 root 密码（默认值是本文档公开的）
passwd -l armbian           # ② 锁掉 armbian 账号（它在 sudo + docker 组！）
rm -f /etc/ssh/ssh_host_*; ssh-keygen -A; systemctl restart ssh   # ③ 唯一化 SSH 主机密钥
bash /root/wifi-connect.sh  # ④ 配 WiFi（交互式：列 WiFi → 选编号 → 输密码）
```

> ⚠️ **别把没做前两步的机器接公网。** 更彻底的做法：把
> `/etc/ssh/sshd_config.d/99-umi.conf` 里的 `PasswordAuthentication` 改成 `no`，只留密钥登录。

### 5.3 刷机命令

**前置条件**：BootLoader 已解锁；设备是 **CSOT 面板**；你手上有一份原厂底包（只为取 `dtbo.img`）。

```bash
# ① 刷 boot（28 MB）
adb reboot bootloader
fastboot flash boot boot/boot-umi-csot-ovf-wifi6-gpu-oc-final.img

# ② 刷回原厂 dtbo（★ 必须是原厂镜像，不能换、不能空）
fastboot flash dtbo <你底包里的>images/dtbo.img

# ③ 刷整机 rootfs（2.1 GB）—— 注意：它是 tar.gz 打包的根文件系统，
#    **不能** fastboot flash，要在 TWRP 恢复模式里解包：
#      重启到 TWRP → bash tools/restore-system-opensource.sh
```

> 已有 Linux 系统在跑、只是想升级 rootfs？可以 ssh 进去后自己
> `tar xzf … -C /` 覆盖（危险，先备份）。新机器一律走 TWRP。


刷完约 40~60 秒后，插上 USB 就会出现**网卡 + 串口**，然后按 §5.2 做那 4 步（改密码 / 锁 `armbian` / 换主机密钥 / 配 WiFi）。

```bash
ssh root@172.16.42.1        # 密码 umi10linux（USB 网卡，Windows 免驱）
# 或直接开串口 COMx（115200）—— 免密直接进 root shell
```

---

## 六、怎么用

完整使用手册：**[`docs/02-使用指南.md`](docs/02-使用指南.md)**。三条"连接通道"是这台机器的命脉：

| 通道 | 怎么连 | 什么时候用 |
|---|---|---|
| **USB 串口** | 插 USB → 电脑出现串口 → 开 115200 8N1 → **自动 root 登录** | SSH/WiFi 都挂了时的救命通道 |
| **USB 网卡（SSH）** | 插 USB → 电脑出网卡（Windows 免驱）→ `ssh root@172.16.42.1` | 日常开发、传文件 |
| **WiFi（SSH）** | 串口/USB 里跑 `/root/wifi-connect.sh` 配一次，之后开机自连 | 摆脱线缆 |

**三个最常用的设置**：

```bash
# 1) 配 WiFi（交互式，配置持久化，重启自动重连）
bash /root/wifi-connect.sh

# 2) 充电上限（默认充到 70% 停、65% 复充）
vi /etc/default/battery-charge-limit     # UPPER=70 / LOWER=65
systemctl restart battery-charge-limit
journalctl -u battery-charge-limit -f    # 看它决策

# 3) GPU 频率上限（默认 800 MHz；想回原厂 587 或冒险上 900 都改这里）
vi /etc/default/umi-gpu-maxfreq          # GPU_MAX_FREQ=800000000
systemctl restart umi-gpu-maxfreq
```

---

## 七、怎么自己构建

完整构建指南：**[`docs/03-自行构建.md`](docs/03-自行构建.md)**。
本目录里构建材料是**自包含**的，两条链都给了：

| 想做 | 材料 | 说明 |
|---|---|---|
| **只改 DTB → 重建 boot**（最常见） | `boot-build/` + `dtb/` | `dtc -@` 编译 DTS → 用 `replace-dtb.py` 只换 boot 镜像的 dtb 段（kernel/initrd 逐字节不动）。**可复现**：产物 sha256 = `a7e4d341…` |
| **从零做一套 rootfs** | `rootfs-build/` | Armbian `build` 框架的 umi 移植（板级配置 + 3 个 DTS + overlay + 3 个扩展），照着 `rootfs-build/BUILD.md` 跑 |

```bash
# 最常用的一条命令（改完 dtb/ 里的 DTS 后）
bash boot-build/build-boot.sh          # 自带前置检查 + 校验 + 重打包 + 打印 sha256
```

---

## 八、目录结构

```
umi-system-opensource-2026-09-27/
├── README.md                     ← 本文件（项目主页）
├── SHA256SUMS.txt                ← 全量校验清单（sha256sum -c 自检）
│
├── boot/                         【成品】boot 镜像（Venus OPP 修复 + GPU 超频档）
├── rootfs/                       【成品】整机系统镜像（Debian 13）
├── dtb/                          【源码】当前 DTS + 其编译产物 DTB
├── rootfs-config/                rootfs 侧关键配置快照（GPU 限频 / cpupower / 充电区间）
│
├── boot-build/                   【构建】boot 构建链
│   ├── BUILD.md  build-boot.sh  preflight.sh
│   ├── dts.patch                 基线 DTS → 当前 DTS 的完整补丁
│   ├── baseline/                 Armbian 原始 DTB / 反编译 DTS（补丁基准）
│   ├── tools/                    replace-dtb.py / rebuild-boot.py / gen-ovf-nodes.py
│   └── CHANGELOG-2026-09-27.md
│
├── rootfs-build/                 【构建】rootfs 构建链（Armbian build 的 umi 移植）
│   ├── BUILD.md  apply-umi-port.sh  wsl-setup.md
│   ├── config/boards/xiaomi-umi.conf
│   ├── patch/kernel/…/dt/        3 个板级 DTS（csot / sms / common）
│   └── userpatches/              overlay（服务脚本）+ 扩展 + customize-image.sh
│
├── docs/                         【文档】见下表
└── tools/                        【工具】还原 / 拆片 / 发布
```

**文档索引（`docs/`）**

| 文档 | 内容 |
|---|---|
| [`01-快速开始.md`](docs/01-快速开始.md) | 刷机全流程、首启必做（账号与加固）、验收命令 |
| [`02-使用指南.md`](docs/02-使用指南.md) | 账号密码 / 配 WiFi / 连串口 / USB 网卡 / 充电上限 / GPU / 服务清单 / 故障排查 |
| [`03-自行构建.md`](docs/03-自行构建.md) | 重建 boot、从零构建 rootfs、可复现性校验 |
| [`04-发布与下载.md`](docs/04-发布与下载.md) | 产物清单、校验、发布到 releases 仓库的流程、发布前检查清单 |
| [`RELEASE-NOTES.md`](docs/RELEASE-NOTES.md) | GitHub Release 正文模板（已按本版填好） |

---

## 九、⚠️ 安全与禁忌（刷机前必读）

### 绝对不要碰分区

**只写 `boot` 和 `userdata`。** 以下分区一旦擦除，**基带 / IMEI / WiFi MAC 会永久丢失且无法恢复**：

```
modemst1  modemst2  fsg  fsc  persist  mdm1m9kefs1  mdm1m9kefs2  mdm1m9kefs3
```

- 刷机工具请用 **MiFlash2020 自带的新版 fastboot**（旧版 fastboot 有 sparse 截断 bug）。

### 这份镜像的已知风险面

| 项 | 说明 | 缓解 |
|---|---|---|
| 默认密码 + 允许密码登录 | `sshd` 放开 `PermitRootLogin`/`PasswordAuthentication`，而 `root`/`armbian` 的密码是本文档公开的值 | 首启 `passwd` + `passwd -l armbian`；或改 `PasswordAuthentication no` + 放自己的公钥 |
| **`armbian` 账号在 `sudo` 与 `docker` 组** | 用它登录后 `sudo` 即 root（`docker` 组本身也等价 root），**与 root 同级风险** | **务必 `passwd -l armbian`**，或 `userdel -r arming`（确认不需要它） |
| SSH 主机密钥随镜像分发 | 所有人共用同一对主机密钥（中间人风险） | `rm -f /etc/ssh/ssh_host_*; ssh-keygen -A; systemctl restart ssh` |
| `umi-put`（8080 无鉴权文件服务） | **已默认不自启** | 需要时 `systemctl start umi-put`，别暴露到公网 |
| GPU 超频 | 无过热降频保护 | 改 `/etc/default/umi-gpu-maxfreq` 回 `587000000` |
| 保命机制会写 `misc` 分区 | 故意设计：异常重启落 TWRP | 正常运行由 `/data/` 下的标志位维持 |

### 一个真会崩机的坑

**不要读 `/sys/bus/nvmem/devices/qfprom0/nvmem`（efuse）** —— 那个电源域开机后会断电，
再访问它的 MMIO 会直接 **异步 SError → Kernel panic**。同理：**任何已断电外设的 MMIO 都不要碰**。

---

## 十、许可与出处

| 内容 | 出处 / 许可 |
|---|---|
| 内核、DTS/DTB | Armbian `sm8250` family（基于 sm8250-mainline，上游内核主线）→ **GPL-2.0** |
| `qca6390-pmu` / `pwrseq_qcom_wcn` 配方 | 上游 `sm8250-xiaomi-elish` 补丁、主线 `drivers/power/sequencing/` → **GPL-2.0** |
| Mesa / Turnip / Freedreno | freedreno 上游 → MIT 系许可 |
| 本项目原创部分（`tools/`、`docs/`、服务脚本、构建脚本） | 作者保留权利，正式许可证待定（见 `NOTICE-许可与出处.md`） |
| 厂商二进制（`dtbo.img`、`a650_zap.mbn` 等） | **不在本发布内**，需从你自己的机器/底包中取得 |

> 本发布**不含**任何厂商专有镜像（请在 §六 刷机时自行准备原厂 `dtbo`）。
