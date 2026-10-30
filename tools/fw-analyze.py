#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""
fw-analyze.py — S2 ISP 固件镜像分析器

从 Apple 的 ISP 固件镜像中提取协议事实，用于**独立实现**我们的固件与驱动。

本工具不复制任何代码：它只做观测 —— 扫描镜像、定位结构、提取常量表，
产出的是关于**接口**的知识（opcode、命令名、寄存器访问位置），
而不是可执行的实现。

子命令:
  commands <image>            提取 CISP 命令表 (opcode <-> 名称)
  commands <image> --json X   同时输出 JSON
  buildinfo <image>           提取构建元数据 (版本/ISA/编译器)
  vectors <image>             定位 ARM 向量表与入口点
  mmioreg <image>             统计 MMIO 寄存器访问热点
"""
import argparse
import json
import os
import re
import struct
import sys

# 命令名表: 411 项 {u32 name_ptr, u32 id}
CMD_TABLE_OFF = 0x0b22f0
CMD_TABLE_LEN = 411

# 已知的运行时观测值 —— 固件自己打印过的 "CMD = 0xNNNN [NAME]"
# 用于验证提取规则的正确性（自校验，不依赖任何外部实现）
RUNTIME_OBSERVED = {
    "CISP_CMD_STOP": 0x0001,
    "CISP_CMD_CONFIG_GET": 0x0003,
    "CISP_CMD_PRINT_ENABLE": 0x0004,
    "CISP_CMD_CH_START": 0x0100,
    "CISP_CMD_CH_STOP": 0x0101,
    "CISP_CMD_CH_BUFFER_RETURN": 0x0104,
    "CISP_CMD_CH_CAMERA_CONFIG_GET": 0x0106,
    "CISP_CMD_CH_CAMERA_CONFIG_SELECT": 0x0107,
    "CISP_CMD_CH_INFO_GET": 0x010d,
    "CISP_CMD_CH_BUFFER_RECYCLE_MODE_SET": 0x010e,
}


def load(path):
    with open(path, 'rb') as f:
        return f.read()


def cstr(data, off, maxlen=80):
    end = data.find(b'\x00', off, off + maxlen)
    if end < 0:
        return ''
    try:
        return data[off:end].decode('ascii')
    except UnicodeDecodeError:
        return ''


# --------------------------------------------------------------- commands --

def extract_commands(data, table_off=CMD_TABLE_OFF, table_len=CMD_TABLE_LEN):
    """提取命令表。

    表项为 8 字节 {u32 name_ptr, u32 id}，按 id 升序。
    **线协议 opcode = id - 1**（已由固件自身的运行时调试输出验证）。
    """
    out = []
    for i in range(table_len):
        base = table_off + i * 8
        if base + 8 > len(data):
            break
        name_ptr, ident = struct.unpack_from('<II', data, base)
        name = cstr(data, name_ptr)
        if not name.startswith('CISP_CMD_'):
            continue
        out.append({
            'index': i,
            'name': name,
            'id': ident,
            'opcode': ident - 1,
        })
    return out


def cmd_commands(args):
    data = load(args.image)
    cmds = extract_commands(data, args.table_off, args.table_len)

    # 自校验: 与运行时观测值比对
    by_name = {c['name']: c['opcode'] for c in cmds}
    mismatches = []
    for name, expect in RUNTIME_OBSERVED.items():
        got = by_name.get(name)
        if got != expect:
            mismatches.append((name, expect, got))

    groups = {}
    for c in cmds:
        groups.setdefault(c['opcode'] >> 8, []).append(c)

    if args.json:
        with open(args.json, 'w') as f:
            json.dump({
                'image': os.path.basename(args.image),
                'table_offset': args.table_off,
                'rule': 'wire_opcode = id - 1',
                'count': len(cmds),
                'groups': {hex(k): len(v) for k, v in sorted(groups.items())},
                'runtime_selfcheck': {
                    'checked': len(RUNTIME_OBSERVED),
                    'mismatches': [
                        {'name': n, 'expected': e, 'got': g} for n, e, g in mismatches
                    ],
                    'pass': not mismatches,
                },
                'commands': cmds,
            }, f, indent=2, ensure_ascii=False)
        print("JSON -> %s" % args.json)

    print("命令表 @ 0x%08x, 共 %d 项" % (args.table_off, len(cmds)))
    print("opcode 分组 (高字节):")
    for k, v in sorted(groups.items()):
        print("   0x%02xx  %3d 条" % (k, len(v)))
    print()
    if mismatches:
        print("运行时自校验 **失败**:")
        for n, e, g in mismatches:
            print("   %-45s 期望 0x%x 实得 %s" % (n, e, g))
        return 1
    print("运行时自校验 **通过**: %d/%d 条固件自报 opcode 与表推导值一致"
          % (len(RUNTIME_OBSERVED), len(RUNTIME_OBSERVED)))
    return 0


# -------------------------------------------------------------- buildinfo --

def cmd_buildinfo(args):
    data = load(args.image)
    print("=== 构建元数据 ===")
    # 元数据块位于 0x1000 附近
    region = data[0x1000:0x1200]
    for m in re.finditer(rb'[ -~]{4,}', region):
        print("   0x%04x  %s" % (0x1000 + m.start(), m.group().decode()))

    print()
    print("=== 版本标识探测 ===")
    for pat in (rb'S2ISP-[0-9.]+', rb'H4[A-Z]+', rb'ffw'):
        for m in re.finditer(pat, data):
            print("   0x%06x  %s" % (m.start(), m.group().decode()))
            break
    return 0


# --------------------------------------------------------------- vectors --

def cmd_vectors(args):
    """定位 ARM 向量表与入口点。"""
    data = load(args.image)
    print("=== ARM 向量表 ===")
    words = [struct.unpack_from('<I', data, i)[0] for i in range(0, 0x40, 4)]
    for i, w in enumerate(words):
        kind = ''
        if (w & 0x0f000000) == 0x0a000000:
            imm = w & 0x00ffffff
            if imm & 0x800000:
                imm -= 0x1000000
            kind = '  ; b 0x%x' % (i * 4 + 8 + imm * 4)
        print("   +0x%02x  0x%08x%s" % (i * 4, w, kind))

    # 入口点
    w0 = words[0]
    if (w0 & 0x0f000000) == 0x0a000000:
        imm = w0 & 0x00ffffff
        if imm & 0x800000:
            imm -= 0x1000000
        entry = 8 + imm * 4
        print()
        print("复位入口点 = 0x%08x" % entry)
        print()
        print("=== 入口点反汇编 ===")
        for i in range(entry, min(entry + 96, len(data)), 4):
            w = struct.unpack_from('<I', data, i)[0]
            cond = (w >> 28) & 0xf
            op = (w >> 25) & 0x7
            if op == 0x5 and cond == 0xe:
                crn, crd, crm, op2, c = (w >> 16) & 0xf, (w >> 12) & 0xf, \
                    (w >> 8) & 0xf, (w >> 5) & 0xf, w & 0x1f
                print("   0x%08x  mcr  p15, %d, r%d, cr%d, cr%d, {%d}"
                      % (i, c, crd, crn, crm, op2))
            elif (w & 0x0ffffff0) == 0x012fff10:
                print("   0x%08x  bx  r%d" % (i, w & 0xf))
            elif (w & 0x0f000000) == 0x0f000000:
                print("   0x%08x  svc/mcr-class 0x%08x" % (i, w))
            else:
                print("   0x%08x  0x%08x" % (i, w))
    return 0


# --------------------------------------------------------------- mmioreg --

def cmd_mmioreg(args):
    """统计固件里对 MMIO 寄存器空间的访问热点。

    S2 芯片的寄存器基址由主机侧映射，固件用固定地址访问。
    这里统计访问最密集的偏移，作为「哪些硬件块最重要」的线索。
    """
    data = load(args.image)
    # ARM LDR/STR 立即数偏移: cond 01 I P U B W L Rn Rd offset12
    hits = {}
    for off in range(0, len(data) - 4, 4):
        w = struct.unpack_from('<I', data, off)[0]
        if (w >> 25) & 7 not in (1, 2, 3):   # LDR/STR 类
            continue
        if (w >> 28) & 0xf not in (0xe,):    # 只取无条件执行
            continue
        if (w >> 24) & 1:                   # P=0: pre-indexed 也算
            pass
        imm = w & 0xfff
        rn = (w >> 16) & 0xf
        if rn == 13:                        # 排除栈访问
            continue
        u = (w >> 23) & 1
        if not u:
            imm = -imm
        hits[imm] = hits.get(imm, 0) + 1

    top = sorted(hits.items(), key=lambda kv: -kv[1])[:30]
    print("=== MMIO 偏移访问热点 (top 30) ===")
    print("   偏移      次数")
    for off, c in top:
        print("   0x%08x  %4d" % (off & 0xffffffff, c))
    print()
    print("注意: 这里统计的是固件代码里的立即数偏移，")
    print("      真实寄存器地址 = 基址 + 偏移，基址由主机侧决定。")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)

    p = sub.add_parser('commands')
    p.add_argument('image')
    p.add_argument('--json')
    p.add_argument('--table-off', type=lambda s: int(s, 0), default=CMD_TABLE_OFF)
    p.add_argument('--table-len', type=int, default=CMD_TABLE_LEN)
    p.set_defaults(func=cmd_commands)

    p = sub.add_parser('buildinfo')
    p.add_argument('image')
    p.set_defaults(func=cmd_buildinfo)

    p = sub.add_parser('vectors')
    p.add_argument('image')
    p.set_defaults(func=cmd_vectors)

    p = sub.add_parser('mmioreg')
    p.add_argument('image')
    p.set_defaults(func=cmd_mmioreg)

    args = ap.parse_args()
    return args.func(args)


if __name__ == '__main__':
    sys.exit(main())
