#!/usr/bin/env python3
"""
从 fork 的原始 umi 设备树生成修复版设备树。
修复项：
  1. GPU  status 笔误（tatus -> status）
  2. GPU  zap shader 路径改为主线通用路径
  3. 电池  battery 节点取消注释（并修正为小米10 的实际规格）
  4. 新增  &pm8150b_charger / &pm8150b_fg / &pm8150b_vbus
  5. 新增  BQ25970 快充节点（默认注释，需实机确认后启用）
"""
import os, re, sys

# 用法:
#   python3 gen-dts.py <原始 umi 设备树 sm8250-xiaomi-umi-common.dtsi> [输出目录]
# 也可用环境变量覆盖: SRC_DTS / OUT_DIR
_HERE = os.path.dirname(os.path.abspath(__file__))
SRC = (sys.argv[1] if len(sys.argv) > 1 else None) or os.environ.get("SRC_DTS") or \
      os.path.join(_HERE, "original", "sm8250-xiaomi-umi-common.dtsi")
OUTDIR = (sys.argv[2] if len(sys.argv) > 2 else None) or os.environ.get("OUT_DIR") or \
         os.path.join(_HERE, "patch", "kernel", "archive", "sm8250-6.18", "dt")

if not os.path.isfile(SRC):
    sys.exit(f"[X] 找不到原始设备树: {SRC}\n"
             f"    用法: python3 gen-dts.py <原始 sm8250-xiaomi-umi-common.dtsi> [输出目录]\n"
             f"    原始设备树来自 armbian/build 的 sm8250 fork（Archfx/armbian-build-bpi），需自行获取。")
os.makedirs(OUTDIR, exist_ok=True)
print(f"源   : {SRC}\n输出 : {OUTDIR}")

dts = open(SRC, encoding="utf-8").read()
orig = dts
changes = []

# ---------- 1 + 2: GPU ----------
old_gpu = '''&gpu {
	 tatus = "okay";
 
	zap-shader {
		memory-region = <&gpu_mem>;
		firmware-name = "qcom/sm8250/xiaomi/elish/a650_zap.mbn";
	};
};'''
new_gpu = '''&gpu {
	status = "okay";

	zap-shader {
		memory-region = <&gpu_mem>;
		firmware-name = "qcom/sm8250/a650_zap.mbn";
	};
};'''
if old_gpu not in dts:
    sys.exit("!! 找不到 GPU 节点原文，中止")
dts = dts.replace(old_gpu, new_gpu, 1)
changes.append("GPU: tatus -> status，zap shader 改用主线通用路径")

# ---------- 3: battery ----------
old_batt = '''	// battery: battery {
	//  	compatible = "simple-battery";
	//  	voltage-min-design-microvolt = <3870000>;
	//  	energy-full-design-microwatt-hours = <16600000>;
	//  	charge-full-design-microamp-hours = <4300000>;
	// };'''
new_batt = '''	/*
	 * 小米10 电池参数
	 *
	 * 依据（小米官方 umi 设备树，LineageOS android_kernel_xiaomi_sm8250）：
	 *   arch/arm64/boot/dts/vendor/qcom/umi-sm8250.dtsi
	 *     &pm8150b_fg   { qcom,battery-data = <&umi_batterydata>; ... }
	 *     &pm8150b_charger { qcom,fv-max-uv = <4450000>; ... }
	 *   arch/arm64/boot/dts/vendor/qcom/fg-gen4-batterydata-umi-gybm-4780mah.dtsi
	 *     qcom,max-voltage-uv     = <4480000>
	 *     qcom,nom-batt-capacity-mah = <4780>
	 *
	 * → 官方确认：电量计用的是 PM8150B **内置** FG（fg-gen4），
	 *   所以主线侧用 &pm8150b_fg + simple-battery 是正确路线。
	 *   原注释块里的 4300000uAh / 16600000uWh 是从小米平板5(elish) 抄来的，数值不对。
	 */
	battery: battery {
		compatible = "simple-battery";
		voltage-min-design-microvolt = <3870000>;
		voltage-max-design-microvolt = <4480000>;
		energy-full-design-microwatt-hours = <18498600>;
		charge-full-design-microamp-hours = <4780000>;
	};'''
if old_batt not in dts:
    sys.exit("!! 找不到 battery 注释块原文，中止")
