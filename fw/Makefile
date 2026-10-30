# SPDX-License-Identifier: GPL-2.0-only
#
# fw/Makefile — 自研 ISP 固件
#
# 目标: ARM 二进制，运行在 S2 芯片的 ISP 处理器上。
# 链接地址 0 —— 固件被加载到 DDR 偏移 0（实测确认）。
#

CROSS   ?= arm-none-eabi-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
SIZE    := $(CROSS)size

TARGET   := s2isp
SRCS     := start.S main.c

CFLAGS := -O2 -march=armv7-a -marm \
          -ffreestanding -fno-builtin -fno-stack-protector \
          -fno-pic -nostdlib -Wall -Wextra \
          -fno-asynchronous-unwind-tables

LDFLAGS := -T s2isp.ld -nostdlib -Wl,--build-id=none -Wl,-z,noexecstack

.PHONY: all clean probe disasm size

all: $(TARGET).bin

$(TARGET).elf: $(SRCS) s2isp.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS)
	$(SIZE) $@

# ISP CPU 需要的是裸二进制
$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@

probe: $(TARGET).bin
	@echo "=== 固件大小 ==="
	@ls -l $(TARGET).bin
	@echo "=== 向量表 ==="
	@$(OBJDUMP) -D -b binary -m arm $(TARGET).bin | head -12

disasm: $(TARGET).elf
	$(OBJDUMP) -d $<

size: $(TARGET).elf
	$(SIZE) -A $<

clean:
	rm -f $(TARGET).elf $(TARGET).bin
