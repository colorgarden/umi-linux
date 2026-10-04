# UmiLinux v2026-09-27 —— 小米 10 的整机 Linux 镜像 + 配套 boot

> 用于 GitHub Release 的正文（`gh release create --notes-file docs/RELEASE-NOTES.md`）。
> 仓库：<https://github.com/misaka-link/umi-linux>　｜　许可：GPL-2.0

---

## Xiaomi Mi 10（umi / SM8250）的原生 Linux 系统

小米 10 的**纯 Linux 整机镜像**：**Debian 13 trixie + 内核 6.18.52 LTS**，
不要 Android、无桌面，当无头 ARM 小服务器用。

### 附件

| 附件 | 大小 | sha256 |
|---|---|---|
| `boot-umi-csot-ovf-wifi6-gpu-oc-final.img` | 28,209,152 B | `a7e4d341e35a663683bf41a8fe99d472bc6b8568aa1b54b05901dc7e9f2d842a` |
| `umi-system-opensource-2026-09-27.tar.gz` | 2,123,920,669 B | `51f4b38d23b71d7d70b7472b3ef95e673c0e984f1f7c489c75305fc4fb2d645f` |
| `SHA256SUMS.txt` | — | 全量清单，`sha256sum -c` 自检 |

### 这版有什么

- **能跑**：WiFi 6（QCA6390）、USB 有线网卡（NCM，Windows 免驱）+ USB 串口控制台、
  Adreno 650 GPU（Vulkan 1.3 / OpenGL 4.6 / GLES 3.2）、Venus 视频硬编解、PM8150B 电量计与充电区间控制、真息屏
- **已修**：Venus 动态调频（8 路 1080p 硬编 5/8 → **8/8**）、GPU 超频（800 MHz **+34.8%** / 900 MHz **+53.0%**）
- **镜像里不含个人信息**：WiFi 凭据、设备 MAC / 序列号、历史日志与诊断转储均已不在镜像内

### 🔑 默认账号（刷完就有）

| 账号 | 密码 | 能否登录 | 说明 |
|---|---|---|---|
| **`root`** | **`umi10linux`** | ✅ 串口（**免密**）/ SSH / 本地 | **首启必须改** |
| **`armbian`** | **`armbian`** | ✅ SSH / 本地 | ⚠️ **在 `sudo` + `docker` 组**，等于第二把 root 钥匙 → **必须 `passwd -l armbian` 锁掉** |
| `www` / `sync` / 其余 21 个系统账号 | — | ❌ 全部已锁定 | 无 shell 或锁定位 |

> 串口是自动登录 root 的（`agetty --autologin root`），打开串口就进 root shell，不需要密码。

### 刷完就能用吗？

**能。** 开机约 40~60 秒后，插上 USB 就有网卡（`172.16.42.1`，Windows 免驱）和串口，
GPU / 编解码 / 息屏 / 充电控制 / Docker 都已就绪，不需要额外装东西。
**只有两件事要你亲手做**：① 改密码并锁掉 `armbian` ② 配一次 WiFi（镜像里不含 WiFi 凭据）。

### ⚠️ 刷机前必读

1. 机型面板必须是 **CSOT**；BootLoader 必须已解锁。
2. **必须保留原厂 `dtbo.img`**：`fastboot flash dtbo <你底包里的>images/dtbo.img`，不能换、不能空。
3. **绝不碰基带分区**：`modemst1/2`、`fsg`、`fsc`、`persist`、`mdm1m9kefs*`。
4. `*.tar.gz` 是**根文件系统打包**，不能 `fastboot flash`，要在 **TWRP 里解包**（`tools/restore-system-opensource.sh`）。

### ⚠️ 首启必做

```bash
passwd                                                  # 改 root 密码
passwd -l armbian                                       # 锁掉 armbian（在 sudo + docker 组）
rm -f /etc/ssh/ssh_host_*; ssh-keygen -A; systemctl restart ssh   # 唯一化主机密钥
bash /root/wifi-connect.sh                              # 配 WiFi
```

### 已知限制

- **屏幕不驱动**（无面板驱动，主动断电息屏）→ **开机后屏幕黑是正常的**，无 GUI/桌面
- **无蜂窝基带**（不能打电话 / 短信 / SIM 上网）、无摄像头 / 指纹 / NFC
- **蓝牙、音频未验证**
- USB 默认是 **gadget**（网卡 + 串口），要接键鼠/U 盘需自行切换 host 角色
- **不休眠**（sleep/suspend 被主动 mask，服务器要常在线）
- GPU 超频档**没有过热降频保护**，长期满载请自行关注温度
- ⚠️ **容器里跑 ANGLE 系 GL 应用**（Chromium / Electron / CEF、无头浏览器、Kasm / Waydroid）会命中
  **Mesa 25.0.7 的 ANGLE-on-freedreno bug** → `BaseVertex` 绘制错乱（上游 **25.2.1** 才修）
  → 用 **drirc 伪装 `GL_VENDOR`** 绕过，**不需要换内核 / 重刷镜像**
- ⚠️ **GPU 频率**：镜像默认上限 **800 MHz 属超频档**（865 原厂熔丝验证最高档是 **587 MHz**）；
  若把 `min_freq` 也写成 800（钉死）则**再也不会降频**，而本内核**无过热降频保护**
  → 建议改回 `587000000`（`/etc/default/umi-gpu-maxfreq`）。本项目现已改回 587

完整能力矩阵见仓库 `README.md`，刷机流程见 `docs/01-快速开始.md`，使用手册见 `docs/02-使用指南.md`。

```bash
BASE=https://github.com/misaka-link/umi-linux/releases/download/v2026-09-27
curl -LO $BASE/boot-umi-csot-ovf-wifi6-gpu-oc-final.img
curl -LO $BASE/umi-system-opensource-2026-09-27.tar.gz
```
