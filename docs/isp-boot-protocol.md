# S2 ISP 启动协议规格

主机与 ISP 固件之间的启动握手序列。**这是我们自己实现固件时必须复现的行为。**

来源：真机运行时观测（`dmesg`）+ 寄存器读写序列分析。
每一条都标注了观测来源。

---

## 0. 寄存器域

主机侧有两块 MMIO：

| 域 | BAR | 物理地址 | 大小 | 用途 |
|---|---|---|---|---|
| S2 IO | 0 | `0xb0900000` | 64 KB | DDR PHY、PCIe link、S2 块 |
| S2 MEM | 2 | `0x90000000` | 256 MB | DDR 窗口（固件、堆、IPC 队列都在这里） |
| ISP IO | 4 | `0xb0800000` | 1 MB | ISP 块寄存器、IPC 控制、中断 |

ISP 相关寄存器（ISP IO 域内偏移）：

| 偏移 | 名称 | 方向 | 用途 |
|---|---|---|---|
| `0x40004` | `ISP_REG_40004` | W | ISP 使能（写 1） |
| `0x40008` | `ISP_REG_40008` | W | 写 `0x80000000` |
| `0x41000` | `ISP_IRQ_STATUS` | R | 中断状态，bit 4..7 = 固件握手信号 |
| `0x41004` | `ISP_IRQ_ENABLE` | W | 中断使能 |
| `0x41020` | `ISP_REG_41020` | W | 写 `0x10` |
| `0x41024` | `ISP_IRQ_CLEAR` | W | 写回状态即清除 |
| `0xc3000` | `ISP_FW_CHAN_CTRL` | RW | **多义寄存器**，见下 |
| `0xc3004` | `ISP_FW_QUEUE_CTRL` | RW | IPC 队列基址 / 队列大小−1 |
| `0xc3008` | `ISP_FW_SIZE` | W | 固件长度 |
| `0xc300c` | `ISP_FW_HEAP_SIZE` | RW | 堆大小请求 / magic 握手 |
| `0xc3010` | `ISP_FW_HEAP_ADDR` | W | 堆基址 |
| `0xc3014` | `ISP_FW_HEAP_SIZE2` | W | 堆大小 |
| `0xc3018` | `ISP_REG_C3018` | W | 写 0 |
| `0xc301c` | `ISP_REG_C301C` | W | FW args 结构基址 |

**`0xc3000` 的多义性**（重要）：同一个寄存器在不同阶段含义不同 ——
阶段 1 写 0，阶段 2 读出通道数，阶段 4 读出通道描述表地址。

---

## 1. 内存布局（DDR 窗口内偏移）

**实测**（真机探针，DDR 根资源 `0x90000000`–`0x9fffffff`，256MB）：

```
主机 DDR 偏移      ISP CPU 地址     内容
0x00000000  ─────────────────  固件（8MB 预留区，实际镜像 1384KB）
0x00800000  ─────────────────  通道描述表（固件发布，位于固件区顶端）
0x00800000+ ─────────────────  IPC 队列（主机分配）
                固件堆（主机按固件请求分配，≤4MB）
```

关键结论：

- **固件被放在 DDR 偏移 0**，驱动强制校验 `firmware->base.start == mem->start`。
- **ISP CPU 与主机使用同一套 DDR 偏移编号**（通道表地址 `0x00800000` 主机直接用作
  `s2_mem + 0x800000` 读取，无需转换）。
- 固件链接在地址 0，向量表 `b 0x1620`（PC 相对）与绝对常量 `0x1620` 自洽。
- 固件访问 DDR 用物理基址 **`0x90000000`**（镜像内该常量出现 188 次）。
- `ISP_FW_HEAP_SIZE` 在阶段 1/3 被写为 `0x10000000 − 8MB`，即「256MB 减去固件
  预留区后剩余的空间」。

### 尚未确定

**ISP CPU 用什么地址访问 ISP BAR4 里的寄存器**（主机物理 `0xb0800000`）。
镜像里找不到 `0xb0800000` / `0xb0900000` 常量。可能性：
硬件固定映射 / 由引导结构传入 / 由固件头参数传入。
**这是 M1 要解决的第一问题。**

---

## 2. 握手五阶段

### 阶段 1 — 主机装载固件

```
写 ISP_FW_CHAN_CTRL  (0xc3000) = 0
写 ISP_FW_QUEUE_CTRL (0xc3004) = ipc_queue_base
写 ISP_FW_SIZE       (0xc3008) = firmware_size (对齐后)
写 ISP_FW_HEAP_SIZE  (0xc300c) = 0x10000000 - firmware_size
写 ISP_FW_HEAP_ADDR  (0xc3010) = 0
写 ISP_FW_HEAP_SIZE2 (0xc3014) = 0
```

然后轮询 `ISP_IRQ_STATUS (0x41000)`，等待 **bit 4..7 (mask `0xf0`)** 置位。
这是**第一次中断**，表示固件已启动。

> 观测：`ISP woke up after 0ms`

### 阶段 2 — 固件回报需求

