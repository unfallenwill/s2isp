# 0001 — ISP 固件架构侦察

日期：M0 阶段
目的：确定「自己写固件」是否可行，以及摸清启动协议。

所有结论都附了复现命令。**不确定的地方明确标注为「待验证」。**

---

## 结论摘要

| # | 结论 | 置信度 |
|---|---|---|
| 1 | ISP 固件是 **ARMv7** 代码，不是私有 ISA | 高（反汇编确证） |
| 2 | 由 **clang** 编译，版本 `S2ISP-01.57.00` | 高（镜像内元数据） |
| 3 | 与 **iOS 7.0.3** 同源（`iPhone OS / 7.0.3`） | 高（镜像内元数据） |
| 4 | 芯片代号 **H4**（`H4ISPAPPLE` / `H4ISPCD`） | 高 |
| 5 | **MMU 关闭** → 固件用物理地址 | 高（启动代码清 SCTLR.V） |
| 6 | 命令表 411 项，**opcode = id − 1** | 高（10/10 运行时交叉验证） |
| 7 | 启动握手共 5 阶段，可完整复现 | 高（寄存器序列 + 日志） |
| 8 | **固件链接在地址 0，从 DDR 偏移 0 启动**，ISP CPU 与主机共用 DDR 偏移编号 | 高（真机探针实测） |
| 9 | ISP 处理很可能是**定功能硬件 + 固件下发系数** | 中（命令集形态推断，**待验证**） |

---

## 1. 固件镜像结构

```
0x00000  ARM 向量表
         +0x00  b 0x1620        ← 复位入口
         +0x04  b .  × 7        ← 未实现的异常向量
0x00040  "FFW Application"
0x00050  "See next page for information"
0x01000  构建元数据块
0x01010  "Copyright (c) APPLE Inc. All Rights Reserved."
0x01060  "Feb 15 2017" / "12:17:55"
0x01080  "S2ISP-01.57.00"
0x01090  "H4ISPAPPLE" / "H4ISPCD" / "ffw"
0x010d0  "iPhone OS" / "7.0.3"
0x010f0  "clang/clang++"
0x01620  ARM 启动代码
0x02xxx  代码段
0xa4xxx  字符串段（411 个 CISP 命令名 + 其它）
0xb22f0  命令名表 {u32 name_ptr, u32 id} × 411
```

复现：

```bash
python3 tools/fw-analyze.py buildinfo .cache/firmware.bin
python3 tools/fw-analyze.py vectors  .cache/firmware.bin
```

---

## 2. ARM 启动序列

复位向量 `b 0x1620`，目标处：

```asm
1620:  mcr  15,0,r0,cr1,cr0,{1}    ; 失效 I-cache
1624:  isb  sy
162c:  mcr  15,0,r0,cr1,cr0,{0}    ; 读 SCTLR
1630:  bic  r0,r0,#0x2300          ; 清对齐控制位
1634:  bic  r0,r0,#5               ; 清 V  → MMU 关闭
1638:  orr  r0,r0,#2               ; 置 A
163c:  mcr  15,0,r0,cr1,cr0,{0}    ; 写回
1658:  mcr  15,0,r0,cr12,cr0,{0}   ; CP 访问控制
1664:  mcr  15,0,r0,cr5,cr0,{1}    ; 失效 TLB
166c:  ldr  sp,[pc,#28]             ; 栈指针
1680:  bx   r2                     ; 跳入主流程
```

**「MMU 关闭」是重要结论**：ISP CPU 直接使用物理地址，
这解释了为什么固件里找不到 Windows/Linux 那种分页地址转换逻辑，
也说明固件与硬件的地址映射是固定的。

---

## 3. 命令表与 opcode

### 表位置与结构

```
0x0b22f0: 411 项，每项 8 字节 { u32 name_ptr, u32 id }
```

按 `id` 升序排列，`id` 的取值呈分组结构（`0x1xx` / `0x2xx` / `0x3xx` ...）。

### opcode 规则

**线协议 opcode = `id` − 1。**

推导依据：固件自己的调试输出会打印收到的 opcode 与命令名，例如
`FWMSG: [ISP] CH = 0 CMD = 0x0106 [CISP_CMD_CH_CAMERA_CONFIG_GET]`。
而表中 `CISP_CMD_CH_CAMERA_CONFIG_GET` 的 `id = 0x107`。

### 交叉验证（10/10）

`tools/fw-analyze.py` 内置了 10 条从真机 `dmesg` 抓到的固件自报 opcode，
提取时自动比对，全部一致：

```
CISP_CMD_STOP                     0x0001
CISP_CMD_CONFIG_GET               0x0003
CISP_CMD_PRINT_ENABLE             0x0004
CISP_CMD_CH_START                 0x0100
CISP_CMD_CH_STOP                  0x0101
CISP_CMD_CH_BUFFER_RETURN         0x0104
CISP_CMD_CH_CAMERA_CONFIG_GET     0x0106
CISP_CMD_CH_CAMERA_CONFIG_SELECT  0x0107
CISP_CMD_CH_INFO_GET              0x010d
CISP_CMD_CH_BUFFER_RECYCLE_MODE_SET 0x010e
```

