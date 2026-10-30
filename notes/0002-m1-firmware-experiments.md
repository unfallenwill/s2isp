# 0002 — M1 实验记录：让自研 ARM 固件在 ISP CPU 上运行

日期：M1 阶段
目的：验证「自己写 ISP 固件」这条路是否可行（项目的分水岭）。

---

## 结论

**✅ 自研 ARM 固件能在 ISP CPU 上执行。** 这是 M1 闸门的核心证据。

我们的探针固件（`fw/probe.S`，约 900 字节）在加载后成功往 DDR 写了标记
（`PRB8` / `PRBA` / `PRBC` 等），证明：

1. ISP CPU 会执行我们自己的代码
2. 固件镜像必须以 **ARM 向量表**开头（偏移 0），否则 CPU 跳飞到垃圾地址
3. 固件可以**完全位置无关**地编写
4. 未映射读会返回**总线错误签名**（不同地址有不同签名），而不是恒定值
5. 未映射读有**长超时**，全地址空间盲扫不可行

---

## 实验装置

```
tools/recover-camera.sh     复位摄像头（关键，见下）
fw/probe.S                 自研探针固件
fw/Makefile                ARM 交叉编译，链接地址 0
tools/fw-analyze.py        参考固件分析器
```

观测通道：在**现有驱动**里加探针，把 DDR 与 ISP 寄存器窗口 dump 出来
（研究用补丁，不进交付物）。

---

## 踩过的坑

### 1. 向量表必须在镜像偏移 0

第一版固件把 `mrc p15,...` 放在偏移 0。CPU 复位时从 `[0]` 取分支指令，
拿到一个非分支指令 → 跳飞 → 固件根本没跑，表现和「固件写错地址」完全一样。

修正后与参考固件布局完全一致：

```
0x00  b reset_entry     ← 复位向量
0x04  b .              ← 其余 15 个异常向量
...
0x40  reset_entry:     ← 代码从这里开始
```

### 2. 异常处理程序的帧布局

ARMv7 异常帧：

| 偏移 | 内容 |
|---|---|
| +0x00..+0x10 | r0, r1, r2, r3, r12 |
| +0x14 | r14_irq |
| +0x18 | **r14_svc** |
| +0x1c | r15（故障指令地址 + 4） |
| +0x20 | CPSR |

返回序列（`eret` 读的是 ELR 寄存器而不是内存帧，改不了返回地址，
所以要用「切模式 + 从内存帧读 r14_svc」的方式）：

```asm
data_abort:
	ldr	r0, [sp, #0x1c]		@ frame r15
	str	r0, [sp, #0x18]		@ r14_svc <- 跳过故障指令
	ldr	r1, [sp, #0x20]
	and	r1, r1, #0x1f
	orr	r1, r1, #0x13		@ System 模式
	msr	spsr, r1
	movs	r0, #0x13
	msr	cpsr_c, r0			@ 切模式，CPSR 从 SPSR 恢复
	ldr	pc, [sp, #0x18]
```

### 3. 位置无关：用 `adr` 而不是 `ldr =`

`ldr rX, =symbol` 会生成绝对地址的常量池项 → 依赖加载基址。
必须用 `adr`（PC 相对，±4095）或 `add rX, pc, #imm`。

### 4. 观测地址不要用绝对常量

`ldr r4, =0x80000` 这种写法在不知道加载基址时不可靠。
用 `adr r4, _outbase` + 常量加法，保证「相对镜像偏移」语义。

---

## 最重要的发现：上游驱动缺少关停路径

反复热卸载/重载模块后，摄像头**彻底不可用**：

```
Init failed! No wake signal
```

关键点：

- **用 Apple 原厂固件也一样失败** → 不是我们的固件的问题，是硬件状态
- **S3 挂起/恢复不能修复**（设备保留内部状态）
- 唯一有效恢复：PCI 设备彻底移除再重新枚举

```bash
modprobe -r facetimehd
echo 1 > /sys/bus/pci/devices/0000:02:00.0/remove
echo 1 > /sys/bus/pci/rescan
```

原因：`fthd_hw_deinit()` 只往 `ISP_REG_41020` 写 0，不对 S2 芯片做电源周期。
ISP CPU 仍处于已启动状态，重新加载时不会从复位向量取指。

Apple 的 kext 有完整的 `DisableS2Chip` / `EnableS2Chip`（走 ACPI），Linux 驱动没有。

