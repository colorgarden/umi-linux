# NOTICE —— 许可与出处

> 本仓库是**混合来源**的产物。整体以 **GPL-2.0** 发布（见 [`LICENSE`](LICENSE)），
> 各部分来源与许可如下。

---

## 一、按内容分

| 内容 | 位置 | 出处 | 许可 |
|---|---|---|---|
| 内核、DTS/DTB | `dtb/`、`boot/`、`boot-build/baseline/`、`boot-build/dts.patch` | Armbian `sm8250` family（基于 sm8250-mainline，最终源自 Linux 主线） | **GPL-2.0** |
| `qca6390-pmu` 配方 | `boot-build/dts.patch` 中相关 hunk | 上游 `sm8250-xiaomi-elish` 补丁（Jianhua Lu，2024，已进主线） | **GPL-2.0** |
| `pwrseq_qcom_wcn` 相关改动 | 同上 | 主线 `drivers/power/sequencing/`（Bartosz Golaszewski） | **GPL-2.0** |
| 板级移植包 | `rootfs-build/`（板级配置、DTS、overlay、扩展） | 本项目原创（内核与 DTS 例外，见上） | **GPL-2.0** |
| 构建/刷机/发布工具 | `boot-build/tools/*.py`、`boot-build/build-boot.sh`、`tools/*.sh` | 本项目原创 | **GPL-2.0** |
| 系统服务与脚本（镜像内） | `battery-charge-limit`、`panel-off`、`wifi-connect.sh`、`umi-venus-enable`、`umi-gpu-maxfreq` 等 | 本项目原创 | **GPL-2.0** |
| 文档 | `README.md`、`docs/*` | 本项目原创 | **GPL-2.0** |
| Mesa / Turnip / Freedreno | 镜像内 | freedreno 上游 | MIT 系 |
| QCA6390 固件 | 镜像内 | `kvalo/ath11k-firmware` / linux-firmware | 见其自带许可 |
| Debian 用户空间 | 镜像内 | Debian 项目 | 各自开源许可 |
| **小米厂商二进制**（`dtbo.img`、`a650_zap.mbn` 等） | **不在本仓库内** | 小米官方 | **未包含 / 不可再分发** |

---

## 二、几个必须说清的点

1. **本发布不含任何厂商专有镜像。**
   `dtbo.img`（ABL 的板级 overlay）、`a650_zap.mbn`（GPU zap shader，用的是小米 elish 的签名版本）
   都需要使用者**从自己机器的底包里取得**。这一点在 `docs/01-快速开始.md` 里有明确步骤。
2. **内核与 DTS 是 GPL-2.0。** 你基于它们做的修改，**再分发时要遵守 GPL-2.0**
   （提供对应源码）。本发布已经把 DTS 源码、补丁、构建脚本都给了，属于合规做法；
   若你改了内核本身，请一并提供你的内核源码与补丁。
3. **本仓库整体以 GPL-2.0 发布。**
   选它的原因很简单：设备树补丁与内核侧改动本就是 GPL-2.0 上游的衍生作品，整体保持一致
   最省事，任何人拿去改、拿去再分发都不必再确认许可兼容性。完整条款见 [`LICENSE`](LICENSE)。
   如果你只想用其中某段脚本，也可以按 GPL-2.0 单独取出使用。
4. **商标**：Xiaomi、Mi 10、Qualcomm、Snapdragon、Adreno 等为其各自所有者的商标。
   本项目与小米/高通**无隶属或背书关系**，属于社区作品。

---

## 三、给再分发者的最小操作清单

- [ ] 保留本文件与 `LICENSE`
- [ ] 不要把 `dtbo.img` / `a650_zap.mbn` 等厂商二进制打进你的发行包
- [ ] 如果你改过 DTS/内核，附上你的源码或补丁
- [ ] 在 Release 说明里注明"首启必须改 root 密码"（镜像默认允许密码登录）
- [ ] 保留 `SHA256SUMS.txt` 并说明校验方式
