// SPDX-License-Identifier: GPL-2.0-only
/*
 * s2power — Broadcom S2 芯片 (FaceTime HD 摄像头) 的 ACPI 电源控制
 *
 * 背景
 * ----
 * S2 芯片同时包含 ISP 处理器、PCIe 端点与 DDR 控制器。ISP CPU 跑的是
 * 一段加载到 DDR 里的固件，它有独立的 I-Cache。
 *
 * 现有驱动缺少正确的关停路径：fthd_hw_deinit() 只往 ISP_REG_41020 写 0，
 * 不对芯片做电源周期。后果是：
 *
 *   1. 热卸载模块后 ISP CPU 仍处于已启动状态
 *   2. 再次加载时不会从复位向量重新取指 -> "Init failed! No wake signal"
 *   3. 用 Apple 原厂固件也一样失败 —— 硬件进入不可用状态
 *
 * 真正的修复必须让芯片断电重来。DSDT 里找到了对应的 ACPI 序列：
 *
 *    \_SB.PCI0.RP02.CMRA.CMPE(1)   -> 断电
 *         ASPM = S2PM (0x02)
 *         PSTA = 0x00, 等待 PSTA == 0
 *         L23D = 1 (切断 PCIe 链路)
 *    \_SB.PCI0.RP02.CMRA.CMPE(0)   -> 上电
 *         PSTA = 0x03, 等待 PSTA == 0x03
 *         读回 ASPM, 复位 ASPM = 0
 *
 * 这与 Apple 的 AppleCameraInterface.kext 里
 * AppleCamIn::acpiControlS2ChipPower() 走的是同一条路径
 * (kext 反汇编见 artifacts/apple-camera-interface.asm)。
 *
 * 注意
 * ----
 * 断电会让 PCIe 链路断开，设备从总线上消失。上电后需要重新枚举才能恢复，
 * 单靠本模块不足以让摄像头工作。完整恢复流程见 tools/recover-camera.sh。
 *
 * 用法（独立调试用）
 *   insmod s2power.ko state=1    # 断电
 *   insmod s2power.ko state=0    # 上电
 *   insmod s2power.ko cycle=1    # 断电 + 上电
 */

#include <linux/acpi.h>
#include <linux/delay.h>
#include <linux/module.h>
#include <linux/moduleparam.h>

#define S2_ACPI_PATH	"\\_SB.PCI0.RP02.CMRA"
#define S2_ACPI_METHOD	"CMPE"

static int state = -1;
static int cycle;
module_param(state, int, 0444);
module_param(cycle, int, 0444);
MODULE_PARM_DESC(state, "power state: 0=on 1=off (-1 = do nothing)");
MODULE_PARM_DESC(cycle, "1 = power off then power on");

/*
 * 调用 \_SB.PCI0.RP02.CMRA.CMPE(arg)
 */
static int s2_power_call(int arg)
{
	acpi_handle handle = NULL;
	acpi_status st;

	st = acpi_get_handle(NULL, (acpi_string)S2_ACPI_PATH, &handle);
	if (ACPI_FAILURE(st) || !handle) {
		pr_err("s2power: 找不到 ACPI 设备 %s (status=%x)\n",
		       S2_ACPI_PATH, st);
		return -ENODEV;
	}

	pr_info("s2power: %s(%d)\n", S2_ACPI_METHOD, arg);
	st = acpi_execute_simple_method(handle, S2_ACPI_METHOD, (u64)arg);
	if (ACPI_FAILURE(st)) {
		pr_err("s2power: %s(%d) 失败 (status=%x)\n",
		       S2_ACPI_METHOD, arg, st);
		return -EIO;
	}
	return 0;
}

/*
 * 供驱动内部调用的接口
 */
int s2_power_off(void)
{
	return s2_power_call(1);
}

int s2_power_on(void)
{
	return s2_power_call(0);
}

static int __init s2power_init(void)
{
	int ret;

	if (cycle) {
		ret = s2_power_off();
		if (ret)
			return ret;
		msleep(500);
		ret = s2_power_on();
		if (ret)
			return ret;
		msleep(500);
		pr_info("s2power: 电源周期完成，PCIe 链路会短暂断开，"
			"需要重新枚举才能恢复设备\n");
	} else if (state >= 0) {
		ret = s2_power_call(state);
		if (ret)
			return ret;
	}

	return 0;
}

static void __exit s2power_exit(void)
{
	pr_info("s2power: 卸载\n");
}

module_init(s2power_init);
module_exit(s2power_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Broadcom S2 chip ACPI power control (FaceTime HD camera)");
