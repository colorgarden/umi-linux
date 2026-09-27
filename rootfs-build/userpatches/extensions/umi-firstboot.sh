# @description 小米10 (umi) 首次启动预设 —— 让 Armbian 的 firstrun 向导全自动跑完，
# 不弹任何交互问题。root 密码设为 root，另建一个 armbian/armbian 备用账号。
#
# 配合 userpatches/customize-image.sh 使用：后者在构建时就把 root 密码和
# SSH 配置写好，所以即使向导没跑（无头设备没有可用控制台），SSH root/root 也能用。
#
# 启用方式：ENABLE_EXTENSIONS="... umi-firstboot"

function post_family_tweaks__umi_firstboot_presets() {
	display_alert "$BOARD" "写入 firstrun 预设（root 密码 = root）" "info"

	local f="${SDCARD}/root/.not_logged_in_yet"
	: > "$f"

	# ---- 网络：不动。WiFi 交给 NetworkManager，USB 网卡由 usbgadget-rndis 负责 ----
	echo "PRESET_NET_CHANGE_DEFAULTS=0" >> "$f"

	# ---- 系统 ----
	echo "SET_LANG_BASED_ON_LOCATION=n" >> "$f"
	echo "PRESET_LOCALE=en_US.UTF-8" >> "$f"
	echo "PRESET_TIMEZONE=Asia/Shanghai" >> "$f"
	echo "PRESET_USER_SHELL=bash" >> "$f"
	echo "PRESET_CONNECT_WIRELESS=n" >> "$f"

	# ---- root 账号：密码 root ----
	echo "PRESET_ROOT_PASSWORD=root" >> "$f"
	echo "PRESET_ROOT_KEY=''" >> "$f"

	# ---- 备用普通账号 armbian/armbian（便于日常使用，可留可删）----
	echo "PRESET_USER_NAME=armbian" >> "$f"
	echo "PRESET_USER_PASSWORD=armbian" >> "$f"
	echo "PRESET_USER_KEY=''" >> "$f"
	echo "PRESET_DEFAULT_REALNAME=Armbian" >> "$f"

	# ---- 首次登录后自动执行的 provision 脚本（可留空）----
	install -Dm755 /dev/null "${SDCARD}/root/provisioning.sh" || true

	return 0
}
