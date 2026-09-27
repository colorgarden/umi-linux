# 构建 umi 的 Armbian minimal 镜像

> 目标产物：**无桌面、带 Docker、GPU 已启用、电池已启用、息屏已预置**的 Armbian 镜像
> 内核：**6.18 LTS**（Armbian sm8250 family 的 current 分支）

---

## 一、前置条件

| 项 | 要求 |
|---|---|
| 构建主机 | **Linux**（Ubuntu 22.04 / 24.04 推荐）。Windows 可用 **WSL2** |
| 磁盘 | ≥ 50 GB 可用（源码 + 工具链 + 输出） |
| 内存 | ≥ 8 GB（4 GB 会很慢） |
| 网络 | 能访问 github.com / kernel.org / debian 源 |
| 权限 | 需要 `sudo`（构建过程中要 mount / chroot） |

> WSL2 上注意：源码**不要**放在 `/mnt/c/` 下（跨文件系统极慢，且 chroot 会出问题）。
> 放在 WSL 自己的文件系统里，比如 `~/build`。
>
> **WSL2 环境的创建步骤见 [wsl-setup.md](wsl-setup.md)**（磁盘固定在 `E:\WSL2`）。

---

## 二、准备 armbian/build

```bash
sudo apt update
sudo apt install -y git

cd ~
git clone --depth 1 https://github.com/armbian/build.git
cd build
```

先确认 sm8250 family 的 current 内核版本（本移植按 6.18 验证）：

```bash
grep -A2 'current)' config/sources/families/sm8250.conf
# 期望看到 KERNEL_MAJOR_MINOR="6.18"
```

如果这里不是 6.18 了，把 `patch/kernel/archive/sm8250-6.18/dt/` 里的三个 DTS
复制到对应版本号的 `dt/` 目录即可（DTS 本身跨小版本基本通用）。

---

## 三、应用 umi 移植

把本目录（`armbian-umi-port/`）拷到构建机上，然后：

```bash
cd ~/build
~/armbian-umi-port/apply-umi-port.sh ~/build
```

脚本会做四件事：

1. 装 `config/boards/xiaomi-umi.conf`（板级配置）
2. 装三个设备树到 `patch/kernel/archive/sm8250-6.18/dt/`
3. 装 `packages/bsp/xiaomi-umi/zz-update-abl-kernel`
4. 校验依赖的充电补丁是否都在

> **为什么放 `dt/` 就够了**：Armbian 的 `0000.patching_config.yaml` 里有
> ```yaml
> dts-directories:
>   - { source: "dt", target: "arch/arm64/boot/dts/qcom" }
> auto-patch-dt-makefile:
>   - { directory: "arch/arm64/boot/dts/qcom", config-var: "CONFIG_ARCH_QCOM" }
> ```
> 放在 `dt/` 里的 .dts/.dtsi 会被自动复制进内核源码树，Makefile 也会被自动打补丁，
> **不需要手写 Makefile 补丁**。

---

## 四、构建

```bash
cd ~/build

./compile.sh build \
    BOARD=xiaomi-umi \
    BRANCH=current \
    RELEASE=trixie \
    BUILD_MINIMAL=yes \
    BUILD_DESKTOP=no \
    KERNEL_CONFIGURE=no \
    ENABLE_EXTENSIONS="docker-ce umi-usb-host umi-firstboot umi-kernel-tweaks" \
    EXPERT=yes
```

参数说明：

| 参数 | 作用 |
|---|---|
| `BRANCH=current` | 用 sm8250 family 的 current 分支 = **6.18 LTS**（想要 6.19 就用 `edge`） |
| `RELEASE=trixie` | Debian 13。要 Ubuntu 24.04 就换 `noble` |
| `BUILD_MINIMAL=yes` | **纯 CLI，不装桌面** |
| `ENABLE_EXTENSIONS="docker-ce …"` | 三个扩展，见下表 |
| `KERNEL_CONFIGURE=no` | 不弹内核配置菜单 |

**三个扩展分别做什么：**

| 扩展 | 作用 |
|---|---|
| `docker-ce` | Armbian 官方扩展：构建时从 Docker 官方源装好 `docker-ce` / `containerd.io` / `docker-compose-plugin` |
| `umi-usb-host` | 打开 USB host 所需内核选项（关键是 `CONFIG_USB_ROLE_SWITCH`）→ 键鼠可用 |
| `umi-firstboot` | 预置首次启动向导，root 密码 = `root`，全自动无人值守 |
| `umi-kernel-tweaks` | 把 apparmor 加进 `CONFIG_LSM`（让已编译的 AppArmor 真正生效）+ 服务器向内核选项 |

