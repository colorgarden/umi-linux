#!/usr/bin/env bash
#
# test-charge-limit.sh —— battery-charge-limit 的滞回逻辑单测
#
# 分两层测：
#   A. decide() 纯函数：穷举电量/状态的组合，断言动作与新状态
#   B. 端到端：构造假的 sysfs 树（capacity + charging_enabled），真跑脚本，
#      断言 charging_enabled 的写入序列符合滞回语义
#
# 用法： bash tools/test-charge-limit.sh [路径/到/battery-charge-limit]
#
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="${1:-}"
if [ -z "$SCRIPT" ]; then
	# 依次尝试几个可能的相对位置（tools/ 下、tests/ 下、移植包根目录）
	for cand in \
		"$HERE/../sources/armbian-umi-port/userpatches/overlay/usr/local/bin/battery-charge-limit" \
		"$HERE/../userpatches/overlay/usr/local/bin/battery-charge-limit" \
		"$HERE/userpatches/overlay/usr/local/bin/battery-charge-limit" \
		"/usr/local/bin/battery-charge-limit"
	do
		[ -r "$cand" ] && { SCRIPT="$cand"; break; }
	done
fi
[ -n "$SCRIPT" ] && [ -r "$SCRIPT" ] || {
	echo "找不到 battery-charge-limit，请显式指定路径：bash $0 <路径>"; exit 2; }

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '        期望=%s 实际=%s\n' "$2" "$3"; }

TMP=$(mktemp -d 2>/dev/null) || TMP=""
# Git Bash 的 mktemp 可能返回 "C:/Users/..." 这种 Windows 风格路径，
# bash 的 glob 不认（会被当成相对路径），所以强制换成 POSIX 路径
case "$TMP" in
	/*) ;;
	*)  TMP="/tmp/chglmt.$$"; rm -rf "$TMP"; mkdir -p "$TMP" ;;
esac
trap 'rm -rf "$TMP"' EXIT

echo "被测脚本：$SCRIPT"
echo

# ======================================================================
echo "A. decide() 纯函数 —— 滞回状态机"
# ======================================================================
# 只加载函数，不进入主循环
export BATTERY_CHARGE_LIMIT_LIB=1
export SYSFS_ROOT="$TMP/fake"
UPPER=75; LOWER=70
# shellcheck disable=SC1090
source "$SCRIPT"

# 表驱动：cap state 期望动作 期望新状态
run_decide() { decide "$1" "$2"; }

check_decide() {
	local cap="$1" state="$2" want="$3" got
	got=$(run_decide "$cap" "$2")
	if [ "$got" = "$want" ]; then ok "cap=$cap state='$state' → $want"
	else bad "cap=$cap state='$state'" "$want" "$got"; fi
}

# --- 到顶：≥75 停充 ---
check_decide 80 unknown "off off"    # 未知状态、已超顶 → 立即停
check_decide 75 unknown "off off"    # 正好等于 UPPER 也算到顶
check_decide 75 on      "off off"    # 正在充 → 停
check_decide 75 off     "none off"   # 已经停了 → 不重复写
check_decide 90 off     "none off"   # 远高于阈值且已停 → 不重复写

# --- 到底：≤70 复充 ---
check_decide 60 unknown "on on"      # 未知状态、低于下限 → 开充
check_decide 70 unknown "on on"      # 正好等于 LOWER 也算到底
check_decide 70 off     "on on"      # 停充中 → 复充
check_decide 70 on      "none on"    # 正在充 → 不重复写
check_decide 30 on      "none on"    # 远低于阈值且已在充 → 不重复写

# --- 滞回区间：71~74 维持现状 ---
check_decide 71 off     "none off"   # 停在 71 → 继续停（关键：不因低于75就复充）
check_decide 72 off     "none off"
check_decide 73 off     "none off"
check_decide 74 off     "none off"
check_decide 71 on      "none on"    # 充到 71 → 继续充（关键：不因未到75就停）
check_decide 74 on      "none on"
check_decide 73 unknown "none unknown"  # 未知状态 + 区间内 → 保持未知、不动手

# --- 边界：UPPER/LOWER 可配置 ---
UPPER=60 LOWER=55
check_decide 60 on      "off off"
check_decide 57 off     "none off"
check_decide 55 off     "on on"
UPPER=75 LOWER=70

echo
# ======================================================================
echo "B. 端到端 —— 真跑脚本，喂假 sysfs，检查 charging_enabled 写入序列"
# ======================================================================
FAKE="$TMP/e2e"
mkdir -p "$FAKE/class/power_supply/BAT0" \
         "$FAKE/class/power_supply/pm8150b_charger"

BATT="$FAKE/class/power_supply/BAT0"
CHG="$FAKE/class/power_supply/pm8150b_charger"
echo 60 > "$BATT/capacity"
echo 1  > "$CHG/charging_enabled"

# 前置自检：假 sysfs 必须能被脚本里的 glob 展开方式找到，
# 否则后面所有断言都会「看起来通过」其实是空跑（假阳性）
# 注意：不能写成 `if ! set -- ...; [ -d "$1" ]` —— `!` 会让 set 在子 shell
# 里执行，位置参数留不下来，检查必然失败。
set -- "$FAKE"/class/power_supply/*/
if [ -d "$1" ]; then
	ok "前置自检：假 sysfs 就绪（$FAKE）"
