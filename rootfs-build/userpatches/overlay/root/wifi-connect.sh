#!/bin/bash
#
# 小米10 (umi) 快捷连 WiFi
#
# 用法：  sudo wifi-connect
#
# 交互流程：列出 WiFi → 输入编号 → 输入密码 → 连接（DHCP）
#
# 这套镜像用的是 systemd-networkd + wpa_supplicant（没有 NetworkManager/nmcli），
# 所以本脚本按这个栈来写，配置写进：
#   /etc/wpa_supplicant/wpa_supplicant-<iface>.conf   （WiFi 凭据，PSK 已哈希）
#   /etc/systemd/network/25-<iface>.network           （DHCP）
# 配置是持久的，重启后自动重连。
#
set -u

IFACE="${1:-wlan0}"
WPA_CONF="/etc/wpa_supplicant/wpa_supplicant-${IFACE}.conf"
NETD_CONF="/etc/systemd/network/25-${IFACE}.network"
WPA_SVC="wpa_supplicant@${IFACE}"

die() { echo "错误：$*" >&2; exit 1; }
info() { echo "  $*"; }

[ "$(id -u)" -eq 0 ] || die "请用 sudo 运行：sudo $0"

echo "============================================================"
echo " 小米10 WiFi 连接向导（网卡：$IFACE）"
echo "============================================================"
echo

# ---------------------------------------------------------------- 1. 网卡就绪
if ! ip link show "$IFACE" >/dev/null 2>&1; then
	echo "找不到无线网卡 $IFACE。当前网络接口："
	ip -br link | sed 's/^/  /'
	echo
	echo "如果只有 lo / usb0，说明 ath11k 没起来，检查："
	echo "  dmesg | grep -i ath11k"
	echo "  lspci -nn | grep -i qualcomm"
	die "无线网卡不可用"
fi
ip link set "$IFACE" up
rfkill unblock wifi 2>/dev/null || true

# ---------------------------------------------------------------- 2. 起 wpa_supplicant
if [ ! -f "$WPA_CONF" ]; then
	info "初始化 $WPA_CONF"
	{
		echo "ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev"
		echo "update_config=1"
		echo "country=CN"
	} > "$WPA_CONF"
	chmod 600 "$WPA_CONF"
fi

systemctl enable "$WPA_SVC" >/dev/null 2>&1 || true
systemctl restart "$WPA_SVC" >/dev/null 2>&1 || systemctl start wpa_supplicant >/dev/null 2>&1 || true
sleep 2

# ---------------------------------------------------------------- 3. 扫描
echo "正在扫描 WiFi（约 8 秒）..."
wpa_cli -i "$IFACE" scan >/dev/null 2>&1 || true
sleep 6

# wpa_cli scan_results 输出：bssid  frequency  signal  flags  ssid
# 用 \t 分隔；SSID 可能含空格，所以只按前 4 个字段切分
mapfile -t RAW < <(wpa_cli -i "$IFACE" scan_results 2>/dev/null | tail -n +2)

# 没有结果时退回 iw（若装了）
if [ "${#RAW[@]}" -eq 0 ] && command -v iw >/dev/null 2>&1; then
	echo "  （wpa_cli 没结果，改用 iw 扫描）"
	iw dev "$IFACE" scan 2>/dev/null | awk '
		/^BSS /          { ssid=""; sig="" }
		/^\tSSID: /      { ssid=substr($0, index($0,":")+2) }
		/^\tsignal: /    { sig=$2 }
		ssid!="" && sig!="" { printf "%s\t%s\n", sig, ssid; ssid="" }
	' > /tmp/.wifiscan
	mapfile -t RAW < <(awk -F'\t' '{printf "-100\t%s\t-\t%s\n", $1, $2}' /tmp/.wifiscan)
	rm -f /tmp/.wifiscan
fi

[ "${#RAW[@]}" -gt 0 ] || die "没扫到任何 WiFi。确认无线网卡正常：dmesg | grep -i ath11k"

# 解析 → 去重（同 SSID 留信号最强的）→ 按信号从强到弱排序
mapfile -t LIST < <(
	for line in "${RAW[@]}"; do
		sig=$(echo "$line" | awk -F'\t' '{print $3}')
		flags=$(echo "$line" | awk -F'\t' '{print $4}')
		ssid=$(echo "$line" | awk -F'\t' '{for(i=5;i<=NF;i++){printf "%s%s",(i>5?"\t":""),$i}}')
		[ -z "$ssid" ] && continue
		case "$flags" in
			*WPA*|*RSN*|*WEP*) sec="加密" ;;
			*)                 sec="开放" ;;
		esac
		printf "%s\t%s\t%s\n" "$sig" "$sec" "$ssid"
	done | sort -rn -k1,1 | awk -F'\t' '!seen[$3]++'
)