> 也可以把这一长串存成 `userpatches/config-umi.conf`，之后 `./compile.sh umi` 即可。

首次构建约 **1–2 小时**（要下载工具链、编内核）。
重复构建会走 ccache，快很多。想强制干净重建加 `CLEAN_LEVEL=make-kernel`。

**产物**在 `output/images/`，会长这样：

```
Armbian_<版本>_Xiaomi-umi_trixie_current_6.18.x_minimal.rootfs.img
Armbian_<版本>_Xiaomi-umi_trixie_current_6.18.x_minimal.boot_sm8250-xiaomi-umi-csot.img
Armbian_<版本>_Xiaomi-umi_trixie_current_6.18.x_minimal.boot_sm8250-xiaomi-umi-sms.img
```

- `*.boot_<dtb>.img` → 刷到手机的 **`boot`** 分区
- `*.rootfs.img` → 刷到给 Linux 用的分区（不要安卓的话，直接刷 `userdata`）

---

## 五、刷机

**前置：Bootloader 已解锁**（小米10 需要社区等级/答题，或走 `Xiaomi-HyperOS-BootLoader-Bypass`）。

⚠️ **先确认你的面板型号**（决定用哪个 boot 镜像）：

```bash
# 方法一：从设备树读（需 root）
adb shell su -c 'cat /sys/firmware/devicetree/base/model'
# 方法二：拨号 *#*#6484#*#* 进 CIT → LCM Information 看厂商前缀
```

本机已知是 **CSOT（华星光电）**，所以用 `..._boot_sm8250-xiaomi-umi-csot.img`。

```bash
adb reboot bootloader

# 刷 boot
fastboot flash boot Armbian_..._minimal.boot_sm8250-xiaomi-umi-csot.img

# 刷 rootfs（不要安卓 → 直接刷 userdata；想保留安卓就换成别的空闲分区）
fastboot flash userdata Armbian_..._minimal.rootfs.img

fastboot reboot
```

> **如果 umi 是 A/B 双槽**（先跑 `fastboot getvar current-slot` 确认），
> 那么分区名可能是 `boot_a`/`boot_b`，用 `fastboot flash boot_a ...`。
> A/B 设备还能做到"安卓留在 A 槽、Linux 住 B 槽"。

---

## 六、镜像开箱即有的东西

构建出来的镜像**默认**已经是这样（不需要你手动配）：

| 项 | 默认值 | 由谁设置 |
|---|---|---|
| **SSH** | 已启用、开机自启 | `customize-image.sh` |
| **root 登录** | 允许（`PermitRootLogin yes`） | `customize-image.sh` |
| **root 密码** | `root` | `customize-image.sh` + `umi-firstboot.sh` 双保险 |
| **备用账号** | `armbian` / `armbian` | `umi-firstboot.sh` |
| **时区** | `Asia/Shanghai` | `umi-firstboot.sh` |
| **启动目标** | `multi-user.target`（纯 CLI） | `customize-image.sh` |
| **息屏** | `consoleblank=60` | 板级配置的 cmdline |
| **USB 键鼠** | 插 OTG 转接头即用 | 设备树 + `umi-usb-host` 扩展 |
| **USB 网卡** | 插电脑即出现 RNDIS | 设备树 + `usbgadget-rndis.service` |
| **Docker** | 已安装 | `docker-ce` 扩展 |
| **常用工具** | htop / tmux / v4l-utils / i2c-tools / dtc / usbutils 等 | `customize-image.sh` |
| **休眠挂起** | 已 mask | `customize-image.sh` |
| **上手说明** | `/root/README-mi10.md` | `customize-image.sh` |

登录方式：

```bash
ssh root@<设备IP>        # 密码 root
# 或
ssh armbian@<设备IP>     # 密码 armbian
```

---

## 七、首次开机后必做

```bash
# 1) 整盘扩容（rootfs 镜像是按最小尺寸生成的，Docker 会撑爆）
sudo resize2fs $(findmnt -no SOURCE /)
df -h /

# 2) 确认息屏生效（AMOLED 黑屏 = 像素不发光）
cat /sys/class/graphics/fb0/blank      # 期望 4
# 想立刻手动黑屏：echo 4 | sudo tee /sys/class/graphics/fb0/blank

# 3) 联网（USB 线插上就是网卡，systemd 服务默认已启用）
ip -br link
# WiFi 备用：
nmcli device wifi list && nmcli device wifi connect "<SSID>" password "<密码>"
```

---

## 八、验收清单