else
	printf '\033[31m前置自检失败\033[0m：假 sysfs 建在 %s，glob 展不开\n' "$FAKE"
	echo "  展开结果：$FAKE/class/power_supply/*/"
	exit 2
fi
if [ ! -r "$BATT/capacity" ] || [ ! -w "$CHG/charging_enabled" ]; then
	printf '\033[31m前置自检失败\033[0m：capacity / charging_enabled 不可读写\n'
	exit 2
fi

# 观测手段：charging_enabled 是普通文件，脚本每次真正写入都会刷新 mtime。
# 于是「值不变 + mtime 不变」= 确实没写，「值不变 + mtime 变了」= 重复写了。
# （不用 FIFO：脚本是 echo > file，写 FIFO 会阻塞。）
stamp() { stat -c '%y' "$CHG/charging_enabled" 2>/dev/null || echo "?"; }
val()   { cat "$CHG/charging_enabled" 2>/dev/null; }

# 关键：上面为了加载函数把 LIB 标志 export 了，子进程必须清掉，
# 否则真跑脚本时会立刻 return、什么都不做
unset BATTERY_CHARGE_LIMIT_LIB

# 启动脚本（INTERVAL 很短，让测试快）
SYSFS_ROOT="$FAKE" UPPER=75 LOWER=70 INTERVAL=1 \
	"$SCRIPT" > "$TMP/e2e.log" 2>&1 &
PID=$!
PID3=""
# 确保退出时不留后台进程
trap 'kill "$PID" "$PID3" 2>/dev/null; rm -rf "$TMP"' EXIT

# 等脚本第一次采样完（此时 60% ≤ 70% → 应写 1，但它本来就是 1，
# 我们改成从 0 开始，这样能观察到第一次真正的写入）
echo 0 > "$CHG/charging_enabled"
sleep 2

if [ "$(val)" = "1" ]; then
	ok "起始 60% → charging_enabled 被置 1（开始充电）"
else
	bad "起始 60% 应置 1" "1" "$(val)"
fi

# ---- 冲到 75% → 应停充 ----
echo 75 > "$BATT/capacity"; sleep 2
V75=$(val); M75=$(stamp)
[ "$V75" = "0" ] && ok "75% → charging_enabled 置 0（停充）" \
                 || bad "75% 应置 0" "0" "$V75"

# ---- 掉到 72%（滞回区间）→ 必须保持 0，且不应发生写入 ----
echo 72 > "$BATT/capacity"; sleep 2
V72=$(val); M72=$(stamp)
[ "$V72" = "0" ] && ok "72%（滞回区间）→ 保持 0，未复充" \
                 || bad "72% 应保持 0" "0" "$V72"
if [ "$M72" = "$M75" ]; then
	ok "72% → 没有发生写入（mtime 未变，确认是「维持」而非「重复写 0」）"
else
	bad "72% 不应写入 charging_enabled" "mtime 不变" "mtime 变了"
fi

# ---- 掉到 70% → 应复充 ----
echo 70 > "$BATT/capacity"; sleep 2
V70=$(val)
[ "$V70" = "1" ] && ok "70% → charging_enabled 置 1（复充）" \
                 || bad "70% 应置 1" "1" "$V70"
# 记下复充这一刻的时间戳，作为下一段「不应写入」的基准
M70=$(stamp)

# ---- 回到 72% → 保持 1，不复停 ----
echo 72 > "$BATT/capacity"; sleep 2
V72b=$(val); M72b=$(stamp)
[ "$V72b" = "1" ] && ok "72%（滞回区间）→ 保持 1，未停充" \
                  || bad "72% 应保持 1" "1" "$V72b"
[ "$M72b" = "$M70" ] && ok "72% → 同样没有发生写入（mtime 停在复充那一刻）" \
                     || bad "72% 不应写入" "mtime 不变" "mtime 变了"

