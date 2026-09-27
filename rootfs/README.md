# rootfs —— 整机系统镜像

本目录存放**整机系统镜像**（设备根文件系统的完整打包）。

| 文件 | 大小 | sha256 |
|---|---|---|
| `umi-system-opensource-2026-09-27.tar.gz` | 2,123,920,669 B（1.98 GiB） | `51f4b38d23b71d7d70b7472b3ef95e673c0e984f1f7c489c75305fc4fb2d645f` |

> ⚠️ **这个镜像不在 git 仓库里**（2 GB 二进制必须走 Release 附件，仓库附件的单文件上限是 2 GiB）。
> 见 [`../docs/04-发布与下载.md`](../docs/04-发布与下载.md)。

## 获取

```bash
curl -LO https://github.com/misaka-link/umi-linux/releases/download/v2026-09-27/umi-system-opensource-2026-09-27.tar.gz
mv umi-system-opensource-2026-09-27.tar.gz rootfs/

# 校验
sha256sum -c ../SHA256SUMS.txt     # 相关行应显示 OK
```

## 怎么用

它是 **tar.gz 打包的根文件系统**，**不能** `fastboot flash`。要在 **TWRP 恢复模式**里解包：

```bash
# 重启到 TWRP 后
bash tools/restore-system-opensource.sh
```

完整刷机流程见 [`../docs/01-快速开始.md`](../docs/01-快速开始.md)。

## 里面是什么

Debian 13 trixie + 内核模块 6.18.52 + 项目全部系统服务（息屏 / Venus 硬编解 / GPU 限频 /
充电区间控制 / CPU 性能模式 / 保命回 TWRP / 诊断采集）+ Mesa 25.0.7 / Turnip + 相关固件。
**不含任何个人信息**（WiFi 凭据、设备 MAC / 序列号、历史日志均已不在镜像内）。