```
读 ISP_FW_CHAN_CTRL  (0xc3000) = num_channels     (实测 7)
读 ISP_FW_QUEUE_CTRL (0xc3004) = queue_size - 1   (实测 44865)
读 ISP_FW_HEAP_SIZE  (0xc300c) = 固件请求的堆大小
```

堆大小必须 ≥ `0x1000`，且 ≤ `0x400000`（4MB），否则主机拒绝。

> 观测：`Number of IPC channels: 7, queue size: 44865`
> 观测：`Firmware requested heap size: 3072kb`

### 阶段 3 — 主机下发参数

```
写 ISP_FW_CHAN_CTRL  (0xc3000) = 0
写 ISP_FW_QUEUE_CTRL (0xc3004) = ipc_queue_base
写 ISP_FW_SIZE       (0xc3008) = 0x800000          (8MB)
写 ISP_FW_HEAP_SIZE  (0xc300c) = 0x10000000 - 0x800000
写 ISP_FW_HEAP_ADDR  (0xc3010) = heap_base
写 ISP_FW_HEAP_SIZE2 (0xc3014) = heap_size
写 ISP_REG_C301C     (0xc301c) = fw_args_base
写 ISP_REG_41020     (0x41020) = 0x10
```

`fw_args` 结构（12 字节）：

```c
struct isp_fw_args {
    u32 unknown;        // 观测值 2
    u32 fw_arg;         // 观测值 0
    u32 full_stats_mode;// 观测值 0
};
```

然后再次轮询 `ISP_IRQ_STATUS`，等待 **mask `0xf0`** 置位 —— **第二次中断**。

> 观测：`ISP second int after 0ms`

### 阶段 4 — 通道描述表

```
读 ISP_FW_CHAN_CTRL (0xc3000) = 通道描述表地址
```

> 观测：`Channel description table at 00800000`

通道表每项 **256 字节**（实测步长 `offset + i * 256`），
其中前 76 字节是有效内容：

```c
struct isp_channel_info {
    char name[64];   /* 通道名，NUL 结尾 */
    u32   type;
    u32   source;
    u32   size;
    /* 其余 180 字节未使用 */
};
```

实测 7 个通道名（来自驱动日志）：

```
terminal, io, debug, buf_h2t, buf_t2h, sharedmalloc, io_t2h
```

### 阶段 5 — magic value

```
写 ISP_FW_HEAP_SIZE (0xc300c) = 0x8042006
轮询 ISP_FW_HEAP_SIZE 直到读到 0
```

固件会把这个寄存器清零 —— 这就是「magic number 1 from ISPCPU」。

> 观测：`magic value: 00000000 after 0 ms`

完成后主机才使能中断（写 `ISP_IRQ_ENABLE`）。

---

## 3. 运行期 IPC 协议

### 命令头（8 字节，packed）

```c
struct isp_cmd_hdr {
    u32 unknown0;   /* 恒为 0 */
    u16 opcode;
    u16 status;
};
```

### Ring buffer 条目（64 字节）

| 偏移 | 字段 |
|---|---|
| `+0x00` | 地址 + 标志位 |
| `+0x04` | 请求长度 |
| `+0x08` | 响应长度 |

主机发命令的流程：分配一块命令内存 → 写入命令头 → 载荷跟在命令头之后 →
通过 `io` 通道的 ring buffer 投递 → 等待 `io` 通道就绪 → 从同一块内存读回响应。

### 命令 opcode

**opcode = 固件命令表项 id − 1**。完整 411 条见
[`isp-commands.md`](isp-commands.md)。

该映射规则已用固件自身运行时打印的 10 个 opcode 交叉验证（10/10 一致）。

---

## 4. 尚未确定的部分（M1 要解决的）

1. **ISP CPU 的寄存器基址** —— 固件用什么地址访问 `0xc3000` / `0x41000` 那些寄存器？
   MMU 是关的，所以是物理地址，但未找到对应的常量。
   可能由硬件固定映射，或通过某个引导结构传入。**← M1 首要问题**
2. **IPC 队列条目的确切格式** —— 主机侧是 64 字节，但固件侧写什么格式还没定。
3. **通道表的 `type` / `source` / `size` 语义**。
4. **固件如何产生第一次/第二次中断**（写 `ISP_IRQ_STATUS` 还是别的）。
5. **`0x8042006` 这个 magic 值的含义**。

这些正是 M1（最小固件）要逐个攻克的问题。

---

## 5. 复现方式

```bash
# 握手序列（真机）
sudo dmesg | grep -i facetimehd

# 内存布局（真机探针）
#   在 isp_mem_init() 中插入 pr_info，打印 root->start/end 与
#   firmware->offset / size_aligned，然后：
make -C /lib/modules/$(uname -r)/build M=$PWD modules
sudo modprobe -r facetimehd
sudo insmod ./facetimehd.ko
dmesg | grep PROBE
```

实测输出：

```
PROBE: DDR root start=0x90000000 end=0x9fffffff
PROBE: firmware offset=0x0 size_aligned=0x7fffff size=0x800000
```
