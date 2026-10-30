/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * s2isp 链接脚本 —— 链接在地址 0
 *
 * 固件被主机加载到 DDR 偏移 0，ISP CPU 从复位向量(地址 0)启动，
 * 与参考固件一致，因此可以用普通绝对寻址。
 */

ENTRY(_start)

MEMORY
{
	FW (rwx) : ORIGIN = 0x00000000, LENGTH = 8M
}

SECTIONS
{
	.text : {
		__vectors_start = .;
		KEEP(*(.text.vectors))
		*(.text)
		*(.text.*)
		. = ALIGN(4);
		__text_end = .;
	} > FW

	.rodata : {
		*(.rodata)
		*(.rodata.*)
		. = ALIGN(4);
	} > FW

	.data : {
		*(.data)
		*(.data.*)
		. = ALIGN(4);
		__data_end = .;
	} > FW

	__bss_start = .;
	.bss (NOLOAD) : {
		*(.bss)
		*(.bss.*)
		*(COMMON)
		. = ALIGN(4);
		__bss_end = .;
	} > FW

	/* 栈放在镜像末尾之后 */
	_stack (NOLOAD) : {
		. = ALIGN(8);
		. = . + 16K;
		_stack_top = .;
	} > FW

	/DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) *(.comment) }
}