```bash
# --- GPU ---
ls -l /dev/dri/                        # 期望出现 renderD128
dmesg | grep -i -E "adreno|msm|zap"    # 不应有 "failed to load zap shader"

# --- 电池 ---
ls /sys/class/power_supply/            # 期望有 BAT0 / AC / USB
cat /sys/class/power_supply/*/capacity 2>/dev/null
cat /sys/class/power_supply/*/status

# --- 视频编解码 (Venus) ---
dmesg | grep -i venus
v4l2-ctl --list-devices
ffmpeg -hwaccel v4l2m2m -c:v h264_v4l2m2m -i test.mp4 -f null -

# --- WiFi ---
lspci -nn | grep -i qualcomm
dmesg | grep -i ath11k

# --- Docker ---
docker version
docker run --rm --device /dev/dri hello-world
```

---

## 九、故障排查

### 开不了机 / 卡在启动
刷回之前备份的 boot 镜像即可（`fastboot flash boot boot-backup.img`）。
**刷之前一定要先备份**：
```bash
adb shell su -c 'dd if=/dev/block/by-name/boot of=/sdcard/boot-backup.img'
adb pull /sdcard/boot-backup.img
```

### 电池相关的节点导致编译失败
如果 `&pm8150b_charger` / `&pm8150b_fg` 报 "undefined label"，说明当前补丁集里
没有 0027/0029 那两个补丁。检查：
```bash
ls patch/kernel/archive/sm8250-6.18/ | grep -E "0027|0029|0037"
```
缺哪个就去 `patch/kernel/archive/sm8250-6.19/` 或 6.12 目录里找同名文件补上。

### 构建失败在 `config/boards/xiaomi-umi.conf` 某一行
最常见的是板级配置里引用了**已过时的 Armbian 内部文件名**。已知坑：

| 旧写法（会失败） | 现代写法 |
|---|---|
| `/etc/apt/sources.list.d/armbian.list` | **`/etc/apt/sources.list.d/armbian.sources`** |

Armbian 只在 `SKIP_ARMBIAN_REPO=yes` 时把 `armbian.sources` 改名成 `armbian.sources.disabled`，
所以**不能无条件 `mv`** —— 要加 `[ -e ]` 守卫，否则文件不存在时 `set -e` 直接中断构建。

本移植包已经按现代写法改好了。如果你从别处抄板级配置，**先对照官方同平台板级配置核实**
（`config/boards/xiaomi-elish.conf` 是最好的参照，它一直在维护）。

### 某个包安装失败导致整个构建挂掉
板级配置里 `chroot_sdcard_apt_get_install` 一次装多个包时，只要有一个在目标 release 里不存在就会整体失败。
本移植包改成了**逐个安装 + 失败告警跳过**：

```bash
for pkg in qbootctl qrtr-tools unudhcpd mkbootimg device-tree-compiler ; do
	do_with_retries 2 chroot_sdcard_apt_get_install "$pkg" \
		|| display_alert "Skipping package" "${pkg} 安装失败，继续" "warn"
done
```

### 电量显示不出来
先确认电量计到底是哪一颗（在现有 MIUI 上跑）：
```bash
adb shell ls /sys/bus/i2c/devices/
adb shell cat /sys/class/power_supply/*/name
```
如果显示的是 `bq27z561` 之类**外挂**芯片，就照 Armbian 补丁 `0022` 里 elish 的写法，
在对应 i2c 总线上加节点，而不是用 `&pm8150b_fg`。

### GPU 还是没起来
```bash
dmesg | grep -i -E "zap|adreno|gmu"
```
若报 `failed to load zap shader` → 固件缺失。确认：
```bash
ls -l /lib/firmware/qcom/sm8250/a650_zap.mbn /lib/firmware/qcom/a650_gmu.bin
```
没有的话装 `armbian-firmware-full`，或者把 `firmware-name` 改成分片路径
`qcom/sm8250/xiaomi/elish/a650_zap.mbn`（如果装了 Armbian 固件包的话）。

### 内核升级后息屏失效
`zz-update-abl-kernel` 重建 boot 镜像时已带上 `consoleblank=60`。
如果手动改过，检查 `/proc/cmdline` 里有没有 `consoleblank=60`。

---

## 十、这个移植改了什么（对照原始 fork 版本）

