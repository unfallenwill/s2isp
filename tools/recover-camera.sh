#!/bin/bash
#
# SPDX-License-Identifier: GPL-2.0-only
#
# recover-camera.sh — 复位 FaceTime HD 摄像头
#
# 为什么需要这个：
#   现有驱动**没有正确的关停路径**。`fthd_hw_deinit()` 只往 ISP_REG_41020
#   写 0，不对 S2 芯片做电源周期。结果是：热卸载模块后，ISP CPU 仍处于
#   已启动状态，再次加载时不会从复位向量重新取指 —— 表现为
#       Init failed! No wake signal
#   而且**用 Apple 原厂固件也一样失败**，即硬件进入了不可用状态。
#
#   唯一可靠的恢复方式是让 PCI 设备彻底消失再重新枚举，
#   这会触发设备级复位，ISP CPU 随之回到复位向量。
#
#   注意：S3 挂起/恢复**不能**修复（设备保留了内部状态）。
#
# 用法:
#   ./recover-camera.sh                 # 用当前已安装的固件复位
#   ./recover-camera.sh --fw <file>     # 先安装指定固件再复位
#
set -uo pipefail

FW=""
if [[ "${1:-}" == "--fw" ]]; then
	FW="$2"
fi

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "需要 root，请用 sudo" >&2; exit 1; }

FW_DIR="/usr/lib/firmware/facetimehd"
[[ -d /usr/lib/firmware ]] || FW_DIR="/lib/firmware/facetimehd"

if [[ -n "$FW" ]]; then
	[[ -r "$FW" ]] || { echo "找不到 $FW" >&2; exit 1; }
	echo "==> 安装固件 $(basename "$FW") -> $FW_DIR"
	install -m644 "$FW" "$FW_DIR/firmware.bin"
fi

# 找到设备
DEV=""
for d in /sys/bus/pci/devices/*/; do
	if [[ -r "${d}modalias" ]] && grep -q 'v000014E4d00001570' "${d}modalias" 2>/dev/null; then
		DEV="${d}"; break
	fi
done
if [[ -z "$DEV" ]]; then
	echo "找不到 14e4:1570 设备" >&2
	exit 1
fi
echo "==> 设备: ${DEV%/}"

echo "==> 卸载模块"
modprobe -r facetimehd 2>/dev/null
sleep 1

echo "==> 移除 PCI 设备"
echo 1 > "${DEV}remove" 2>&1 || { echo "移除失败" >&2; exit 1; }
sleep 2

echo "==> 重新扫描"
echo 1 > /sys/bus/pci/rescan 2>&1
sleep 6

# 判定标准是「设备重新被探测」，而不是「出现 /dev/video0」——
# 用我们自己的探针固件时握手必然失败，但仍说明复位成功。
if dmesg | tail -30 | grep -q 'Found FaceTime HD camera'; then
	echo "==> 复位成功，设备已重新探测"
	dmesg | grep -iE 'facetimehd' | tail -8
	if [ -e /dev/video0 ]; then
		echo "==> /dev/video0 就绪"
	else
		echo "==> 无 /dev/video0（若加载的是自研探针固件，这是预期的）"
	fi
	exit 0
else
	echo "==> 复位失败，查看 dmesg" >&2
	dmesg | grep -iE 'facetimehd' | tail -12 >&2
	exit 1
fi
