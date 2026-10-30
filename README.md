# s2isp

**从零实现 Broadcom S2 ISP 的固件与主机驱动 —— 不依赖任何第三方二进制或代码。**

目标：让 2011–2017 年的 Apple Mac 内置 FaceTime HD 摄像头（PCI `14e4:1570`）
在一套**完全自主**的 Linux 驱动上工作，不使用 Apple 的 ISP 固件，
不使用社区的逆向驱动代码。

---

## 为什么这是个真问题

这块摄像头不是普通 USB 摄像头。它是 Broadcom 的 **S2** ISP 芯片，走 PCIe，
核心固件跑在芯片自带的 **ARM** 处理器上。没有那块固件，芯片不会出图。

当前生态的现状：

| 组件 | 来源 | 问题 |
|---|---|---|
| ISP 固件 | Apple 的 `AppleCameraInterface.kext` 里的一段 gzip 流 | Apple 专有二进制 |
| 传感器标定 | Apple 的 `AppleCameraAssistant.kext` | Apple 专有二进制 |
| 主机驱动 | [patjak/facetimehd](https://github.com/patjak/facetimehd)（GPLv2） | 他人逆向成果 |

**本项目要把这三样全部自己做出来。**

---

## 可行性评估

结论先给：**技术上可行，工程量以「月」计而非「周」计。**
下面是支撑这个判断的关键发现，以及分阶段计划。

### 关键发现

**1. ISP 固件是 ARM 代码，不是私有 ISA。**

从固件镜像头部提取到的构建元数据：

```
Copyright (c) APPLE Inc. All Rights Reserved.
Feb 15 2017
S2ISP-01.57.00
H4ISPAPPLE
H4ISPCD
ffw
iPhone OS / 7.0.3
clang/clang++
```

入口处是标准 ARMv7 启动序列（`mcr p15, ... cr1/cr5/cr12`，配 `isb sy`）：

```asm
1620:  mcr  15,0,r0,cr1,cr0,{1}    ; 失效 I-cache
1630:  bic  r0,r0,#0x2300          ; 清 SCTLR 对齐位
1658:  mcr  15,0,r0,cr12,cr0,{0}   ; CP 访问控制
1664:  mcr  15,0,r0,cr5,cr0,{1}    ; 失效 TLB
166c:  ldr  sp,[pc,#28]             ; 栈指针
1680:  bx   r2                     ; 跳 main
```

→ 意味着我们可以用 `arm-none-eabi-gcc` 写自己的固件，用 `objdump -m arm`
反汇编研究 Apple 那份。**指令集不是障碍。**

**2. ISP 很可能主要是「定功能硬件块 + 固件下发系数」。**

固件里实现了 **410 条 CISP 命令**，其中大量是这类：

```
CISP_CMD_APPLE_CH_AWB_2D_CCM_SET
CISP_CMD_APPLE_CH_AFFILTER_COEFF_SET
CISP_CMD_APPLE_CH_AFHORZFILT_COEFF_SET
CISP_CMD_APPLE_CH_AE_PSEUDO_Y_WEIGHT_SET
CISP_CMD_APPLE_CH_AWB_HISTOGRAM_WEIGHT_SET
```

全是「把系数写进去」，而不是「在这里做像素运算」。
→ 像素级处理很可能在 S2 的固定功能硬件里，固件只负责配置。
→ 这大幅降低了「自己实现完整 ISP 算法」的难度。

**3. 主机侧很多硬件初始化本来就由驱动完成，不是固件。**

例如 DDR PHY 的 VDL 标定（`one_shmoo_RE_FIFO`）、PLL 配置、PCIe link 建立
——这些都是主机驱动做的。固件只在这些完成之后才被加载。

→ 驱动侧的硬件 bring-up 可以用**真机黑盒实验**重新推导，不需要参考 Apple 的代码。

**4. 有真机。**

整个项目可以在真实的 S2 芯片上迭代验证，不需要仿真器。

### 难点（诚实列出）

| 难点 | 规模 | 说明 |
|---|---|---|
| S2 ISP 硬件块寄存器语义 | **最大** | 完全无文档，只能从 Apple 固件的读写序列反推 |
| IPC 协议 | 中 | 主机侧可观测，但通道描述表、共享内存请求等格式需逆向 |
| DDR PHY 标定算法 | 中 | 纯硬件标定，可在真机上用搜索算法重新推导 |
| 传感器 I2C 驱动 | 小 | 1871/1874/1675 等型号，MIPI CSI-2 寄存器标准较通用 |
| 图像处理（若需主机侧兜底） | 中 | demosaic / AWB / gamma 可用 libyuv / OpenCV 实现 |

---

## 分阶段计划

每个阶段都有**可验证的产出**，而不是「做完才知道对不对」。

| 阶段 | 产出 | 验证方式 |
|---|---|---|
| **M0** 工具链 | ARM 交叉编译器 + 固件分析工具（反汇编/符号恢复/调用图） | 能完整反汇编 Apple 固件并建立索引 |
| **M1** ★ 最小固件 | 自研 ARM 固件：启动 → 报告 1 个 IPC 通道 → 响应 ping | **决定性验证**：能被主机加载并握手成功 |
| **M2** 主机驱动 | 我们自己的 PCIe/DDR/IPC/V4L2 驱动，能加载 M1 的固件 | 加载自研固件成功 |
| **M3** 裸帧 | I2C 配传感器 + 采集 RAW Bayer 帧 | 拿到有内容的原始帧 |
| **M4** 成像 | 主机侧 demosaic + AWB + gamma → YUV | 输出可看的图像 |
| **M5** 完整 | V4L2 管线、控制接口、格式协商、性能调优 | 与现有驱动的画质/帧率对标 |

**M1 是整个项目的分水岭。** 如果自研固件能让主机驱动完成握手，
后面就是常规工程；如果不行，说明 S2 的启动协议有我们没看到的硬件依赖，
需要回头重新评估。

---

## 目录

```
docs/       设计文档、协议规格、逆向笔记
fw/         自研 ISP 固件（ARM）
driver/     自研主机驱动
tools/      分析与构建工具
notes/      原始实验记录
```

---

## 与既有工作的关系

- 现有可用的驱动：[patjak/facetimehd](https://github.com/patjak/facetimehd)（GPLv2）
- 本仓库**不复制其代码**。所有实现从零编写。
- 本仓库会记录**观测到的硬件行为**（寄存器读写序列、协议格式），
  这是从硬件本身得到的知识，与任何人的源代码无关。
- 协议与硬件语义的规格化描述放在 `docs/`，可独立阅读。

## 许可

GPL-2.0-only
