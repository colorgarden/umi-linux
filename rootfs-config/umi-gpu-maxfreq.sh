#!/bin/bash
# ============================================================
# umi: 限制 GPU devfreq 的最高频率（超频档存在时的安全阀）
# ------------------------------------------------------------
# DTB 里的 GPU OPP 表现在包含 670MHz~1GHz 的超频档。
# 本服务在每次开机时把 max_freq 拉回 /etc/default/umi-gpu-maxfreq
# 中配置的安全值，防止调速器在高负载时自动冲到不稳定档位。
# 想手动实验：直接 echo <freq> > /sys/class/devfreq/3d00000.gpu/max_freq
# ============================================================
set -u
[ -f /etc/default/umi-gpu-maxfreq ] && . /etc/default/umi-gpu-maxfreq
LIMIT="${GPU_MAX_FREQ:-587000000}"
DEV=/sys/class/devfreq/3d00000.gpu
LOG=/run/umi-gpu-maxfreq.log

# 等 devfreq 设备就绪（最多 20 秒）
for _ in $(seq 1 40); do
    [ -w "$DEV/max_freq" ] && break
    sleep 0.5
done
[ -w "$DEV/max_freq" ] || { echo "$(date -Is) devfreq 未出现，跳过" >>"$LOG"; exit 0; }

# 先把 min 降下来（devfreq 要求 min <= max）
cur_min=$(cat "$DEV/min_freq" 2>/dev/null || echo 0)
if [ "$cur_min" -gt "$LIMIT" ]; then
    echo "$LIMIT" > "$DEV/min_freq" 2>/dev/null || true
fi
echo "$LIMIT" > "$DEV/max_freq" 2>/dev/null || true
echo "$(date -Is) 设定 GPU max_freq=$LIMIT 实际 max=$(cat "$DEV/max_freq") min=$(cat "$DEV/min_freq")" >>"$LOG"