dts = dts.replace(old_batt, new_batt, 1)
changes.append("电池: 取消注释，参数按官方 fg-gen4-batterydata-umi-gybm-4780mah 校准（4480mV/4780mAh）")

# ---------- 4: PM8150B 充电器 / 电量计 ----------
# 写法照抄 Armbian sm8250-6.18 补丁集里的权威示例：
#   0037-power-supply-qcom_pm8150b_charger-adds-charging-cont.patch
#     （oneplus-instantnoodlep 的 &pm8150b_charger 覆盖，只有三行）
# 注意：不要在这里覆盖 io-channels / io-channel-names ——
#   0029 补丁已经在 pm8150b.dtsi 的 charger@1000 节点里定义好了
#   （io-channel-names = "usb_in_i_uv", "usb_in_v_div_16"），
#   自己再写一份（比如 lmi 用的 "usbin_i"/"usbin_v"）反而会失配。
pm8150b_block = '''
/*
 * PM8150B 充电器与电量计
 *
 * 依赖 Armbian sm8250 family 的 out-of-tree 补丁（6.18 补丁集已自带）：
 *   0028/0037/0039/0041  qcom_pm8150b_charger 驱动  (CONFIG_CHARGER_QCOM_SMB5=y)
 *   0024/0025/0030/0042  qcom_fg 电量计驱动        (CONFIG_BATTERY_QCOM_FG=y)
 *   0029                 pm8150b.dtsi 加 charger@1000 节点
 *   0027                 pm8150b.dtsi 加 fuel-gauge@4000 节点
 * 内核配置里这两个驱动都已经是 y，无需改 config。
 */
&pm8150b_charger {
	status = "okay";
	monitored-battery = <&battery>;
};

/*
 * ⚠️ 电量计：待实机验证
 * 没有现成的 Armbian sm8250 设备启用过 PM8150B 内置 FG（elish 用的是外挂
 * TI bq27z561），所以这一条属于"按 lmi 的做法推断"，需要实测。
 *
 * 先在本机 MIUI 上确认电量计到底是哪一颗：
 *     adb shell ls /sys/bus/i2c/devices/
 *     adb shell cat /sys/class/power_supply/battery/name
 * 如果显示 bq27z561 之类的外挂芯片，就要改成在对应 i2c 总线上加节点
 * （参考 Armbian 补丁 0022 里 elish 的写法），而不是启用下面这段。
 *
 * 如果启用后开机异常，把这段和上面的 &pm8150b_charger 一起注释掉即可回退
 * （只保留 battery 节点不会有害）。
 */
&pm8150b_fg {
	status = "okay";
	monitored-battery = <&battery>;
};

/*
 * USB VBUS 输出调节器（可选，默认不开）
 * 只在需要 USB host 模式对外供电时才需要；RNDIS gadget 是 device 模式，用不上。
 * 主线 pm8150b.dtsi 里该节点默认 disabled，启用前建议先确认 regulator 依赖。
 *
 * &pm8150b_vbus {
 * 	status = "okay";
 * };
 */
'''

anchor = '''&pon_pwrkey {
	status = "okay";
};'''
if anchor not in dts:
    sys.exit("!! 找不到 &pon_pwrkey 锚点，中止")
dts = dts.replace(anchor, pm8150b_block.lstrip("\n") + "\n" + anchor, 1)
changes.append("新增 &pm8150b_charger / &pm8150b_fg（照抄 oneplus 的权威写法，不覆盖 io-channels）")