# ---- 无效电量值 → 不应崩、不应改状态 ----
echo "garbage" > "$BATT/capacity"; sleep 2
if kill -0 "$PID" 2>/dev/null; then
	ok "capacity 读到非数字时进程仍存活"
	[ "$(val)" = "1" ] && ok "非数字期间状态不变" || bad "非数字期间不应改状态" "1" "$(val)"
else
	bad "capacity 非数字导致进程退出"
fi

echo
# ======================================================================
echo "C. 配置校验 与 内核原生分支"
# ======================================================================
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null

# --- C1: UPPER 不是整数 → 必须以退出码 1 退出，且不进入循环 ---
OUT=$(SYSFS_ROOT="$FAKE" UPPER="75%" "$SCRIPT" 2>&1); RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "不是非负整数"; then
	ok "UPPER='75%' → 拒绝启动（rc=1）"
else
	bad "UPPER='75%' 应拒绝启动" "rc=1 + 提示" "rc=$RC out=$OUT"
fi

OUT=$(SYSFS_ROOT="$FAKE" UPPER="abc" LOWER="" "$SCRIPT" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok "UPPER='abc' LOWER='' → 拒绝启动（rc=1）" \
                || bad "非法配置应拒绝启动" "rc=1" "rc=$RC out=$OUT"

# --- C2: UPPER <= LOWER → 给警告但仍然运行 ---
NATIVE="$TMP/native"
mkdir -p "$NATIVE/class/power_supply/BAT0" "$NATIVE/class/power_supply/charger"
echo 50 > "$NATIVE/class/power_supply/BAT0/capacity"
echo 1  > "$NATIVE/class/power_supply/charger/charging_enabled"

SYSFS_ROOT="$NATIVE" UPPER=70 LOWER=75 INTERVAL=30 timeout 3 "$SCRIPT" > "$TMP/c2.log" 2>&1
if grep -q "滞回区间无效" "$TMP/c2.log"; then
	ok "UPPER(70) <= LOWER(75) → 打出滞回无效警告"
else
	bad "UPPER<=LOWER 应给警告" "含「滞回区间无效」" "$(cat "$TMP/c2.log")"
fi

# --- C3: 充电器有 charge_control_end_threshold → 走原生路径，写 UPPER 后常驻 ---
NAT2="$TMP/native2"
mkdir -p "$NAT2/class/power_supply/BAT0" "$NAT2/class/power_supply/charger"
echo 50 > "$NAT2/class/power_supply/BAT0/capacity"
echo 0  > "$NAT2/class/power_supply/charger/charging_enabled"
echo 0  > "$NAT2/class/power_supply/charger/charge_control_end_threshold"

SYSFS_ROOT="$NAT2" UPPER=75 LOWER=70 INTERVAL=1 \
	"$SCRIPT" > "$TMP/c3.log" 2>&1 &
PID3=$!
sleep 2

TH=$(cat "$NAT2/class/power_supply/charger/charge_control_end_threshold")
[ "$TH" = "75" ] && ok "原生路径：charge_control_end_threshold 被写成 75" \
                 || bad "原生路径应写 75" "75" "$TH"

if kill -0 "$PID3" 2>/dev/null; then
	ok "原生路径：进程常驻（exec sleep infinity），交给 systemd 管理"
else
	bad "原生路径进程不应退出"
fi

# 原生路径下不应去动 charging_enabled（那是兜底路径的属性）
CE=$(cat "$NAT2/class/power_supply/charger/charging_enabled")
[ "$CE" = "0" ] && ok "原生路径：未去碰 charging_enabled" \
                || bad "原生路径不应写 charging_enabled" "0" "$CE"

if grep -q "使用内核原生" "$TMP/c3.log"; then
	ok "原生路径：日志确认走了内核原生分支"
else
	bad "应走内核原生分支" "含「使用内核原生」" "$(cat "$TMP/c3.log")"
fi
kill "$PID3" 2>/dev/null

echo
# ---- 日志抽查 ----
echo "  脚本日志（e2e）："
sed 's/^/    /' "$TMP/e2e.log"
echo "  脚本日志（原生路径）："
sed 's/^/    /' "$TMP/c3.log"

echo
if [ "$FAIL" -eq 0 ]; then
	printf '\033[32m全部通过\033[0m：%d 项\n' "$PASS"
	exit 0
else
	printf '\033[31m失败 %d 项\033[0m，通过 %d 项\n' "$FAIL" "$PASS"
	exit 1
fi
