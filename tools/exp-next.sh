#!/bin/bash
#
# SPDX-License-Identifier: GPL-2.0-only
#
# exp-next.sh — M1 寄存器基址定位实验（一次跑完一轮）
#
# 前提: ISP CPU 必须是**干净**状态（刚开机的状态）。
#   原因: 旧固件会在 I-Cache 里继续跑并覆写 DDR，导致我们的固件根本没机会执行。
#   而 S2 芯片的 ACPI 电源周期虽然能复位 ISP CPU，但会让 PCIe 链路断开且
#   设备无法重新枚举（需要整机重启），所以实验之间只能靠重启来复位。
#
# 用法:
#   ./exp-next.sh <stop_mask>      # stop_mask 位定义:
#                                     bit0 写 0 到 ISP_REG_40004
#                                     bit1 写 0 到 ISP_REG_40008
#                                     bit2 写 0 到 ISP_REG_41020
#   ./exp-next.sh --fw <file> <stop_mask>
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

FW="${ROOT}/fw/s2isp.bin"
STOP=0

if [[ "${1:-}" == "--fw" ]]; then
	FW="$2"; STOP="${3:-0}"
else
	STOP="${1:-0}"
fi

PROBE_DRIVER="${PROBE_DRIVER:-/tmp/fwprobe2/facetimehd.ko}"
FW_DIR="/usr/lib/firmware/facetimehd"
[[ -d /usr/lib/firmware ]] || FW_DIR="/lib/firmware/facetimehd"

echo "############################################################"
echo "# 实验: stop_mask=0x$STOP  固件=$(basename "$FW")"
echo "############################################################"

if [[ ! -f "$PROBE_DRIVER" ]]; then
	echo "!! 缺少探针驱动 $PROBE_DRIVER"
	echo "   构建: python3 tools/make-probe-driver.py <驱动源码> /tmp/fwprobe2 && make -C /tmp/fwprobe2"
	exit 1
fi

echo "==> 安装固件"
install -m644 "$FW" "${FW_DIR}/firmware.bin"

echo "==> 卸载旧模块"
modprobe -r facetimehd 2>/dev/null
sleep 1

echo "==> 装载探针驱动 (zap=1 stop=$STOP)"
for m in videobuf2_common videobuf2_memops videobuf2_v4l2 videobuf2_dma_sg videodev; do
	modprobe "$m" 2>/dev/null
done
if insmod "$PROBE_DRIVER" probe_zap=1 probe_stop=$STOP 2>&1 | head -2; then
	:
fi

echo "==> 重新枚举设备"
if [ -d /sys/bus/pci/devices/0000:02:00.0 ]; then
	echo 1 > /sys/bus/pci/devices/0000:02:00.0/remove 2>/dev/null
	sleep 2
fi
echo 1 > /sys/bus/pci/rescan 2>/dev/null
sleep 20

echo
echo "==> 结果"
LOG=/tmp/exp-$(date +%H%M%S).txt
dmesg > "$LOG"
echo "    日志: $LOG"

grep -E 'Loaded firmware|PROBE: DDR|stop seq' "$LOG" | tail -4 | sed 's/^/    /'

echo
if grep -q 'PROBE-FOUND' "$LOG"; then
	echo "    ★★★ 命中! ★★★"
	grep 'PROBE-FOUND' "$LOG" | sed 's/^/    /'
else
	echo "    未命中。"
fi

if grep -q '50424545' "$LOG"; then
	echo "    ✓ 探针固件执行了 (找到 PRBE 签名)"
else
	echo "    ✗ 探针固件没有执行"
fi

echo
echo "    DDR0[0:8]:"
grep -A2 'PROBE-DDR0:' "$LOG" | tail -3 | sed 's/^/      /'
echo
echo "    DDR80000 非零字:"
python3 - "$LOG" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding='utf-8', errors='replace').read().split('\n')
idx = [i for i, l in enumerate(lines) if 'PROBE-DDR80000:' in l]
if not idx:
    print("      (无)"); raise SystemExit
vals = []; i = idx[-1] + 1
while i < len(lines):
    m = re.match(r'^\[\s*\d+\.\d+\]\s+([0-9a-f]{8})\s*$', lines[i])
    if m:
        vals.append(m.group(1)); i += 1
    elif vals:
        break
    else:
        i += 1
nz = [(i, v) for i, v in enumerate(vals) if v != '00000000']
print(f"      非零 {len(nz)} 个")
for i, v in nz[:12]:
    print("      +0x%03x  %s" % (i * 4, v))
PY
