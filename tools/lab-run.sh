#!/bin/bash
#
# SPDX-License-Identifier: GPL-2.0-only
#
# lab-run.sh — M1 实验的安全执行循环
#
# 背景:
#   ISP CPU 跨模块重载**不复位**。旧固件仍在它的 I-Cache 里执行，
#   会把新固件的复位向量覆写掉，导致「我们的固件根本不跑」——
#   这是早期实验反复失败的真正原因（不是固件写错）。
#
#   唯一可靠的复位手段是给 S2 芯片做电源周期（ACPI CMPE），
#   但断电会让 PCIe 链路断开、设备从总线消失，需要重新枚举。
#
# 本脚本把这两个动作打包成幂等的一步：
#     1. ACPI 电源周期（复位 ISP CPU 与 I-Cache）
#     2. PCI 设备 remove + rescan（让设备回到总线上）
#     3. 装载指定固件（默认自研探针固件）
#     4. 读回观测数据
#
# 用法:
#   ./lab-run.sh                 # 用默认探针固件跑一轮
#   ./lab-run.sh --fw <file>     # 指定固件
#   ./lab-run.sh --no-cycle      # 跳过电源周期（仅重新枚举）
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

FW="${ROOT}/fw/s2isp.bin"
DO_CYCLE=1
KEEP=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--fw)        FW="$2"; shift 2 ;;
		--no-cycle)  DO_CYCLE=0; shift ;;
		--keep)      KEEP=1; shift ;;
		-h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
		*) echo "未知参数: $1" >&2; exit 1 ;;
	esac
done

FW_DIR="/usr/lib/firmware/facetimehd"
[[ -d /usr/lib/firmware ]] || FW_DIR="/lib/firmware/facetimehd"
S2POWER="/tmp/s2acpi/s2power.ko"

echo "==> [1/5] 准备固件 $(basename "$FW")"
install -m644 "$FW" "${FW_DIR}/firmware.bin"

echo "==> [2/5] 卸载模块"
modprobe -r facetimehd 2>/dev/null
sleep 1

if [[ $DO_CYCLE -eq 1 ]]; then
	echo "==> [3/5] S2 芯片电源周期（复位 ISP CPU + I-Cache）"
	if [[ -f "$S2POWER" ]]; then
		rmmod s2power 2>/dev/null
		insmod "$S2POWER" cycle=1 2>&1 | grep -v '^$' | head -3
		rmmod s2power 2>/dev/null
	else
		echo "    !! 找不到 $S2POWER，跳过（ISP CPU 可能不会复位）"
	fi
	sleep 2
else
	echo "==> [3/5] 跳过电源周期"
fi

echo "==> [4/5] 重新枚举 PCI 设备"
# 电源周期后设备可能已从总线消失
if [ -d /sys/bus/pci/devices/0000:02:00.0 ]; then
	echo 1 > /sys/bus/pci/devices/0000:02:00.0/remove 2>/dev/null
	sleep 2
fi
echo 1 > /sys/bus/pci/rescan 2>/dev/null
sleep 3

# 重新枚举后内核会自动 modprobe facetimehd；确保 videobuf2 依赖就位
for m in videobuf2_common videobuf2_memops videobuf2_v4l2 videobuf2_dma_sg videodev; do
	modprobe "$m" 2>/dev/null
done
modprobe facetimehd 2>/dev/null
sleep 5

echo "==> [5/5] 结果"
if [ -e /dev/video0 ]; then
	echo "    /dev/video0 就绪"
	v4l2-ctl -d /dev/video0 --stream-mmap=4 --stream-count=10 --stream-to=/dev/null 2>&1 | tail -1
else
	echo "    无 /dev/video0（用我们的探针固件时这是预期的）"
fi
echo
dmesg | grep -iE 'facetimehd|fthd|s2power' | tail -14