### 与社区驱动的差异（附带发现）

把提取结果与社区驱动的枚举逐条比对：**383/410 一致（93.4%）**。
26 处不一致**全部落在命令组边界**，且集中在社区驱动不常用、
或因其「不等待响应」而无法暴露错误的命令上。

例：社区驱动 `CISP_CMD_POWER_DOWN = 0xa`，而固件表中该命令 `id = 0x100`
→ 真实 opcode `0xff`。社区驱动发的是 `0xa`，恰好落在 `TIMEPROFILE_SHOW` 的
有效区间；由于 `POWER_DOWN` 不等响应，这个错误一直不可见。

> **对本项目的意义**：我们从固件的命令表直接推导 opcode，
> 可以比社区驱动**更正确**。这是「不依赖第三方代码」带来的直接收益。

---

## 4. 启动握手

完整规格见 [`../docs/isp-boot-protocol.md`](../docs/isp-boot-protocol.md)。

真机观测日志：

```
Loaded firmware, size: 1384kb
ISP woke up after 0ms
Number of IPC channels: 7, queue size: 44865
Firmware requested heap size: 3072kb
ISP second int after 0ms
Channel description table at 00800000
magic value: 00000000 after 0 ms
Enabling interrupts
```

---

## 5. 命令集形态 → 关于 A2 假设

411 条命令里大量是「下发系数 / 矩阵 / 权重」类型：

```
CISP_CMD_APPLE_CH_AWB_2D_CCM_SET
CISP_CMD_APPLE_CH_AFFILTER_COEFF_SET
CISP_CMD_APPLE_CH_AFHORZFILT_COEFF_SET
CISP_CMD_APPLE_CH_AE_PSEUDO_Y_WEIGHT_SET
CISP_CMD_APPLE_CH_AWB_HISTOGRAM_WEIGHT_SET
CISP_CMD_APPLE_CH_AWB_X_TO_CCT_LUT_SET
```

**推断**：像素级运算在 S2 的定功能硬件里，固件只负责下发参数与调度。

**这条假设决定了整个项目的工程量级别**：

- 若成立 → 我们只需写「配置 + 调度」固件，工作量以月计
- 若不成立 → 需要复刻整套 ISP 算法，工作量以年计

M1/M3 的实验设计都以验证这条假设为目的。
**目前仅有命令集形态这一个间接证据，不足以定论。**

---

## 6. 待解决问题（M1 的输入）

1. **ISP CPU 的寄存器基址**。已知 MMU 关闭，但固件里找不到 `0xb0800000`
   之类的物理基址常量。可能性：
   - 硬件固定映射（ISP CPU 有自己的地址视图）
   - 通过某个引导结构传入
   - 通过固件头/参数块传入

   → **M1 第一步要解决的就是这个。**

2. IPC 队列条目的确切格式（主机侧 64 字节已知）。
3. 通道表 `type` / `source` / `size` 的语义。
4. 固件如何触发第一次/第二次中断。
5. `0x8042006` magic 值的含义。

---

## 7. 真机探针：内存布局（已实测）

在 `isp_mem_init()` 里插探针重新编译加载，得到：

```
PROBE: DDR root start=0x90000000 end=0x9fffffff
PROBE: firmware offset=0x0 size_aligned=0x7fffff size=0x800000
```

结论：

- DDR 根资源 = BAR2 物理 `0x90000000`，256MB
- **固件被放在 DDR 偏移 0**（驱动强制 `firmware->base.start == mem->start`）
- **通道表地址 `0x00800000` 是 DDR 偏移**，主机直接用 `s2_mem + 0x800000` 读，
  → **ISP CPU 与主机共用同一套 DDR 偏移编号**，无需转换
- `0x00800000` 恰好是固件 8MB 预留区的顶端 → 固件把自己的通道表放在自己
  内存区的顶部
- 固件镜像里 `0x90000000` 出现 188 次 → 固件确实用物理地址访问 DDR

### 探针方法

```bash
# 在 isp_mem_init() 里加 pr_info
make -C /lib/modules/$(uname -r)/build M=$PWD modules
sudo modprobe -r facetimehd
# 注意: 卸载 facetimehd 会连带卸掉 videobuf2，insmod 前要手动补回
sudo modprobe videobuf2_common videobuf2_memops videobuf2_v4l2 videobuf2_dma_sg videodev
sudo insmod ./facetimehd.ko
dmesg | grep PROBE
```

坑：直接 `insmod` 会报 `Unknown symbol vb2_fop_mmap`，
因为 `modprobe -r` 把 videobuf2 一起卸了，而 insmod 不会自动加载依赖。

---

## 8. 复现方式

```bash
tools/fetch-reference-firmware.sh        # 取参考固件到 .cache/（不入库）
python3 tools/fw-analyze.py commands .cache/firmware.bin --json .cache/commands.json
python3 tools/fw-analyze.py buildinfo .cache/firmware.bin
python3 tools/fw-analyze.py vectors  .cache/firmware.bin
tools/check.sh m0
```