→ **这是我们驱动必须补上的硬性要求（M2）**，否则会踩同一个坑。

---

## 观测通道验证

用 Apple 固件 + 探针驱动，读回的 ISP 寄存器窗口与驱动写入的值一致：

```
+0xc3000 = 00000000   (驱动在阶段 3 写 0)
+0xc3004 = 00800000   (IPC 队列基址)
+0xc3008 = 00800000   (固件区大小 8MB)
+0xc300c = 00000000   (magic 值握手后被清零)
+0xc3010 = 0080b000   (堆基址)
+0xc3014 = 00300000   (堆大小 3MB)
+0xc301c = 00b0b000   (fw args)
```

**顺带得到**：IPC 队列在 DDR 偏移 `0x800000`（紧跟固件的 8MB 区），
堆在 `0x80b000`。这些是固件运行期会用到的常量。

---

## 待解决：ISP 寄存器的基址

已排除 `0xb0800000`（主机物理 BAR4）：读出的 `0x60463304` /
`0x6b04f843` 在**不同偏移重复出现**，是 PCIe 总线错误签名，不是真实数据。

限制：未映射读有长超时（目测单次可达数百毫秒），
按 4KB 步长盲扫整个地址空间不可行。

下一步方向：

1. **内容寻址** —— 从参考固件里定位它访问这些寄存器的指令序列，
   反推基址（参考固件里 `0x90000000` 出现 188 次，说明它用物理地址；
   寄存器基址很可能也以某种形式存在于代码或数据中）
2. **定向扫描** —— 用「读到的值不是错误签名」作判据，
   在可能的范围内做低偏移（同一页内）读
3. **硬件文档 / 专利 / 公开逆向** —— 搜索 S2 芯片的地址映射资料

---

## 复现

```bash
# 构建探针固件
cd fw && make

# 复位 + 加载我们的固件 + 观察
sudo tools/recover-camera.sh --fw fw/s2isp.bin
```

---

## 0003 — ACPI 电源周期：找到了，但它单独不够用

### DSDT 里的电源序列

反编译 DSDT 找到（`iasl -d`）：

```c
Name (S2PM, 0x02)
Method (CMPE, 1, Serialized)
{
    If (Arg0 == 0x01) {         /* 断电 */
        GD45 = 0x01;
        \_SB.PCI0.RP02.ASPM = S2PM;      /* 2 */
        \_SB.PCI0.RP02.PSTA = 0x00;
        While (\_SB.PCI0.RP02.PSTA != 0x00) { Sleep (0x01); }
        ... 等待 LACT == 1 ...
        L23D = 0x01;                    /* 切断 L2/L3 链路 */
        LEDM = 0x00;
    } Else {                      /* 上电 */
        \_SB.PCI0.RP02.CMRA.DPST = 0x03;
        While (DPST != 0x03) { Sleep (0x01); }
        If (SLTP == 0x00) { L23E = 0x01; LEDM = 0x01; }
        \_SB.PCI0.RP02.PSTA = 0x03;
        While (PSTA != 0x03) { Sleep (0x01); }
        S2PM = \_SB.PCI0.RP02.ASPM;
        \_SB.PCI0.RP02.ASPM = 0x00;
        GP45 = 0x00; GD45 = 0x00;
    }
}
```

路径 `\_SB.PCI0.RP02.CMRA.CMPE`。与 Apple kext 的
`AppleCamIn::acpiControlS2ChipPower()` 同一条路径。

已实现为 `driver/s2power.c`（`acpi_execute_simple_method` 调用 CMPE）。

### 但单独用它不够

执行 CMPE(1) → CMPE(0) 之后：

- PCIe 链路断开，**设备从总线消失**
- 重新枚举（`/sys/bus/pci/rescan`、根端口 remove+rescan）**都救不回来**
- 只有整机重启才能恢复

原因：Apple 在睡眠/唤醒时用这条路径，是因为**同时会重初始化整条 PCIe 链路**；
Linux 侧没有这个配套动作。

⇒ **结论：我们的驱动不能单独做 ACPI 电源周期。**
真正的解法是找到 **ISP CPU 自身的复位寄存器**——而那又需要先知道寄存器基址（循环依赖）。

⇒ **打破循环的办法**：用**写**代替**读**做定位（见 0004）。

### 实验纪律

由于 ISP CPU 无法在不重启的情况下复位，**每次实验之间需要整机重启**。
`tools/exp-next.sh` 把一轮实验打包成一条命令，便于重启后立刻执行。
