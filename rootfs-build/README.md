# armbian-umi-port — 小米10 (umi) 无头服务器移植包

给 `armbian/build` 用的 umi 板级配置 + 设备树 + BSP 脚本 + 镜像定制。
**目标：无桌面、带 Docker、GPU 启用、电池启用、息屏已预置、SSH root/root 可直连、USB 键鼠可用。**

## 快速开始

**Windows 用户**：先按 [wsl-setup.md](wsl-setup.md) 建好 WSL2（磁盘在 `E:\WSL2`），然后：

```bash
# 在 WSL 里一键完成（装依赖 → 克隆 → 应用移植 → 构建）
bash ./build-in-wsl.sh
```

**已有 Linux 构建机**：

```bash
git clone https://github.com/armbian/build.git ~/build
./apply-umi-port.sh ~/build
cd ~/build && ./compile.sh build \
    BOARD=xiaomi-umi BRANCH=current RELEASE=trixie \
    BUILD_MINIMAL=yes BUILD_DESKTOP=no KERNEL_CONFIGURE=no \
    ENABLE_EXTENSIONS="docker-ce umi-usb-host umi-firstboot" EXPERT=yes
```

完整说明见 **[BUILD.md](BUILD.md)**。

## 目录结构

```
config/boards/xiaomi-umi.conf                     板级配置（family / 内核 / cmdline / BSP 钩子）
patch/kernel/archive/sm8250-6.18/dt/
    sm8250-xiaomi-umi-common.dtsi                 主设备树（已修复，含 USB OTG）
    sm8250-xiaomi-umi-csot.dts                    CSOT 面板变体（本机是这种）
    sm8250-xiaomi-umi-sms.dts                     三星面板变体
packages/bsp/xiaomi-umi/
    zz-update-abl-kernel                          内核升级后重建 ABL boot 镜像
userpatches/
    extensions/umi-usb-host.sh                    打开 USB host 内核选项（关键：USB_ROLE_SWITCH）
    extensions/umi-firstboot.sh                   首次启动预设（root 密码 = root）
    customize-image.sh                            chroot 内：root 密码 / SSH / 常用工具
gen-dts.py                                        从原始设备树生成修复版的脚本
apply-umi-port.sh                                 一键应用到 armbian/build
build-in-wsl.sh                                   WSL 里的一键构建脚本
wsl-setup.md                                      WSL2 环境搭建（磁盘固定在 E:\WSL2）
```

## 镜像默认行为

| 项 | 默认 |
|---|---|
| SSH | 启用、自启，**允许 root 登录** |
| 账号 | `root` / `root`，另有 `armbian` / `armbian`（**这是构建框架的出厂默认值**；本项目发布的成品镜像以 `../docs/01-快速开始.md` 里的账号表为准） |
| 桌面 | 无（`multi-user.target`） |
| 息屏 | `consoleblank=60`（AMOLED 黑屏 = 等效熄屏） |
| USB 键鼠 | 插 OTG 转接头即用 |
| USB 网卡 | 插电脑出现 RNDIS |
| Docker | 已装 |
| 休眠 | 已 mask |

## 本包相对原始版本的修复

原始 umi 支持来自 `Archfx/armbian-build-bpi`（armbian/build 的 fork，官方已移除 umi）。
共 16 项改动，主要有：

1. **GPU**：`&gpu { tatus = "okay"; }` → `status = "okay"`（一个字母的笔误让 Adreno 650 静默禁用）
2. **GPU 固件**：zap shader 路径改为主线通用 `qcom/sm8250/a650_zap.mbn`
3. **电池**：取消 `battery` 节点注释，参数从"平板5 的值"修正为小米10 规格；新增 `&pm8150b_charger` / `&pm8150b_fg`
4. **USB 键鼠**：新增 `&pm8150b_typec` + connector + `&pm8150b_vbus` + dwc3 端点，并打开 `CONFIG_USB_ROLE_SWITCH`
5. **息屏**：cmdline 预置 `consoleblank=60`
6. **SSH / root**：`customize-image.sh` 里直接设好，开箱即用
7. **板级配置**：改用官方 `sm8250` family（才能吃到 `qcom_fg` / `pm8150b_charger` 补丁），并加 initrd 固件 hook

改动逐条对照见 BUILD.md 第十节。

## 已验证 / 待验证

| 项 | 状态 |
|---|---|
| 设备树语法（花括号平衡、无 `tatus` 残留） | ✅ 已校验（127/127） |
| 依赖的内核补丁（0027/0029/0037/0038）在 6.18 补丁集里存在 | ✅ 已核对 |
| 内核配置 `CONFIG_CHARGER_QCOM_SMB5` / `CONFIG_BATTERY_QCOM_FG` 已是 `y` | ✅ 已核对 |
| `&pm8150b_charger` 写法 | ✅ 照抄补丁 0037 的 oneplus 示例 |
| USB OTG 配置 | ✅ 照抄补丁 0038 的 oneplus 实现 |
| 所有 shell 脚本语法 | ✅ `bash -n` 全过 |
| **`&pm8150b_fg`（PM8150B 内置电量计）** | ⚠️ **待实机验证** —— 没有现成的 Armbian sm8250 设备用过它 |
| **整体能否成功构建并启动** | ⚠️ **未验证** —— 需要跑一次构建 |

**上机第一件事**：在现有 MIUI 上确认电量计型号
```bash
adb shell ls /sys/bus/i2c/devices/
adb shell cat /sys/class/power_supply/*/name
```
如果是外挂芯片（如 `bq27z561`），要改成照 Armbian 补丁 `0022` 的写法挂 i2c 节点。

## 相关文档

- [`../README.md`](../README.md) — 项目主页（能力矩阵 / 启动链 / 做了什么）
- [`../docs/02-使用指南.md`](../docs/02-使用指南.md) — 刷完怎么用（WiFi / 串口 / 充电上限 / GPU）
- [`../docs/03-自行构建.md`](../docs/03-自行构建.md) — 构建总指南（含 boot 链）
- [BUILD.md](BUILD.md) — 本构建包的完整参数说明与 16 项改动对照
- [wsl-setup.md](wsl-setup.md) — 在 Windows 上用 WSL2 搭构建环境