# ---------- 5: USB OTG（键鼠 / 网卡双模式） ----------
usb_block = '''
/*
 * USB OTG —— 让 USB-C 口既能在 device 模式当 RNDIS 网卡，
 * 又能在 host 模式接键盘鼠标。
 *
 * 配置照抄 Armbian sm8250-6.18 补丁 0038
 * （oneplus-instantnoodlep 的 usb otg 实现，同平台已验证）：
 *   - pm8150b_typec  负责 Type-C CC 检测与角色切换
 *   - pm8150b_vbus   在 host 模式下给外设供 5V
 *   - usb_1_dwc3_hs_out 端点接到 Type-C 口
 *
 * 依赖内核配置（由 userpatches/extensions/umi-usb-host.sh 打开）：
 *   CONFIG_USB_ROLE_SWITCH / USB_DWC3_DUAL_ROLE / USB_HID / HID_GENERIC
 *   CONFIG_TYPEC_QCOM_PMIC / TYPEC_TCPM / USB_XHCI_PLATFORM
 *
 * 用法：插上 USB-C 转 A 母口的 OTG 转接头 → 自动切到 host → 键盘鼠标即插即用；
 *       插到电脑上 → 切回 device → 出现 RNDIS 网卡。
 */
&pm8150b_typec {
	vdd-pdphy-supply = <&vreg_l2a_3p1>;
	status = "okay";

	connector {
		compatible = "usb-c-connector";

		op-sink-microwatt = <10000000>;
		power-role = "dual";
		data-role = "dual";
		self-powered;

		source-pdos = <PDO_FIXED(5000, 3000,
					 PDO_FIXED_DUAL_ROLE |
					 PDO_FIXED_USB_COMM |
					 PDO_FIXED_DATA_SWAP)>;
		sink-pdos = <PDO_FIXED(5000, 3000,
				       PDO_FIXED_DUAL_ROLE |
				       PDO_FIXED_USB_COMM |
				       PDO_FIXED_DATA_SWAP)>;

		ports {
			#address-cells = <1>;
			#size-cells = <0>;

			port@0 {
				reg = <0>;

				pm8150b_hs_in: endpoint {
					remote-endpoint = <&usb_1_dwc3_hs_out>;
				};
			};
		};
	};
};

/* VBUS 输出调节器：host 模式下给键盘/鼠标/U 盘供电 */
&pm8150b_vbus {
	regulator-min-microamp = <500000>;
	regulator-max-microamp = <3000000>;
	status = "okay";
};

/* 把 DWC3 的高速端点接到 Type-C 口（主线里这个端点默认是空的） */
&usb_1_dwc3_hs_out {
	remote-endpoint = <&pm8150b_hs_in>;
};
'''

anchor_usb = '''&usb_1_hsphy {
	vdda-pll-supply = <&vreg_l5a_0p88>;'''
if anchor_usb not in dts:
    sys.exit("!! 找不到 &usb_1_hsphy 锚点，中止")
dts = dts.replace(anchor_usb, usb_block.lstrip("\n") + "\n" + anchor_usb, 1)
changes.append("新增 USB OTG：pm8150b_typec + connector + vbus + dwc3 端点连接")

# 给 dwc3 补 role-switch-default-mode
old_dwc3 = '''&usb_1_dwc3 {
	dr_mode = "otg";
	maximum-speed = "high-speed";
	/* Remove USB3 phy */
	phys = <&usb_1_hsphy>;
	phy-names = "usb2-phy";
	usb-role-switch;
};'''
new_dwc3 = '''&usb_1_dwc3 {
	dr_mode = "otg";
	maximum-speed = "high-speed";
	/* Remove USB3 phy */
	phys = <&usb_1_hsphy>;
	phy-names = "usb2-phy";
	usb-role-switch;
	/* 默认按 device 走（插电脑就是 RNDIS 网卡）；
	 * 插上 OTG 转接头检测到外设时自动切 host（键鼠可用） */
	role-switch-default-mode = "peripheral";
};'''
if old_dwc3 not in dts:
    sys.exit("!! 找不到 &usb_1_dwc3 原文，中止")
dts = dts.replace(old_dwc3, new_dwc3, 1)
changes.append("&usb_1_dwc3 补 role-switch-default-mode = peripheral")

