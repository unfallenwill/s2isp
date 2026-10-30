/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * s2isp probe firmware #6 — M1 阶段实验用
 *
 * 设计要点：
 *   - 每个候选只做 **一次** 读（base + 0x128，期望指纹 0xffffffff）。
 *     读之前先把标记写进输出区，因此即使这次读卡死/陷阱，
 *     也能从输出区看出「卡在哪个候选、哪个偏移」。
 *   - 候选表放在输出区之后，便于对照。
 *
 * 输出布局 (DDR 偏移 0x80000 起)：
 *   +0x0000  签名 "PRBC"
 *   +0x0004  已完成的候选数
 *   +0x0008  候选基址
 *   +0x000c  该候选的读值
 *   +0x0010  标记 "C<n>"（n 为候选序号，十六进制）
 *   ... 每个候选占 32 字节
 */

	.section .text.start, "ax"
	.arm
	.global _start

	.global _vectors
_vectors:
_start:
	b	reset_entry
	b	.
	b	.
	b	.
	b	data_abort
	b	.
	b	.
	b	.
	b	.
	b	.
	b	.
	b	.
	b	.
	b	.
	b	.
	b	.

reset_entry:
	.word 0xee010f30
	.word 0xf57ff06f
	.word 0xee110f10
	.word 0xe3c00c23
	.word 0xe3c00005
	.word 0xe3800002
	.word 0xee010f10
	.word 0xf57ff06f
	.word 0xe3a00000
	.word 0xee0c0f10
	.word 0xf57ff06f
	.word 0xe3a00000
	.word 0xee050f30
	.word 0xee050f10
	adr	sp, _stack_top

	ldr	r4, =0x00080000
	ldr	r0, =0x50524243		@ "PRBC" */
	str	r0, [r4, #0]

	adr	r7, cand_table
	mov	r8, #0
	ldr	r6, =0x00080008

cand_loop:
	ldr	r0, [r7, r8, lsl #2]
	cmp	r0, #0
	beq	cand_done

	/* 先写标记 'C' + 候选序号，再读 */
	str	r0, [r6, #0]		@ 基址 */
	movw	r2, #0x0043
	movt	r2, #0x5050		@ "PC" */
	orr	r2, r2, r8		@ 低字节塞索引 */
	str	r2, [r6, #8]

	/* 唯一一次读: base + 0x128 */
	movw	r1, #0x0128
	movt	r1, #0x0
	add	r1, r1, r0
	ldr	r2, [r1]
	str	r2, [r6, #4]		@ 读值 */

	/* 读完成 */
	ldr	r2, =0x50444154		@ "PDAT" */
	str	r2, [r6, #12]

	add	r6, r6, #32
	add	r8, r8, #1
	str	r8, [r4, #4]		@ 完成计数 */
	b	cand_loop

cand_done:
	ldr	r0, =0x50524244		@ "PRBD" */
	str	r0, [r4, #8]

halt:
	.word 0xe320f006
	b	halt

data_abort:
	ldr	r0, [sp, #0x1c]
	str	r0, [sp, #0x18]
	ldr	r1, [sp, #0x20]
	and	r1, r1, #0x1f
	orr	r1, r1, #0x13
	msr	spsr, r1
	movs	r0, #0x13
	msr	cpsr_c, r0
	ldr	pc, [sp, #0x18]

	.align 2
_stack:
	.space 512
_stack_top:

	.align 2
cand_table:
	.word 0xb0800000
	.word 0xb0900000
	.word 0x00000000
	.word 0x00040000
	.word 0x40000000
	.word 0x50000000
	.word 0x60000000
	.word 0x70000000
	.word 0x90000000
	.word 0xa0000000
	.word 0xb0000000
	.word 0xc0000000
	.word 0xd0000000
	.word 0xe0000000
	.word 0xf0000000
	.word 0x00000000
