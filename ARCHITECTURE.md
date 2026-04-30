# GEMM 架构说明（脉动阵列方案）

本文档给出可直接指导 RTL 的 GEMM 架构定义，满足：
- 计算：`D = A × B + C`
- 数据类型：FP16（可选 FP32 累加）
- 接口：AXI4（配置用 AXI4-Lite，数据搬运用 AXI4）
- 目标：1 TOPS（理论峰值）

---

## 1. 顶层架构与数据通路

### 1.1 简单架构框图

```text
                    AXI4-Lite Slave (CSR)
CPU/Host  ----------------------------------------------+
                                                         |
                                                         v
                                                 +---------------+
                                                 |  CSR / IRQ    |
                                                 +-------+-------+
                                                         |
                                                         v
+-----------------------+      +----------------+   +----+-------------------+
| AXI4 Master (Read)    | ---> | Read DMA       |-->| Scheduler / Tile Ctrl |
| A/B/C from DDR/HBM    |      | (AddrGen+Burst)|   | (m/n/k loops, pingpong)|
+-----------------------+      +-------+--------+   +----+-------------------+
                                        |                 | 
                                        v                 |
                         +-----------------------------+   |
                         | On-chip Buffers             |<--+
                         | A_BUF[2], B_BUF[2], C_BUF   |
                         | optional ACC_BUF (banked)   |
                         +---------------+-------------+
                                         |
                                         v
                           +----------------------------+
                           | Systolic Array PE[P_M][P_N]|
                           | A: left->right             |
                           | B: up->down                |
                           +---------------+------------+
                                           |
                                           v
                              +--------------------------+
                              | PostProcess ( +C / cast )|
                              +-------------+------------+
                                            |
                                            v
                           +----------------+----------------+
                           | Write DMA (D tile burst writeback)|
                           +----------------+----------------+
                                            |
                                            v
                                    AXI4 Master (Write)
```

### 1.2 模块边界（必须拆分）

1. `csr_if`：寄存器读写、start/done/irq、错误码
2. `tile_scheduler`：三重循环、边界 mask、双缓冲切换
3. `dma_rd` / `dma_wr`：AXI burst + stride 地址生成
4. `buffer_bank`：A/B/C/ACC 缓冲管理与端口仲裁
5. `systolic_core`：`P_M x P_N` PE 阵列 + 局部累加
6. `postproc`：`acc + C`、舍入/饱和、写回格式化

---

## 2. 精确定义：寄存器与控制

## 2.1 CSR 建议映射（最小可用集合）

- `0x000 CTRL`
  - bit0 `start`（W1P）
  - bit1 `soft_reset`
  - bit2 `irq_en`
- `0x004 STATUS`
  - bit0 `busy`
  - bit1 `done`（W1C）
  - bit2 `err`
- `0x008 ERR_CODE`
  - `1` 地址未对齐，`2` 越界，`3` 非法维度，`4` 内部超时
- `0x010/014/018 DIM_M/N/K`
- `0x020~0x02C ADDR_A/B/C/D`（64bit 平台可拆高低位）
- `0x030~0x03C STRIDE_A/B/C/D`（Bytes）
- `0x040/044/048 TILE_M/N/K`
- `0x04C ARRAY_CFG`：`PE_M`、`PE_N`（只读）
- `0x050~0x06C PERF_COUNTER`（cycle、stall、rd/wr bytes）

## 2.2 调度状态机（建议）

`IDLE -> LOAD_AB/C -> COMPUTE -> STORE_D -> NEXT_TILE -> DONE`

- `LOAD_AB/C`：准备本轮 `k0` 分块输入
- `COMPUTE`：阵列执行并产生部分和
- `STORE_D`：`k0` 全部结束后写回
- `NEXT_TILE`：更新 `(m0,n0)` 与边界 mask

---

## 3. Tile 与数据流（可直接映射 RTL）

## 3.1 三重循环

```text
for m0 in [0, M) step Tm
  for n0 in [0, N) step Tn
    acc_tile = 0
    preload C_tile (optional)
    for k0 in [0, K) step Tk
      load A_tile(Tm,Tk), B_tile(Tk,Tn)
      systolic_compute(Tk cycles + fill/drain)
      acc_tile += A_tile * B_tile
    D_tile = acc_tile + C_tile
    writeback D_tile
```

## 3.2 脉动阵列喂数规则

- 每拍向阵列左边注入一列 A（或一组向量），向顶部注入一行 B
- PE 运算：`acc(i,j) += a(i,k) * b(k,j)`
- 阵列总时延（单 `k0`）：
  - `Tk`（有效 MAC）
  - `+ (P_M-1 + P_N-1)`（灌排空）

## 3.3 双缓冲重叠

- Ping 在算时，Pong 预取下一 `k0`
- 重叠目标：`T_load <= T_compute`，否则 DMA 成瓶颈

---

## 4. 参数与性能收敛方法

## 4.1 峰值公式

\[
TOPS_{peak} = 2 \times (P_M \times P_N) \times f
\]

> 例：`P_M×P_N=512`、`f=1GHz` => `1.024 TOPS`（理论值）

## 4.2 带宽估算（每个 `D_tile`）

- 读：`A(Tm×K)` + `B(K×Tn)` + `C(Tm×Tn)`
- 写：`D(Tm×Tn)`
- FP16 每元素 2B

近似字节量：

\[
BW_{tile} \approx 2\cdot(TmK + KTn + 2TmTn)
\]

用该式与总线峰值比较，确定 `Tk`、burst 长度和 bank 数。

---

## 5. 数值路径与模式

- 默认推荐：`FP16 mul + FP32 accumulate + FP16 output`
- 可选低成本模式：`FP16 mul + FP16 accumulate`
- `postproc` 统一处理：round-to-nearest-even（建议）、溢出饱和

---

## 6. 可验证性与可观测性

必须暴露以下计数器：
- `cycle_total`
- `cycle_compute`
- `cycle_dma_wait`
- `axi_rd_bytes`, `axi_wr_bytes`
- `irq_count`, `err_count`

最小验证集：
1. `M/N/K = 1`、非整 tile、stride 非连续
2. 与软件参考模型逐元素比对（允许 ULP 阈值）
3. 验证重叠：统计 `compute` 与 `dma` 并行周期

---

## 7. RTL 实现顺序（强约束）

1. **MVP**：单 tile、无双缓冲、可正确写回
2. **完整循环**：支持任意 `M/N/K` + 边界 mask
3. **性能版**：A/B 双缓冲 + burst 优化
4. **工程化**：错误处理、计数器、中断、回归脚本

