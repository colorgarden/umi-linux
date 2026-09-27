# @description 小米10 (umi) 内核配置微调：
#   1. 把 apparmor 加进 CONFIG_LSM，让已编译的 AppArmor 真正生效（Docker 会用到）
#   2. 顺带打开几个服务器向的选项
#
# 背景：Armbian 的 sm8250 defconfig 里 `CONFIG_SECURITY_APPARMOR=y` 是开着的，
# 但 `CONFIG_LSM` 默认是 "landlock,lockdown,yama,loadpin,safesetid,integrity,bpf"
# —— 里面**没有 apparmor**，所以 AppArmor 被编译了却不会激活。
# 这里把 CONFIG_LSM 改成 lmi（同为小米 SM8250 机型）实测可用的顺序。
#
# 启用方式：ENABLE_EXTENSIONS="... umi-kernel-tweaks"

function custom_kernel_config__umi_kernel_tweaks() {
	display_alert "${EXTENSION}: 内核配置微调（AppArmor 激活等）" "opts_val" "info"

	# AppArmor 必须在 CONFIG_LSM 列表里才会被初始化。
	# 顺序参考 lmi 的可用配置：apparmor 放在 integrity 之后、bpf 之前。
	opts_val["LSM"]="landlock,lockdown,yama,loadpin,safesetid,integrity,apparmor,bpf"

	# 服务器向：把常用文件系统/网络选项确保打开（幂等，已开则无副作用）
	opts_y+=(
		"OVERLAY_FS"          # Docker overlay2
		"CGROUP_DEVICE"       # docker --device
		"USER_NS"             # rootless docker
		"SECCOMP_FILTER"      # docker 默认 seccomp
		"BRIDGE_NETFILTER"    # docker 网络
		"I2C_CHARDEV"         # i2c-tools 需要
		"GPIO_CDEV"           # libgpiod（控制面板 reset 用）
		"GPIO_CDEV_V1"        # 兼容旧的 gpio sysfs 语义
		"PWM_SYSFS"           # 背光/风扇等
	)
}
