# SPDX-License-Identifier: GPL-2.0-only
#
# fw/Makefile — 自研 ISP 固件
#
# 目标：ARM 二进制，运行在 S2 芯片的 ISP 处理器上。
# 链接地址 0 —— 固件被加载到 DDR 偏移 0（实测确认）。
#

CROSS   ?= arm-none-eabi-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
SIZE    := $(CROSS)size

TARGET   := s2isp
SRC      := probe.S

# 位置无关：代码里所有本地符号用 adr 取，绝对地址只用于刻意探测
CFLAGS := -c -x assembler-with-cpp -march=armv7-a -marm \
          -ffreestanding -fno-pic -nostdlib -Wall -Wextra

LDFLAGS := -Ttext=0 -Tdata=0 -nostdlib -Wl,--build-id=none

.PHONY: all clean probe disasm

all: $(TARGET).bin

$(TARGET).elf: $(SRC)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<
	$(SIZE) $@

# ISP CPU 需要的是裸二进制
$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@

probe: $(TARGET).bin
	@echo "=== 固件大小 ==="
	@ls -l $(TARGET).bin
	@echo "=== 前 16 字节 ==="
	@$(OBJDUMP) -D -b binary -m arm $(TARGET).bin | head -20

disasm: $(TARGET).elf
	$(OBJDUMP) -d $<

clean:
	rm -f $(TARGET).elf $(TARGET).bin
