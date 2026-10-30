#!/bin/bash
#
# SPDX-License-Identifier: GPL-2.0-only
#
# fetch-reference-firmware.sh — 取一份 Apple ISP 固件镜像放到 .cache/ 供**分析**用
#
# 重要: 这不是交付物的一部分。
#   .cache/ 已在 .gitignore 中，发布产物里不会包含任何 Apple 二进制。
#   这里取镜像只是为了**观测硬件接口**（命令表、寄存器访问、握手序列），
#   我们的固件与驱动实现全部从零编写。
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
CACHE="${ROOT}/.cache"
mkdir -p "$CACHE"

# 复用 bcwc_pcie 的提取器（内容寻址，CDN 失效也能工作）
FETCHER="${BCWC_FETCHER:-}"
if [[ -z "$FETCHER" ]]; then
	for c in "${ROOT}/../bcwc_pcie/tools/fetch-firmware.sh" \
	         "${HOME}/GitHub/bcwc_pcie/tools/fetch-firmware.sh"; do
		[[ -f "$c" ]] && { FETCHER="$c"; break; }
	done
fi

if [[ -n "$FETCHER" && -x "$FETCHER" ]]; then
	echo "==> 用 $FETCHER 提取"
	"$FETCHER" --dest "$CACHE"
else
	echo "==> 未找到 bcwc_pcie 的提取器，请手动提供一份 firmware.bin 到 $CACHE/" >&2
	exit 1
fi

echo
echo "已就绪: ${CACHE}/firmware.bin"
echo "（仅供分析，不会进入发布产物）"
