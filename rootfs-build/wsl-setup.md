# 在 Windows 上用 WSL2 构建（推荐）

> `rootfs-build/` 需要 Linux 环境（要 `chroot`、`mount`、`sudo`）。Windows 上最省事的做法是 WSL2。

## 一、装 WSL2

```powershell
# 管理员 PowerShell
wsl --install -d Ubuntu-22.04
wsl --set-default-version 2
```

**把发行版装到非系统盘**（构建要 50 GB+ 可用空间，建议别放 C 盘）：

```powershell
wsl --export Ubuntu-22.04 D:\wsl\ubuntu.tar
wsl --unregister Ubuntu-22.04
wsl --import Ubuntu-22.04 D:\wsl\Ubuntu D:\wsl\ubuntu.tar --version 2
```

内存 / CPU 限制（可选）—— `C:\Users\<你>\.wslconfig`：

```ini
[wsl2]
memory=8GB
processors=8
```

## 二、装构建依赖

```bash
sudo apt update
sudo apt install -y git device-tree-compiler python3 patch bc bison flex \
                    build-essential fakeroot rsync
```

> ⚠️ **源码不要放在 `/mnt/c/`、`/mnt/d/` 这类 Windows 路径下**：跨文件系统极慢，而且 `chroot` 容易出问题。
> 放进 WSL 自己的文件系统，例如 `~/`。

## 三、构建

```bash
# 把本仓库的 rootfs-build/ 拷进 WSL（例如 ~/armbian-umi-port）
cp -r /mnt/<盘符>/<路径>/rootfs-build ~/armbian-umi-port

cd ~/armbian-umi-port
bash build-in-wsl.sh          # 装依赖 → 克隆 armbian/build → 应用移植 → 开始构建
```

也可用环境变量控制：

```bash
BUILD_DIR=~/armbian-build RELEASE=trixie BRANCH=current bash build-in-wsl.sh
```

产物在 `~/armbian-build/output/images/`。参数与扩展说明见 [BUILD.md](BUILD.md)。

## 四、长构建建议放后台

首次构建约 1~2 小时：

```bash
nohup bash build-in-wsl.sh > ~/build-run.log 2>&1 &
tail -f ~/build-run.log
```
