#!/bin/bash
#
# SPDX-License-Identifier: GPL-2.0-only
#
# check.sh — 里程碑验收脚本
#
#   ./tools/check.sh <milestone>
#
# 每个里程碑的判定都是客观的，返回 0 = 通过，1 = 不通过。
# 未实现的里程碑会明确报告 "NOT IMPLEMENTED" 而不是悄悄通过。
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
CACHE="${ROOT}/.cache"

pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; FAILED=$((FAILED+1)); }
skip() { echo "  [SKIP] $*"; }
info() { echo "  ....   $*"; }

FAILED=0
MILESTONE="${1:-}"

# 参考固件（仅用于分析，不属于交付物）
need_ref_firmware() {
	if [[ ! -f "${CACHE}/firmware.bin" ]]; then
		echo "  参考固件缺失。运行:" >&2
		echo "    ${HERE}/fetch-reference-firmware.sh" >&2
		return 1
	fi
	return 0
}

# --------------------------------------------------------------- m0 -----
check_m0() {
	echo "=== M0: 工具链与规格 ==="
	need_ref_firmware || { fail "缺少参考固件"; return 1; }

	# 1. ARM 交叉工具链
	if command -v arm-none-eabi-gcc >/dev/null; then
		pass "ARM 交叉工具链: $(arm-none-eabi-gcc -dumpversion)"
	else
		fail "缺少 arm-none-eabi-gcc"
	fi

	# 2. 分析器能提取命令表
	if python3 "${HERE}/fw-analyze.py" commands "${CACHE}/firmware.bin" \
			--json "${CACHE}/commands.json" > "${CACHE}/cmd.out" 2>&1; then
		pass "命令表提取 + 运行时自校验通过"
		info "$(grep -oE '命令表 @ .*' "${CACHE}/cmd.out" | head -1)"
		grep -oE '运行时自校验 \*\*通过\*\*: .*' "${CACHE}/cmd.out" | sed 's/^/  /'
	else
		fail "命令表提取或自校验失败"
		sed 's/^/        /' "${CACHE}/cmd.out" | head -20
	fi

	# 3. 规格文档已存在且非空
	for f in docs/PLAN.md; do
		if [[ -s "${ROOT}/$f" ]]; then
			pass "规格文档存在: $f ($(wc -l < "${ROOT}/$f") 行)"
		else
			fail "缺少 $f"
		fi
	done

	# 4. 提取器产物已入库（规格的机器可读形式）
	if [[ -s "${ROOT}/docs/isp-commands.md" ]]; then
		pass "命令规格文档已入库 ($(grep -c '^| ' "${ROOT}/docs/isp-commands.md") 行表格)"
	else
		fail "缺少 docs/isp-commands.md"
	fi
}

# --------------------------------------------------------------- m1 -----
check_m1() {
	echo "=== M1: 自研固件启动（项目分水岭）==="
	if [[ ! -f "${ROOT}/fw/s2isp.elf" ]]; then
		echo "  [NOT IMPLEMENTED] 尚未构建自研固件 fw/s2isp.elf"
		return 1
	fi
	fail "M1 判定尚未实现"
}

# --------------------------------------------------------------- m2..m6 -
check_generic() {
	local m="$1"
	echo "=== ${m} ==="
	echo "  [NOT IMPLEMENTED] 该里程碑的判定尚未实现"
	return 1
}

case "$MILESTONE" in
	m0) check_m0 ;;
	m1) check_m1 ;;
	m2|m3|m4|m5|m6) check_generic "${MILESTONE^^}" ;;
	all)
		for m in m0 m1 m2 m3 m4 m5 m6; do
			check_$m 2>/dev/null || true
			echo
		done
		;;
	*) echo "用法: $0 {m0|m1|m2|m3|m4|m5|m6|all}" >&2; exit 2 ;;
esac

echo
if [[ $FAILED -eq 0 ]]; then
	echo "结果: 全部通过"
	exit 0
else
	echo "结果: $FAILED 项未通过"
	exit 1
fi
