/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * s2isp — 自研 ISP 固件
 *
 * 当前是 M1 阶段的**探针固件**：用于确定 ISP CPU 用什么地址访问
 * ISP 寄存器窗口。真正的固件功能（握手、通道表、命令处理）在 M1 后续补齐。
 *
 * 探针原理
 * --------
 * 未映射地址的「读」有长超时（>10s），全地址空间盲扫不可行；
 * 但 PCIe 的 posted「写」不等完成，未映射的写很快返回。
 * 于是改用写来定位寄存器窗口：
 *
 *   对每个候选基址 base，往 base + 0xc3018（驱动写 0 的无害寄存器）
 *   写一个唯一图案 0xC0DE0000|序号。主机随后扫描自己的 ISP BAR
 *   （物理 0xb0800000，1MB），若图案出现在偏移 X，则
 *
 *       base + 0xc3018 == 0xb0800000 + X
 *    => base = 0xb0800000 + (X - 0xc3018)
 *
 * 这样就打破了「固件视角 vs 主机视角」的循环依赖。
 *
 * 固件链接在地址 0（= DDR 偏移 0），与参考固件一致，因此可以用普通
 * 的绝对寻址，不需要位置无关代码。
 */

#include <stdint.h>

#define REG_OFF_PROBE	0x40004u	/* BAR 内的可写寄存器（主机写 1 来启动 ISP） */

#define DDR_OUT		0x00080000u	/* 输出区 = DDR 偏移 0x80000 */
#define PATTERN_BASE	0xc0de0000u

/* 候选基址表（放在 .data，由启动代码保证 .bss 已清零） */
static const uint32_t candidates[] = {
	0xb0800000u,	/* ISP IO BAR4 物理 */
	0xb0900000u,	/* S2 IO BAR0 物理 */
	0x00000000u,	/* 别名 0 */
	0x00040000u,
	0x40000000u,
	0x50000000u,
	0x60000000u,
	0x70000000u,
	0x80000000u,
	0x90000000u,
	0xa0000000u,
	0xb0000000u,
	0xc0000000u,
	0xd0000000u,
	0xe0000000u,
	0xf0000000u,
	0x10000000u,
	0x11000000u,
	0x12000000u,
	0x14000000u,
	0x18000000u,
	0x1c000000u,
};

#define NCAND	(sizeof(candidates) / sizeof(candidates[0]))

/* 输出区结构 */
struct probe_out {
	uint32_t sig;		/* 'PRBE' */
	uint32_t count;		/* 已尝试的候选数 */
	uint32_t done;		/* 'PRBF' */
	uint32_t pad;
	struct {
		uint32_t base;
		uint32_t pattern;
		uint32_t marker;	/* 'PRTT' */
		uint32_t pad;
	} slot[NCAND];
};

#define SIG_PRBE	0x50424545u	/* "PRBE" */
#define SIG_DONE	0x50424645u	/* "PRBF" */
#define MARK_SLOT	0x50525454u	/* "PRTT" */

static struct probe_out *out;

/*
 * 极简的字符串比较辅助：把四个 ASCII 字节打包成 u32
 */
#define FOURCC(a, b, c, d) \
	(((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | \
	 ((uint32_t)(c) << 8) | (uint32_t)(d))

#define SIG_PRBE_CC	FOURCC('P', 'R', 'B', 'E')
#define SIG_DONE_CC	FOURCC('P', 'R', 'B', 'F')
#define MARK_SLOT_CC	FOURCC('P', 'R', 'T', 'T')

int main(void)
{
	uint32_t i;

	out = (struct probe_out *)(uintptr_t)DDR_OUT;
	out->sig = SIG_PRBE_CC;

	for (i = 0; i < NCAND; i++) {
		uint32_t base = candidates[i];
		uint32_t pattern = PATTERN_BASE | i;
		volatile uint32_t *reg;

		out->count = i;

		reg = (volatile uint32_t *)(uintptr_t)(base + REG_OFF_PROBE);

		/* 关键的一写：未映射时也很快返回 */
		*reg = pattern;

		/* 记录（说明这一写完成了） */
		out->slot[i].base = base;
		out->slot[i].pattern = pattern;
		out->slot[i].marker = MARK_SLOT_CC;
	}

	out->count = NCAND;
	out->done = SIG_DONE_CC;

	for (;;) {
		__asm__ volatile("wfi");
	}
	return 0;
}