echo
echo "可用 WiFi："
i=1
for e in "${LIST[@]}"; do
	sig=$(echo "$e" | cut -f1)
	sec=$(echo "$e" | cut -f2)
	ssid=$(echo "$e" | cut -f3)
	printf "  %2d) %-34s 信号 %s dBm  %s\n" "$i" "$ssid" "$sig" "$sec"
	i=$((i+1))
done
echo
echo "  （也可以输入 m 手动指定一个隐藏/不在列表里的 SSID）"
echo

# ---------------------------------------------------------------- 4. 选择
read -rp "请输入编号（1-$((i-1))，或 m）： " CHOICE

if [ "$CHOICE" = "m" ] || [ "$CHOICE" = "M" ]; then
	read -rp "请输入 SSID： " SSID
	read -rp "该网络是否加密？(y/N) " SECURED
	[[ "$SECURED" =~ ^[Yy]$ ]] && SECURED=1 || SECURED=0
else
	case "$CHOICE" in
		''|*[!0-9]*) die "无效输入：$CHOICE" ;;
	esac
	[ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "$((i-1))" ] || die "编号超出范围"
	ENTRY="${LIST[$((CHOICE-1))]}"
	SSID=$(echo "$ENTRY" | cut -f3)
	[ "$(echo "$ENTRY" | cut -f2)" = "加密" ] && SECURED=1 || SECURED=0
fi

echo
info "已选择：$SSID"

# ---------------------------------------------------------------- 5. 密码
if [ "$SECURED" = "1" ]; then
	read -rsp "请输入 WiFi 密码（输入时不显示）： " PASS
	echo
	[ -n "$PASS" ] || die "密码为空"
	# 用 wpa_passphrase 生成 PSK，避免明文落盘
	BLOCK=$(wpa_passphrase "$SSID" "$PASS" | sed -n '/^network={/,$p')
	[ -n "$BLOCK" ] || die "生成 PSK 失败"
else
	BLOCK="network={
	ssid=\"$SSID\"
	key_mgmt=NONE
}"
fi
unset PASS

# ---------------------------------------------------------------- 6. 写入配置
# 先清掉旧的同名 network 块，再追加
if grep -q "ssid=\"$SSID\"" "$WPA_CONF" 2>/dev/null; then
	info "配置里已有 $SSID，替换它"
	awk -v s="ssid=\"$SSID\"" '
		/^network=\{/ { buf=""; inb=1 }
		inb { buf = buf $0 "\n" }
		inb && /^\}/ {
			inb=0
			if (index(buf, s) == 0) printf "%s", buf
			next
		}
		!inb { print }
	' "$WPA_CONF" > "${WPA_CONF}.tmp" && mv "${WPA_CONF}.tmp" "$WPA_CONF"
fi
printf '\n%s\n' "$BLOCK" >> "$WPA_CONF"
chmod 600 "$WPA_CONF"

# networkd 侧：DHCP
mkdir -p /etc/systemd/network
if [ ! -f "$NETD_CONF" ]; then
	info "写入 $NETD_CONF（DHCP）"
	{
		echo "[Match]"
		echo "Name=$IFACE"
		echo
		echo "[Network]"
		echo "DHCP=yes"
	} > "$NETD_CONF"
fi
chmod 644 "$NETD_CONF"

# ---------------------------------------------------------------- 7. 连接
echo
echo "正在连接..."
systemctl enable systemd-networkd >/dev/null 2>&1 || true
systemctl restart systemd-networkd >/dev/null 2>&1 || true
systemctl restart "$WPA_SVC" >/dev/null 2>&1 || systemctl restart wpa_supplicant >/dev/null 2>&1 || true

# 等 IP（最多 30 秒）
IP=""
for _ in $(seq 1 30); do
	IP=$(ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
	[ -n "$IP" ] && break
	sleep 1
done

echo
echo "============================================================"
if [ -n "$IP" ]; then
	echo " ✅ 连接成功"
	echo
	echo "    SSID : $SSID"
	echo "    IP   : $IP"
	GW=$(ip -4 route show default dev "$IFACE" 2>/dev/null | awk '{print $3}' | head -1)
	[ -n "$GW" ] && echo "    网关 : $GW"
	echo
	echo "    测试联网： ping -c3 1.1.1.1"
	echo "    本机 SSH ： ssh root@$IP"
else
	echo " ⚠️  没拿到 IP。排查："
	echo "     wpa_cli -i $IFACE status        # wpa_state 应为 COMPLETED"
	echo "     systemctl status $WPA_SVC --no-pager"
	echo "     networkctl status $IFACE"
	echo "     journalctl -u systemd-networkd -n 30 --no-pager"
	echo
	echo "   密码填错的话重跑本脚本即可。"
fi
echo "============================================================"
echo
echo "配置已持久化，重启后会自动重连："
echo "  $WPA_CONF"
echo "  $NETD_CONF"