# ---------- 6: BQ25970（默认注释，附启用说明） ----------
bq_block = '''
/*
 * TI BQ25970 并联快充（可选，默认不启用）
 * 原 DTS 里 &i2c15 是 disabled，且节点是 standalone 形态（0x66）。
 * ⚠️ 启用前需要先确认本机是单颗还是主从两颗，以及电量计是外挂还是 PMIC 内置：
 *      adb shell ls /sys/bus/i2c/devices/          # 看 i2c 上挂了什么
 *      adb shell cat /sys/class/power_supply/battery/name
 * 确认后再取消下面注释，并把 &i2c15 改成 status = "okay"。
 * 参考实现见 Armbian 补丁 0022-arm64-dts-qcom-sm8250-xiaomi-elish-add-bq25970-charg.patch
 *
 * &i2c15 {
 * 	clock-frequency = <400000>;
 * 	status = "okay";
 *
 * 	bq25970: bq25970-standalone@66 {
 * 		compatible = "ti,bq2597x-standalone";
 * 		reg = <0x66>;
 * 		interrupt-parent = <&tlmm>;
 * 		interrupts = <68 0x2002>;
 * 		pinctrl-names = "default";
 * 		pinctrl-0 = <&bq2597x_master_int_default>;
 * 		ti,bq2597x,bat-ovp-alarm-disable;
 * 		ti,bq2597x,bat-ocp-disable;
 * 		ti,bq2597x,bat-ocp-alarm-disable;
 * 		ti,bq2597x,bat-ucp-alarm-disable;
 * 		ti,bq2597x,bat-ucp-disable;
 * 		ti,bq2597x,bat-therm-disable;
 * 		ti,bq2597x,bus-therm-disable;
 * 		ti,bq2597x,die-therm-disable;
 * 		ti,bq2597x,bat-ovp-threshold = <4550>;
 * 		ti,bq2597x,bat-ovp-alarm-threshold = <4525>;
 * 		ti,bq2597x,bus-ovp-threshold = <12000>;
 * 		ti,bq2597x,bus-ovp-alarm-threshold = <11000>;
 * 		ti,bq2597x,bus-ocp-threshold = <3750>;
 * 		ti,bq2597x,bus-ocp-alarm-threshold = <3500>;
 * 		ti,bq2597x,bat-therm-threshold = <0x15>;
 * 		ti,bq2597x,bus-therm-threshold = <0x15>;
 * 		ti,bq2597x,die-therm-threshold = <145>;
 * 		ti,bq2597x,ac-ovp-threshold = <14>;
 * 	};
 * };
 *
 * 另需在 &tlmm 里补上 pinctrl（原 DTS 引用了但没定义）：
 *
 * 	bq2597x_master_int_default: bq2597x-master-int-default {
 * 		pins = "gpio68";
 * 		function = "gpio";
 * 		drive-strength = <2>;
 * 		bias-pull-up;
 * 		input-enable;
 * 	};
 */
'''
# 插在 //TODO: Port the CHARGER Driver 之后
todo = "//TODO: Port the CHARGER Driver"
if todo not in dts:
    sys.exit("!! 找不到 CHARGER TODO 锚点，中止")
dts = dts.replace(todo, todo + "\n" + bq_block.rstrip("\n"), 1)
changes.append("新增 BQ25970 快充节点（默认注释，附启用说明）")

# ---------- 写文件 ----------
out = os.path.join(OUTDIR, "sm8250-xiaomi-umi-common.dtsi")
open(out, "w", encoding="utf-8", newline="").write(dts)
print("已生成:", out)
print("原始 %d 字节 -> 修复版 %d 字节" % (len(orig), len(dts)))
print()
print("改动清单:")
for i, c in enumerate(changes, 1):
    print(f"  {i}. {c}")

# 面板变体
for variant, model in (("csot", "Xiaomi Mi 10 (CSOT)"), ("sms", "Xiaomi Mi 10 (SMS)")):
    body = f'''// SPDX-License-Identifier: BSD-3-Clause
/*
 * Xiaomi Mi 10 — {model}
 */

/dts-v1/;

#include "sm8250-xiaomi-umi-common.dtsi"

/ {{
	model = "{model}";
	compatible = "xiaomi,umi", "qcom,sm8250";
}};

/*
 * 面板驱动在 umi 上尚未可用（drm/msm 的 DSC CMD Mode 问题，
 * https://gitlab.freedesktop.org/drm/msm/-/issues/42），
 * 无头服务器不需要显示输出，因此保持关闭。
 * 系统通过 bootloader 留下的 simple-framebuffer 输出控制台，
 * 用内核参数 consoleblank=60 让 AMOLED 黑屏（= 等效熄屏）。
 *
 * 如果将来想启用屏幕，取消下面注释并解决 DSC CMD Mode 问题：
 *
 * &display_panel {{
 * 	compatible = "xiaomi-umi-{variant}";
 * 	status = "okay";
 * }};
 */
'''
    p = os.path.join(OUTDIR, f"sm8250-xiaomi-umi-{variant}.dts")
    open(p, "w", encoding="utf-8", newline="").write(body)
    print("已生成:", p)


# ===========================================================================
#  生成后校验 —— 防止"注释被 */ 提前截断""label 未定义"这类坑
# ===========================================================================
import re as _re

