#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""
make-probe-driver.py — 给现有驱动打上研究用探针，生成一个专用内核模块

用途：
  在 M1 实验期间需要观测两个通道：
    1. ISP BAR 里的内容（找探针固件写下的图案 0xC0DE00xx）
    2. DDR 的内容（看探针固件跑到哪一步）
  这些观测点要放在**握手失败路径**上，否则探针固件跑不起来时看不到数据。

用法：
  make-probe-driver.py <驱动源码目录> <输出目录>
"""
import os
import re
import shutil
import sys

# ---------------------------------------------------------------- 补丁内容 --

PATCH_DRIVER_H = r'''
struct fthd_private {
	void *probe_fw;
	size_t probe_fw_size;
'''

PATCH_ISP_H_PROTOS = '''
static void fthd_probe_dump(struct fthd_private *dev_priv);
static int probe_zap;
static int probe_stop;
module_param(probe_zap, int, 0644);
module_param(probe_stop, int, 0644);
MODULE_PARM_DESC(probe_zap, "zero DDR before load");
MODULE_PARM_DESC(probe_stop, "stop ISP CPU before load (bit0:0x40004 bit1:0x40008 bit2:0x41020)");
'''

# 载入固件前: 可选停 CPU + 清 DDR + 缓存固件
PATCH_LOAD = '''	/* PROBE: 可选动作，由模块参数控制 */
	if (probe_stop) {
		if (probe_stop & 1) { FTHD_ISP_REG_WRITE(0, ISP_REG_40004); pr_info("PROBE: stop 40004\\n"); }
		if (probe_stop & 2) { FTHD_ISP_REG_WRITE(0, ISP_REG_40008); pr_info("PROBE: stop 40008\\n"); }
		if (probe_stop & 4) { FTHD_ISP_REG_WRITE(0, ISP_REG_41020); pr_info("PROBE: stop 41020\\n"); }
		msleep(100);
		pr_info("PROBE: stop seq done, readback 40004=%08x 41020=%08x\\n",
			FTHD_ISP_REG_READ(ISP_REG_40004), FTHD_ISP_REG_READ(ISP_REG_41020));
	}
	if (probe_zap) {
		u32 z;
		for (z = 0; z < 0x1000000; z += 4)
			FTHD_S2_MEM_WRITE(0, z);
		pr_info("PROBE: DDR 0..16MB zeroed\\n");
	}

'''

PATCH_CACHE = '''	/* PROBE: 缓存固件内容 */
	dev_priv->probe_fw = kmalloc(fw->size, GFP_KERNEL);
	if (dev_priv->probe_fw) {
		memcpy(dev_priv->probe_fw, fw->data, fw->size);
		dev_priv->probe_fw_size = fw->size;
		pr_info("PROBE: firmware cached (%u bytes)\\n", fw->size);
	}

'''

PATCH_DUMP_FN = '''static void fthd_probe_dump(struct fthd_private *dev_priv)
{
	u32 i, v;
	pr_info("PROBE-ISP:");
	for (i = 0xc3000; i <= 0xc3020; i += 4)
		pr_info(" %08x", FTHD_ISP_REG_READ(i));
	pr_info("\\n");
	/* 扫描整个 ISP BAR，找探针固件写下的图案 0xC0DE00xx */
	for (i = 0; i + 4 <= dev_priv->isp_io_len; i += 4) {
		v = FTHD_ISP_REG_READ(i);
		if ((v & 0xffff0000) == 0xc0de0000) {
			pr_info("PROBE-FOUND: pattern %08x at ISP BAR offset 0x%x => base = 0xb0800000 + 0x%x = 0x%x\\n",
				v, i, (int)(i - 0x40004), 0xb0800000 + (int)(i - 0x40004));
		}
	}
	pr_info("PROBE-DDR80000:");
	for (i = 0; i < 600; i++) {
		v = FTHD_S2_MEM_READ(0x80000 + i * 4);
		pr_info(" %08x", v);
	}
	pr_info("\\n");
	pr_info("PROBE-DDR0:");
	for (i = 0; i < 16; i++) {
		v = FTHD_S2_MEM_READ(i * 4);
		pr_info(" %08x", v);
	}
	pr_info("\\n");
}

'''

PATCH_CALL = '''		fthd_probe_dump(dev_priv);
'''

PATCH_TIMEOUT_CALL = '''		fthd_probe_dump(dev_priv);
'''


def patch_file(path, replacements):
    s = open(path, encoding='utf-8').read()
    for old, new in replacements:
        if old not in s:
            print(f"  !! 模式未找到 in {os.path.basename(path)}: {old[:50]!r}")
            continue
        s = s.replace(old, new, 1)
    open(path, 'w', encoding='utf-8').write(s)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    src, dst = sys.argv[1], sys.argv[2]

    if os.path.exists(dst):
        shutil.rmtree(dst)
    shutil.copytree(src, dst)
    for junk in ('.o', '.ko', '.mod', '.mod.c', 'Module.symvers', 'modules.order', '.tmp_versions'):
        for root, dirs, files in os.walk(dst):
            for f in files:
                if f.endswith(junk) or f == junk:
                    try:
                        os.remove(os.path.join(root, f))
                    except OSError:
                        pass

    # fthd_drv.h: 结构体加字段（已存在则跳过，保证脚本幂等）
    p = os.path.join(dst, 'fthd_drv.h')
    s = open(p, encoding='utf-8').read()
    if 'probe_fw;' not in s:
        s = s.replace('struct fthd_private {', PATCH_DRIVER_H, 1)
        open(p, 'w', encoding='utf-8').write(s)
    print("  patched fthd_drv.h")

    # fthd_isp.c: 探针主体
    p = os.path.join(dst, 'fthd_isp.c')
    s = open(p, encoding='utf-8').read()

    # 1) 参数与原型
    s = s.replace('#include "fthd_isp.h"', '#include "fthd_isp.h"\n' + PATCH_ISP_H_PROTOS, 1)

    # 2) dump 函数定义（放在 isp_load_firmware 之前）
    anchor = 'static int isp_load_firmware(struct fthd_private *dev_priv)'
    s = s.replace(anchor, PATCH_DUMP_FN + anchor, 1)

    # 3) 载入前: 停 CPU / 清 DDR
    anchor = '\tFTHD_S2_MEMCPY_TOIO(dev_priv->firmware->offset, fw->data, fw->size);'
    s = s.replace(anchor, PATCH_LOAD + anchor, 1)

    # 4) 缓存固件
    anchor = '\tFTHD_S2_MEMCPY_TOIO(dev_priv->firmware->offset, fw->data, fw->size);'
    s = s.replace(anchor, anchor + '\n' + PATCH_CACHE, 1)

    # 5) 成功路径 dump
    anchor = '\t\tdev_info(&dev_priv->pdev->dev, "magic value: %08x after %d ms\\n", reg, (retries - 1) * 10);'
    s = s.replace(anchor, anchor + '\n\t\tfthd_probe_dump(dev_priv);', 1)

    # 6) 超时路径 dump
    anchor = '\t\tdev_info(&dev_priv->pdev->dev, "Init failed! No wake signal\\n");'
    s = s.replace(anchor, anchor + '\n\t\tfthd_probe_dump(dev_priv);', 1)

    open(p, 'w', encoding='utf-8').write(s)
    print("  patched fthd_isp.c")
    print(f"完成: {dst}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
