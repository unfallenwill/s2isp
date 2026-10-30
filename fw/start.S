/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * s2isp 启动代码（ARM）
 *
 * 链接在地址 0 —— 固件被加载到 DDR 偏移 0，由 ISP CPU 从复位向量启动。
 * 这是实测确认的事实（见 notes/0002）。
 *
 * 职责：
 *   1. 提供 ARM 复位向量表（必须在镜像偏移 0）
 *   2. 关掉 MMU（ISP CPU 以物理地址访问）
 *   3. 建立栈、清零 .bss（主机只拷贝 .text/.data，.bss 不会被初始化）
 *   4. 调用 main()
 */

	.section .text.vectors, "ax"
	.arm
	.align 5
	.global __vectors_start
	.global _start
__vectors_start:
_start:
	b	reset_entry		/* 0x00 复位向量 */
	b	.			/* 0x04 未定义指令 */
	b	.			/* 0x08 SWI */
	b	.			/* 0x0c 预取异常 */
	b	hang			/* 0x10 数据访问异常 */
	b	.			/* 0x14 保留 */
	b	.			/* 0x18 保留 */
	b	.			/* 0x1c 保留 */
	b	hang			/* 0x20 IRQ */
	b	hang			/* 0x24 FIQ */
	b	.			/* 0x28 保留 */
	b	.			/* 0x2c 保留 */
	b	.			/* 0x30 保留 */
	b	.			/* 0x34 保留 */
	b	.			/* 0x38 保留 */
	b	.			/* 0x3c 保留 */
	.global __vectors_end
__vectors_end:

	.section .text
	.arm
	.align 2
	.global reset_entry
reset_entry:
	/* ---- 关 MMU ---- */
	.word	0xee110f10		/* mrc p15,0,r0,cr1,cr0,{0}  读 SCTLR */
	.word	0xe3c00005		/* bic r0,r0,#5        清 V -> MMU 关 */
	.word	0xe3c00c23		/* bic r0,r0,#0x2300   清对齐位 */
	.word	0xee010f10		/* mcr p15,0,r0,cr1,cr0,{0}  写回 */
	.word	0xf57ff06f		/* isb sy */

	/* ---- 关 CP/FP 访问（与参考固件一致） ---- */
	mov	r0, #0
	.word	0xee0c0f10		/* mcr p15,0,r0,cr12,cr0,{0} */
	.word	0xf57ff06f		/* isb sy */

	/* ---- 失效 TLB ---- */
	.word	0xee050f30		/* mcr p15,0,r0,cr5,cr0,{1} */
	.word	0xee050f10		/* mcr p15,0,r0,cr5,cr0,{0} */
	.word	0xf57ff06f		/* isb sy */

	/* ---- 栈 ---- */
	ldr	sp, =_stack_top

	/* ---- 清零 .bss ---- */
	ldr	r0, =__bss_start
	ldr	r1, =__bss_end
1:	cmp	r0, r1
	bhs	2f
	str	r2, [r0], #4
	b	1b
2:

	/* ---- 进 C ---- */
	bl	main

	/* ---- 不该到这里 ---- */
hang:
	.word	0xe320f006		/* wfi */
	b	hang