# 这些 label 不在上游 dtsi 里，是 Armbian 补丁集加上去的：
#   0029 给 pm8150b.dtsi 加 pm8150b_charger: charger@1000
#   0027 给 pm8150b.dtsi 加 pm8150b_fg: fuel-gauge@4000
PATCH_ADDED_LABELS = {"pm8150b_charger", "pm8150b_fg"}


def _strip_comments(text):
    """按 C 词法扫描去注释；返回 (去注释后的文本, 错误列表)。
    不用正则 —— 正则无法发现 '*/' 提前截断注释这种问题。"""
    out, errs, i, n = [], [], 0, len(text)
    while i < n:
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            if j < 0:
                errs.append("块注释 /* 未闭合")
                break
            out.append(" " * (j + 2 - i))
            i = j + 2
        elif text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        else:
            out.append(text[i])
            i += 1
    return "".join(out), errs


def validate_dts(text, name, upstream_labels):
    errs, warns = [], []

    # --- 1) 注释配对 ---
    if text.count("/*") != text.count("*/"):
        errs.append(f"注释不配对：/* {text.count('/*')} 个，*/ {text.count('*/')} 个")

    stripped, serrs = _strip_comments(text)
    errs.extend(serrs)

    # --- 2) 去注释后不应残留注释续行（'*/' 提前截断的典型症状）---
    for i, ln in enumerate(stripped.split("\n"), 1):
        t = ln.strip()
        if t.startswith("* ") or t == "*":
            errs.append(f"第 {i} 行在代码位置出现注释续行（注释可能被 */ 提前截断）：{t[:60]}")

    # --- 3) 花括号平衡 ---
    if stripped.count("{") != stripped.count("}"):
        errs.append(f"花括号不平衡：{{ {stripped.count('{')} 个，}} {stripped.count('}')} 个")

    # --- 4) label 解析 ---
    refs = set(_re.findall(r"&([a-z0-9_]+)", stripped))
    selfdef = set(_re.findall(r"^\s*([a-z0-9_]+):\s", stripped, _re.M))
    # /delete-node/ 的目标必须在上游存在
    for d in _re.findall(r"/delete-node/\s*&([a-z0-9_]+)", stripped):
        if d not in upstream_labels:
            errs.append(f"/delete-node/ &{d} —— 上游没有这个 label")

    unknown = sorted(r for r in refs
                     if r not in upstream_labels
                     and r not in selfdef
                     and r not in PATCH_ADDED_LABELS)
    if unknown:
        errs.append("以下 label 无法解析（上游没有、本文件也没定义）：" + ", ".join(unknown))

    print(f"  [{name}] 引用 label {len(refs)} 个 / 自建 {len(selfdef)} 个 / 补丁新增 {len(PATCH_ADDED_LABELS)} 个")
    for e in errs:
        print(f"      !! {e}")
    for w in warns:
        print(f"      ~  {w}")
    if not errs:
        print("      OK 校验通过")
    return not errs


if __name__ == "__main__":
    import urllib.request as _u
    _ver = "v6.18"
    _base = f"https://raw.githubusercontent.com/torvalds/linux/{_ver}/arch/arm64/boot/dts/qcom"
    _txt = ""
    for _f in ("sm8250.dtsi", "pm8150b.dtsi", "pm8150.dtsi", "pm8150l.dtsi", "pm8009.dtsi"):
        try:
            _txt += _u.urlopen(_u.Request(f"{_base}/{_f}",
                                          headers={"User-Agent": "r"}), timeout=60).read().decode("utf-8", "replace")
        except Exception as _e:
            print(f"  (拉取 {_f} 失败：{_e})")
    _up = set(_re.findall(r"^\s*([a-z0-9_]+):\s*[a-zA-Z0-9,\-]+@", _txt, _re.M))
    _up |= set(_re.findall(r"^\s*([a-z0-9_]+):\s*[a-zA-Z0-9,\-]+\s*\{", _txt, _re.M))
    print(f"\n上游 {_ver} 已知 label：{len(_up)} 个\n")
    _ok = True
    for _f in ("sm8250-xiaomi-umi-common.dtsi",
               "sm8250-xiaomi-umi-csot.dts",
               "sm8250-xiaomi-umi-sms.dts"):
        _p = os.path.join(OUTDIR, _f)
        _ok &= validate_dts(open(_p, encoding="utf-8").read(), _f, _up)
    print()
    print("全部校验通过" if _ok else "!! 存在校验失败项")
    sys.exit(0 if _ok else 1)
