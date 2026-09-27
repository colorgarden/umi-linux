# @description 小米10 (umi) 打开 USB host 模式所需的内核选项 ——
# 让 USB-C 口既能在 device 模式当 RNDIS 网卡，又能在 host 模式接键盘鼠标。
#
# 用官方 `opts_y` 数组机制（同 extensions/kernel-debug-tiers.sh 的写法），
# 由 Armbian 在 olddefconfig 之前统一应用，不会破坏依赖关系。
#
# 启用方式：ENABLE_EXTENSIONS="... umi-usb-host"

function custom_kernel_config__umi_usb_host() {
	display_alert "${EXTENSION}: 打开 USB host（键鼠）与角色切换" "opts_y" "info"

	opts_y+=(
		# ★ 最关键的一项：没有它，设备树里的 `usb-role-switch` 属性不生效，
		#   端口就只能按 dr_mode 固定一种角色，插键鼠没反应。
		"USB_ROLE_SWITCH"

		# DWC3 双角色（host + gadget 同时具备）
		"USB_DWC3_DUAL_ROLE"
		"USB_DWC3_QCOM"

		# HID：键盘 / 鼠标
		"USB_HID"
		"HID_GENERIC"
		"USB_HIDDEV"

		# xHCI 平台驱动（host 侧控制器）
		"USB_XHCI_HCD"
		"USB_XHCI_PLATFORM"

		# Type-C：pm8150b 的 CC 检测与角色切换
		# （defconfig 里是 =m，改成内建，保证早期就能参与角色协商）
		"TYPEC"
		"TYPEC_TCPM"
		"TYPEC_QCOM_PMIC"

		# VBUS 供电：host 模式下给外设供 5V
		"REGULATOR_QCOM_USB_VBUS"

		# 外设：U 盘 / 移动硬盘
		"USB_STORAGE"
		"USB_UAS"

		# 输入子系统
		"INPUT_EVDEV"

		# gadget 侧（RNDIS 网卡 / ACM 串口）
		"USB_GADGET"
		"USB_CONFIGFS"
		"USB_CONFIGFS_RNDIS"
		"USB_CONFIGFS_ACM"
	)
}
