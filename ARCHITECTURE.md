# 基于脉动阵列机的 GEMM 整体架构规划

本文档基于 `README.md` 的设计要求（FP16、AXI4 接口、1 TOPS 理论峰值目标），给出采用脉动阵列（Systolic Array）实现方案时的 GEMM 顶层架构规划。

---

## 1. 总体方案

采用 **Tile 化 + 脉动阵列 + 双缓冲流水** 的实现思路，完成：

\[
D = A \times B + C
\]

三层架构如下：

1. **系统层**：CSR + 调度器 + DMA/AXI
2. **存储层**：A/B/C/D 片上 Buffer（Bank 化 + Ping-Pong）
3. **计算层**：二维脉动阵列 `PE[P_M][P_N]`（FP16 乘加，支持扩展 FP32 累加）

核心策略：
- 外存按 Tile 搬运，提升突发传输效率；
- `A` 沿阵列行方向传播，`B` 沿阵列列方向传播；
- PE 本地累加 `K` 维部分和；
- 计算当前 Tile 时并行预取下一 Tile（双缓冲隐藏访存时延）。

---

## 2. 顶层模块划分

### 2.1 CSR/寄存器模块（AXI4-Lite Slave）

建议寄存器：
- `CTRL`：`start` / `soft_reset` / `irq_en`
- `STATUS`：`busy` / `done` / `err_code`
- `DIM_M` / `DIM_N` / `DIM_K`
- `ADDR_A` / `ADDR_B` / `ADDR_C` / `ADDR_D`
- `STRIDE_A` / `STRIDE_B` / `STRIDE_C` / `STRIDE_D`（字节）
- `TILE_M` / `TILE_N` / `TILE_K`
- `PE_M` / `PE_N`（可只读，映射硬件参数）
- 性能计数器：`cycle_total` / `dma_bytes` / `stall_cycle`

### 2.2 调度器（Scheduler）

职责：
- 管理三重 Tile 循环：
  - `for m0 in 0..M step Tm`
  - `for n0 in 0..N step Tn`
  - `for k0 in 0..K step Tk`
- 驱动 DMA 读写、Buffer 切换、Compute 启停；
- 处理边界 Tile（不足 `Tm/Tn/Tk`）的 mask；
- 统一异常、超时、中断状态回传。

### 2.3 DMA 子系统

- **读 DMA**：负责 A/B/C 搬运，支持 AXI4 INCR burst + stride；
- **写 DMA**：负责 D 写回，支持 burst 聚合；
- 地址发生器：按 Tile 索引与 stride 生成地址；
- 安全检查：地址对齐、越界、参数合法性检查。

### 2.4 片上存储（On-chip Buffer）

- `A_BUF[2]`、`B_BUF[2]`：双缓冲（Ping/Pong）
- `C_BUF`：可选（若采用回写前融合 C）
- `ACC_BUF`：可选（多段 K 分块时保存中间部分和）

设计原则：
- Bank 化降低冲突；
- Buffer 位宽与阵列并行度匹配；
- 对齐 AXI 总线宽度提升有效载荷占比。

### 2.5 脉动阵列计算核心（Compute Core）

- 阵列规模：`P_M x P_N` 参数化；
- 数据流方向：
  - `A`：左 -> 右
  - `B`：上 -> 下
- 每个 PE：
  - `acc += a_in * b_in`
  - 同步转发 `a_out` 与 `b_out`
- `K` 轮后得到局部结果，与 `C` 融合形成 `D`。

---

## 3. 数据流与时序规划

针对单个输出 `D_tile(Tm x Tn)`：

1. 预取 `C_tile`（如启用 `+C` 融合）；
2. 遍历 `k0` 分块：
   - 读 `A_tile(Tm x Tk)` 与 `B_tile(Tk x Tn)`；
   - 脉动阵列运行 `Tk` 周期（外加灌排空延迟）；
   - 局部和保存在 PE 累加寄存器或 `ACC_BUF`；
3. 所有 `k0` 完成后执行 `D_tile = Acc + C_tile`；
4. DMA 突发写回 `D_tile`。

流水重叠建议：
- `Load(k+1)` 与 `Compute(k)` 重叠；
- `Store(tile i)` 与 `Load(tile i+1)` 重叠（带宽允许时）。

---

## 4. 关键参数与 1 TOPS 估算

峰值估算：

\[
TOPS_{peak} = 2 \times (P_M \times P_N) \times f
\]

其中每个 MAC 计为 2 ops。

示例（仅用于量级评估）：
- 若 `f = 1 GHz`，需 `P_M * P_N ≈ 500`；
- 可行规模如 `16 x 32`（512 PE）或 `22 x 24`（528 PE）。

带宽反推建议：
- 若外存带宽成为瓶颈，优先增大 `Tk` 以提升 A/B 重用；
- 结合 `AXI_DATA_WIDTH`、burst 长度和 Tile 尺寸联调。

---

## 5. 数值精度与实现模式

推荐模式：
- 输入：FP16
- 乘法：FP16
- 累加：FP32
- 输出：舍入/截断回 FP16

可选双模式：
- `MODE_FP16_ACC`：资源更低，误差较大
- `MODE_FP32_ACC`：精度更好，资源更高

---

## 6. 可观测性与验证支撑

建议增加硬件计数器：
- `cycle_total`
- `cycle_compute`
- `cycle_stall_dma`
- `axi_rd_bytes`
- `axi_wr_bytes`
- `burst_len_hist`

用于直接支撑：
- 吞吐（GFLOPS/TOPS）
- 总线利用率
- 不同带宽条件下性能退化曲线

---

## 7. RTL 落地优先级

1. MVP：CSR + 单 Tile 脉动计算 + D 写回
2. 完整 `m/n/k` Tile 循环与边界处理
3. 加入 A/B 双缓冲与访存-计算重叠
4. 增加异常处理（越界/对齐/非法配置）与中断
5. 完善性能计数器与验证回归
6. 针对带宽与功耗做迭代优化

---

## 8. 与 README 要求对应关系

- 功能与维度定义（`D=A×B+C`，FP16） -> 本文第 1、3、5 节
- AXI 输入/输出接口要求 -> 本文第 2.1、2.3 节
- 架构设计说明（数据流、分块、片上存储） -> 本文第 2、3 节
- 性能/带宽优化与验收指标 -> 本文第 4、6、7 节
