# 充电区间控制（电池保护）—— 实际实现说明

> 当前设定：**电量 ≥ 70% 停止充电，≤ 65% 恢复充电**（2026-09-27 由 75/70 改来）
> 实现：**`battery-charge-limit`**（本项目 2026-09-20 原有实现，非本次新增）

---

## 一、⚠️ 先说一个我犯的错

我在 2026-09-27 下午**重复造了一个轮子**：写了个 `umi-charge-limit.service` 来做 65/70 的区间控制，
**没有先检索项目里是否已有实现**。实际上这个功能 9-20 就已经做好并一直在跑 —— 于是出现**两个守护进程同时写
`/sys/class/power_supply/pm8150b-charger/charging_enabled`** 的冲突状态（阈值还不同，滞回区里会互相打架）。

已处理：**删掉我加的 `umi-charge-limit`（脚本/单元/配置全删）**，只保留原有的 `battery-charge-limit`，
并把它的阈值改成用户要的 70/65。

> 教训：动手前先 `grep` 项目、先看 `systemctl list-unit-files`。这个项目里"限充/息屏/推文件"这类
> 小功能大多已经做过一轮了。

---

## 二、实际实现：`battery-charge-limit`

**位置（Armbian overlay，重装系统会自动带上）**

| 角色 | 路径 |
|---|---|
| 脚本 | `sources/armbian-umi-port/userpatches/overlay/usr/local/bin/battery-charge-limit` → 设备上 `/usr/local/bin/battery-charge-limit` |
| systemd 单元 | `.../overlay/etc/systemd/system/battery-charge-limit.service` |
| 默认配置（首次装机写入，已存在则不覆盖） | `.../userpatches/customize-image.sh` → `/etc/default/battery-charge-limit` |
| 单测 | `tools/test-charge-limit.sh`（另存 `sources/armbian-umi-port/tests/`） |

### 2.1 双路径自动选择

```
① 内核原生：某个 power_supply 有 charge_control_end_threshold
     → 直接写 UPPER，驱动自己控温控流（无轮询开销，最干净）
② 用户态兜底：某个 psy 有 charging_enabled
     → 轮询 capacity，按滞回决策通断充电
```

**本机走的是路径 ②**：内核 PM8150B 充电驱动没有暴露 `charge_control_*_threshold`
（`/sys` 里确实找不到），所以自动退化到轮询。开机日志可见：

```
[charge-limit] 电池设备：/sys/class/power_supply/qcom-battery
[charge-limit] 使用用户态轮询：充电器 /sys/class/power_supply/pm8150b-charger 的 charging_enabled
[charge-limit] 电量 77% ≥ 70% → 已停止充电
```

### 2.2 滞回语义（核心）

| 电量 | 动作 |
|---|---|
| `cap >= UPPER` | 停止充电（写 `charging_enabled=0`），已经是停的就不重复写 |
| `cap <= LOWER` | 恢复充电（写 `charging_enabled=1`），已经在充就不重复写 |
| `LOWER < cap < UPPER` | **维持现状**（关键：避免在阈值附近反复通断） |

这套语义被抽成纯函数 `decide(cap, state)`，因此可以脱离硬件做确定性单测。

### 2.3 配置优先级与校验

- 优先级：**环境变量 > `/etc/default/battery-charge-limit` > 脚本内置默认（75/70/30）**
- 启动时校验 `UPPER/LOWER/INTERVAL` 必须是非负整数，否则拒绝启动（避免 `[ -ge ]` 报错刷屏）
- 若 `UPPER <= LOWER` 会打印"滞回区间无效"警告
- 服务单元：`ConditionPathExists=/usr/local/bin/battery-charge-limit`、`Restart=on-failure`、`RestartSec=10`
- 日志前缀统一 `[charge-limit]`，走 journal（`journalctl -u battery-charge-limit`）

### 2.4 单测

```bash
bash tools/test-charge-limit.sh      # 2026-09-27 复跑：全部通过 37 项
```

覆盖：`decide()` 边界（`cap==UPPER` 也算到顶、`cap==LOWER` 也算到底、滞回区不动作、
"停在 71% 不因为低于 75 就复充"）、参数非法拒启、滞回无效警告、
原生路径（写 `charge_control_end_threshold` 并 `exec sleep infinity` 常驻且不碰 `charging_enabled`）、
用户态路径 e2e（假 sysfs 真跑脚本）。

---

## 三、2026-09-27 的改动

| 项目 | 改动 |
|---|---|
| 设备 `/etc/default/battery-charge-limit` | `UPPER=75 LOWER=70` → **`UPPER=70 LOWER=65`**（原文件备份为 `.bak-20260927`），`systemctl restart battery-charge-limit` 生效 |
| 仓库 `customize-image.sh` | 首次装机写入的默认值同步改为 70/65（含日志文案） |
| 新增的重复实现 | `umi-charge-limit.service` / `umi-charge-limit.sh` / `/etc/default/umi-charge-limit` **已删除** |

**改动后实测（16:33）**：

```
Sep 27 16:33:01 [charge-limit] 电量 77% ≥ 70% → 已停止充电
当前: capacity=77%  charging_enabled=0  charger_I=0µA      ← 正确处于停充
```

后续：电量掉到 **65%** 自动复充，充到 **70%** 再停，长期维持在 65~70%。

（同日更早的验证：置 `charging_enabled=0` 后 `pm8150b-charger/current_now` 由 ~250 mA 变
**0 µA**、`voltage_now` 变 0、capacity 3 分钟不动、电池电压缓慢下滑 → 停充真实有效。）

---

## 四、日常使用

```bash
# 改区间（改完必须重启服务，配置是启动时读入的）
vi /etc/default/battery-charge-limit          # UPPER=70 / LOWER=65
systemctl restart battery-charge-limit

# 看状态 / 日志
cat /sys/class/power_supply/qcom-battery/capacity
cat /sys/class/power_supply/pm8150b-charger/charging_enabled
journalctl -u battery-charge-limit -f

# 想恢复"插上就充满"：停服务 + 手动把充电写回 1
systemctl disable --now battery-charge-limit
echo 1 > /sys/class/power_supply/pm8150b-charger/charging_enabled
```

⚠️ **停用服务时务必手动写回 `charging_enabled=1`**，否则会一直不充电。

⚠️ `capacity` 是 1% 步进 + 30 秒轮询 → 最多过冲 1%（可能到 71% 才停），对电池保护无影响。

⚠️ 判断"是否在充"要看 **`pm8150b-charger/current_now`**（0 = 停充，≈250 mA = 在充）+
`capacity` 趋势；**不要用 `qcom-battery` 的 `current_now`/`status`**（本移植上不可信：
边充边报 `Discharging`，数值前后差 200 倍）。