| # | 改动 | 原因 |
|---|---|---|
| 1 | GPU `tatus` → `status` | 一个字母的笔误，导致 Adreno 650 静默禁用 |
| 2 | GPU zap shader 路径改为主线通用 `qcom/sm8250/a650_zap.mbn` | 原路径指向 elish 专属目录，依赖 Armbian 固件包 |
| 3 | `battery` 节点取消注释并修正参数 | 原参数（4300mAh/16.6Wh）是从小米平板5 抄来的 |
| 4 | 新增 `&pm8150b_charger` / `&pm8150b_fg` | 原来只有一行 `//TODO: Port the CHARGER Driver` |
| 5 | 新增 BQ25970 快充节点（默认注释） | 原 DTS 里有注释掉的 `bq25970-standalone`，附上启用说明 |
| 6 | cmdline 加 `consoleblank=60` | 息屏（AMOLED 黑屏等效熄火，防烧屏） |
| 7 | 板级配置：`BOARDFAMILY="sm8250"`（原来是 `qcom-abl`） | 用官方 family 才能吃到 `qcom_fg` / `pm8150b_charger` 补丁 |
| 8 | 板级配置：加 initrd 固件 hook | 保证 GPU / Venus 固件早期可加载 |
| 9 | `zz-update-abl-kernel`：cmdline 补 `consoleblank=60` | 原版硬编码 cmdline，内核升级后息屏设置会丢 |
| 10 | `zz-update-abl-kernel`：面板探测失败时报错而非静默默认 csot | 避免打错 DTB |
| 11 | 设备树：新增 USB OTG（`pm8150b_typec` + connector + `pm8150b_vbus` + dwc3 端点） | 让 USB 口能切 host 模式接键鼠（照抄补丁 0038 的 oneplus 实现） |
| 12 | 设备树：`&usb_1_dwc3` 补 `role-switch-default-mode = "peripheral"` | 默认当 device（RNDIS 网卡），插外设自动切 host |
| 13 | 扩展 `umi-usb-host.sh`：打开 `CONFIG_USB_ROLE_SWITCH` 等 | **defconfig 里没有这一项，不开的话 `usb-role-switch` 属性完全无效** |
| 14 | 扩展 `umi-firstboot.sh`：预置首次启动向导 | root 密码 = `root`，无人值守 |
| 15 | `customize-image.sh`：root 密码 / `PermitRootLogin yes` / sshd 自启 / 常用工具 | 开箱即可 SSH root 登录 |
| 16 | `customize-image.sh`：`systemctl mask sleep/suspend/hibernate` | 服务器不该睡 |

---

## 十一、测试与「不重建就改镜像」

### 11.1 单测

`tests/test-charge-limit.sh` —— 限充脚本的滞回逻辑回归测试，**纯 bash，与架构无关**，
在 x86 的 WSL 里也能直接跑：

```bash
bash tests/test-charge-limit.sh
# 或指定被测脚本
bash tests/test-charge-limit.sh /usr/local/bin/battery-charge-limit
```

三层覆盖：

| 层 | 测什么 | 数量 |
|---|---|---|
| A | `decide()` 纯函数穷举：电量 × 状态 的组合，断言「动作 + 新状态」 | 20 |
| B | 端到端：造假 sysfs 树（`BAT0/capacity` + `pm8150b_charger/charging_enabled`），真跑脚本，断言写入序列 | 10 |
| C | 配置校验（非法 `UPPER` 拒绝启动、`UPPER<=LOWER` 告警）与内核原生 `charge_control_end_threshold` 分支 | 7 |

B 层用了一个小技巧来区分「没写」和「重复写了同样的值」：
`charging_enabled` 是普通文件，脚本每次真正写入都会刷新 mtime，
所以断言「值不变 **且** mtime 不变」才能证明中间区间确实没动手。

脚本为可测性做了两处设计（生产行为不变）：
- `decide()` 把决策从主循环里抽成纯函数
- `BATTERY_CHARGE_LIMIT_LIB=1` 时只加载函数、不碰 `/sys`、不进主循环
- `SYSFS_ROOT` 可覆盖，指向假 sysfs 树

### 11.2 只改一个文件时，不必重建整个镜像

改了 overlay 里的脚本后，重跑一次完整构建要重新 clone Armbian + 编译内核 + 打 rootfs，
代价很大。而 rootfs 就是一个普通 ext4 镜像，可以直接挂载替换文件：

```bash
sudo bash tests/patch-rootfs-charge-limit.sh
```

它会：只读挂载确认现状 → 可写挂载替换 → **就地跑单测**（单测不过就中止，不把坏东西留下）
→ 核对 systemd 单元与 `/etc/default` → 卸载 → 重算 4 个 sha256。

配套的完整性检查：

```bash
sudo bash tests/check-rootfs-integrity.sh
```

跑 `e2fsck -fn`（只读，不改）+ `sha256sum -c` + 确认关键文件在位。

> 注意：这两个脚本是给 **WSL/Linux 上的 root** 用的。脚本支持环境变量覆盖路径：
> `OUT=<镜像目录> IMG=<rootfs.img> bash check-rootfs-integrity.sh`。
> 镜像文件名变了要同步改 `IMG=`。
