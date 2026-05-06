# Compute Core (Systolic Array) Module Spec (Internal)

## 1. Revision History (Internal Documentation)

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1 | 2026-04-30 | Codex | Initial draft for compute core modules (`systolic_core/pe_cell/acc_ctrl/array_io_adapter`). |
| v0.2 | 2026-05-02 | Digital Design | Complete port lists, FSM, and logic design. Align with RTL implementation. |
| v0.3 | 2026-05-04 | Digital Design | Update default parameters to P_M=4, P_N=4. Verified with Verilator. |

## 2. Terms/Abbreviations

- SA: Systolic Array
- PE: Processing Element
- MAC: Multiply-Accumulate
- FMA: Fused Multiply-Add
- FP16: IEEE 754 half precision
- FP32: IEEE 754 single precision
- Fill/Drain: 阵列灌入/排空阶段
- ULP: Unit in the Last Place
- OS: Output-Stationary

## 3. Overview

本规格定义 GEMM 计算核心（脉动阵列）模块，覆盖：
- `systolic_core`
- `pe_cell`
- `acc_ctrl`
- `array_io_adapter`

目标：实现 `D = A×B + C` 中 `A×B` 主计算路径，采用 Output-Stationary 架构，并与上游 buffer、下游后处理协同达到可配置吞吐与可验证精度。

### 3.1. Block Diagram

```text
           A vectors                        B vectors
buffer ---> array_io_adapter ----------+  +---------- array_io_adapter <--- buffer
                                       |  |
                                       v  v
                                 +--------------+
                                 | systolic_core|
                                 | PE[P_M][P_N] |
                                 +------+-------+
                                        |
                                        v
                                   +---------+
                                   | acc_ctrl|
                                   +----+----+
                                        |
                                        v
                                   partial/acc
                                        |
                                        v
                                     postproc
```

### 3.2. Features

- 参数化 `P_M x P_N` PE 阵列
- 支持 `FP16 mul + FP16/FP32 accumulate` 两种模式
- 支持按 `Tk` 分段累加与 tile 级清零/保持
- 支持 fill/drain 周期控制（wavefront propagation）
- 支持边界 tile mask（无效 lane 自动屏蔽）
- 提供性能计数点（active/stall/fill/drain）

## 4. Port List and Parameters (Internal Documentation)

### 4.1 `systolic_core`

`systolic_core` 是 PE 阵列顶层，负责 PE 实例化、数据流传播、控制信号广播、累加结果收集与 tile 生命周期状态机。

#### 4.1.1 Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `P_M` | int | 4 | 阵列行数（A 向量维度） |
| `P_N` | int | 4 | 阵列列数（B 向量维度） |
| `ELEM_W` | int | 16 | FP16 元素位宽 |
| `ACC_W` | int | 32 | 累加器位宽（FP32 默认） |
| `K_MAX` | int | 4096 | 最大 K 迭代次数 |

#### 4.1.2 Port List

| Signal | Direction | Width | Description |
|---|---|---|---|
| `clk` | Input | 1 | 主时钟 |
| `rst_n` | Input | 1 | 异步低有效复位 |
| `core_start` | Input | 1 | 单拍脉冲，启动 tile 计算 |
| `core_mode` | Input | 1 | 累加模式：0=FP16acc，1=FP32acc |
| `a_vec_valid` | Input | 1 | A 向量有效标志 |
| `a_vec_data` | Input | P_M*ELEM_W | A 向量数据（P_M 个 FP16） |
| `a_vec_mask` | Input | P_M | A 向量 per-row mask（1=valid lane） |
| `b_vec_valid` | Input | 1 | B 向量有效标志 |
| `b_vec_data` | Input | P_N*ELEM_W | B 向量数据（P_N 个 FP16） |
| `b_vec_mask` | Input | P_N | B 向量 per-col mask（1=valid lane） |
| `k_iter_cfg` | Input | 16 | Tk（K chunk 大小） |
| `tile_mask_cfg` | Input | P_M*P_N | per-PE mask（边界 tile 无效 lane 屏蔽） |
| `core_busy` | Output | 1 | 阵列计算中 |
| `core_done` | Output | 1 | 单拍脉冲，tile 计算完成 |
| `core_err` | Output | 1 | 协议错误或 K 溢出 |
| `acc_out_valid` | Output | 1 | 累加器输出有效 |
| `acc_out_data` | Output | P_M*P_N*ACC_W | 扁平化 PE 累加器输出 |
| `acc_out_last` | Output | 1 | tile 最后输出标志 |

### 4.2 `pe_cell`

`pe_cell` 是基础处理单元，执行 `acc += a * b`，并支持 A/B 数据传播与累加器控制。

#### 4.2.1 Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `ELEM_W` | int | 16 | FP16 元素位宽 |
| `ACC_W` | int | 32 | 累加器位宽 |
| `ACC_FP32_DEFAULT` | bit | 1'b1 | 默认 FP32 累加 |

#### 4.2.2 Port List

| Signal | Direction | Width | Description |
|---|---|---|---|
| `clk` | Input | 1 | 主时钟 |
| `rst_n` | Input | 1 | 异步低有效复位 |
| `a_in` | Input | ELEM_W | A 数据输入 |
| `b_in` | Input | ELEM_W | B 数据输入 |
| `a_out` | Output | ELEM_W | A 数据输出（右传） |
| `b_out` | Output | ELEM_W | B 数据输出（下传） |
| `valid_in` | Input | 1 | 输入数据有效标志 |
| `acc_clear` | Input | 1 | 清零累加器（高优先级） |
| `acc_hold` | Input | 1 | 保持累加器（冻结） |
| `acc_mode` | Input | 1 | 累加精度：0=FP16，1=FP32 |
| `acc_out` | Output | ACC_W | 累加器结果输出 |
| `valid_out` | Output | 1 | 延迟后的 valid（右传） |
| `sat_flag` | Output | 1 | 饱和/溢出标志（可选） |

#### 4.2.3 Function Description

- `a_out` / `b_out` 为 `a_in` / `b_in` 的 1 拍寄存延迟（传播）
- `valid_out` 为 `valid_in` 的 1 拍延迟
- 当 `valid_in && !acc_clear && !acc_hold` 时执行 `acc += a_in * b_in`
- `acc_clear` 高电平时，`acc` 在下一拍清零
- `acc_hold` 高电平时，`acc` 保持当前值
- `acc_mode` 控制累加精度：FP16（截断）或 FP32（全精度）

### 4.3 `acc_ctrl`

`acc_ctrl` 负责累加器生命周期管理：tile 启动清零、k-chunk 间保持、tile 完成提交。

#### 4.3.1 Port List

| Signal | Direction | Width | Description |
|---|---|---|---|
| `clk` | Input | 1 | 主时钟 |
| `rst_n` | Input | 1 | 异步低有效复位 |
| `tile_start` | Input | 1 | tile 启动脉冲 |
| `k_chunk_start` | Input | 1 | k-chunk 启动（触发 acc_clear） |
| `k_chunk_last` | Input | 1 | 最后一个 k-chunk（触发 tile_done） |
| `drain_done` | Input | 1 | drain 完成标志 |
| `acc_clear` | Output | 1 | 广播至所有 PE |
| `acc_hold` | Output | 1 | 广播至所有 PE |
| `acc_commit` | Output | 1 | 累加结果提交脉冲 |
| `tile_done` | Output | 1 | tile 完成脉冲 |

#### 4.3.2 Function Description

- `tile_start` 触发 `acc_clear`，准备新 tile
- `k_chunk_start` 在每个 k-chunk 开始时触发 `acc_clear`
- 非 `k_chunk_start` 且 tile 未完成时，`acc_hold=0` 允许累加
- `k_chunk_last && drain_done` 触发 `acc_commit` 和 `tile_done`

### 4.4 `array_io_adapter`

`array_io_adapter` 将 buffer 数据重排为 systolic_core 所需的注入向量格式，并处理 skew 延迟。

#### 4.4.1 Port List

| Signal | Direction | Width | Description |
|---|---|---|---|
| `clk` | Input | 1 | 主时钟 |
| `rst_n` | Input | 1 | 异步低有效复位 |
| `buf_a_data` | Input | P_M*ELEM_W | Buffer A 数据 |
| `buf_b_data` | Input | P_N*ELEM_W | Buffer B 数据 |
| `issue_valid` | Input | 1 | Buffer 数据有效 |
| `mask_cfg` | Input | P_M*P_N | 边界 mask 配置 |
| `a_vec_valid` | Output | 1 | A 向量有效 |
| `a_vec_data` | Output | P_M*ELEM_W | A 向量数据（带 skew） |
| `a_vec_mask` | Output | P_M | A 向量 mask |
| `b_vec_valid` | Output | 1 | B 向量有效 |
| `b_vec_data` | Output | P_N*ELEM_W | B 向量数据（带 skew） |
| `b_vec_mask` | Output | P_N | B 向量 mask |
| `issue_ready` | Output | 1 | Adapter 可接收下一拍 |

#### 4.4.2 Skew 机制

为匹配 systolic wavefront，A/B 数据需按行列延迟注入：
- A 第 `i` 行延迟 `i` 拍后进入阵列（`i = 0 .. P_M-1`）
- B 第 `j` 列延迟 `j` 拍后进入阵列（`j = 0 .. P_N-1`）
- Skew 通过内部移位寄存器实现，深度 `max(P_M, P_N)-1`

## 5. Functional Descriptions

### 5.1. Normal Function

1. `array_io_adapter` 将 buffer 数据组织成每拍注入向量，并按行列施加 skew 延迟
2. `systolic_core` 按拍将 A 左入、B 上入，在 PE 内执行 MAC
3. `acc_ctrl` 在 `k0` 片段间控制清零/保持/提交
4. 完成 `Tk + fill + drain` 后输出 tile 累加结果
5. 输出送入 `postproc` 执行 `+C/round/cast`

#### 5.1.1. Systolic Data Flow (OS)

对于 `PE[i][j]`（`0 <= i < P_M`, `0 <= j < P_N`）：
```
acc[i][j] += A[i][k] * B[k][j]   for k = 0 .. Tk-1
```

Wavefront 时序：
- A 元素 `A[i][k]` 从阵列左边第 `i` 行注入，向右传播，到达 `PE[i][j]` 需 `j` 拍
- B 元素 `B[k][j]` 从阵列顶部第 `j` 列注入，向下传播，到达 `PE[i][j]` 需 `i` 拍
- 通过 skew 延迟使 `A[i][k]` 和 `B[k][j]` 在 `PE[i][j]` 相遇

总计算周期（单 k-chunk）：
```
T_total = Tk + (P_M - 1) + (P_N - 1)
```

- Fill = `(P_M-1) + (P_N-1)`：从第一个 PE 激活到全部 PE 激活
- Compute = `Tk`：所有 PE 同时有效计算
- Drain = `(P_M-1) + (P_N-1)`：从最后一个输入注入到最后一个 PE 完成

### 5.2. Diagnostic Function (Optional)

建议可观测项：
- `cycle_active`, `cycle_fill`, `cycle_drain`, `cycle_stall`
- `valid_utilization`（有效 MAC 比例）
- `sat_flag_count`（若支持饱和统计）

### 5.2.1. Configuration Methods (Optional)

- `DEBUG_CORE_CTRL`：
  - `dbg_freeze_pipe`
  - `dbg_step_cycle`

## 6. Test/Debug Modes (Internal Documentation)

- `single_pe_mode`：仅激活 `PE[0][0]`
- `bypass_acc_mode`：旁路累加寄存器做组合链路检查
- `force_mask_mode`：强制部分 lane 无效

### 6.1.1. Configuration Methods

- `DEBUG_CORE_MODE[0]`：single_pe
- `DEBUG_CORE_MODE[1]`：bypass_acc
- `DEBUG_CORE_MODE[2]`：force_mask

## 7. Architecture Descriptions (Internal Documentation)

### 7.1. Architecture Overview

计算核心由“输入适配 + PE 阵列 + 累加控制”组成：
- 输入适配层：`array_io_adapter`
- 计算阵列层：`systolic_core/pe_cell`
- 控制与提交层：`acc_ctrl`

### 7.2. Clocks and Resets

- 主时钟域：`clk`
- 异步低有效复位：`rst_n`
- 复位行为：清空有效位流水、清零本地累加、`done` 拉低

### 7.2.1. Clock and Reset Description / Logic Circuit

- 每级 PE 建议寄存 `a/b/valid`（1 拍传播延迟）
- `core_start` 采用单拍脉冲并锁存任务上下文

### 7.2.2. CDC Synchronization Scheme (Optional)

若 buffer 与 core 异频：
- 向量输入走 async FIFO
- `core_done` 采用 pulse-stretch + 双触发同步

### 7.3. Top Main Interfaces

- 上游：`buffer_bank` / `array_io_adapter`
- 下游：`postproc`
- 控制：`tile_scheduler`

### 7.4. Architecture Scheme Comparison

- 方案 A：输出驻留（Output-Stationary, OS）
  - 优点：局部累加访存少，GEMM 通用性好
  - 缺点：控制复杂，需要 fill/drain
- 方案 B：权重驻留（Weight-Stationary, WS）
  - 优点：某些模型复用高
  - 缺点：GEMM 通用性下搬运复杂

**本项目采用：OS 方案。**

### 7.5. Sub-Module `acc_ctrl`

#### 7.5.1. Overview

- 管理 `k` 维分段、累加生命周期、tile 完成时机
- 状态机：`IDLE -> COMPUTE -> COMMIT -> DONE`

#### 7.5.2. Sub-Module `acc_rdctl`

##### 7.5.2.1. Overview

- 负责读取/接收本轮向量发射节拍控制（issue control）

##### 7.5.2.2. Logic Design

- 当 `a_vec_valid && b_vec_valid && core_busy` 时推进 `k_cnt`
- fill 阶段推进数据但不提交 tile_done
- mask lane 在 valid 路径拉低

#### 7.5.3. Sub-Module `acc_wrctl`

##### 7.5.3.1. Overview

- 负责累加结果提交与输出节拍控制（commit control）

##### 7.5.3.2. Logic Design

- `tile_start` 触发 `acc_clear`
- 计算期间 `acc_hold=0` 允许累加
- drain 结束后触发 `acc_commit` 和 `tile_done`

### 7.6. Sub-Module `core_dp`

- `k_cnt` 计数器（范围 `0 .. Tk + FILL_DRAIN_CYCLES - 1`）
- lane mask 展开：`tile_mask_cfg[row*P_N+col]`
- FP mode 选择 datapath：`core_mode`

### 7.7. Sub-Module `core_mem` (Optional)

- PE 内部累加寄存阵列（`acc_pe[P_M][P_N]`）
- 结果扁平化输出：`acc_out_data[(row*P_N+col+1)*ACC_W-1:(row*P_N+col)*ACC_W]`

### 7.8. Logic Design

#### 7.8.1. PE 阵列连接

```text
A propagation (horizontal):
  a_mesh[row][0] = a_vec_data[row]
  a_mesh[row][col+1] = PE[row][col].a_out    (col = 0..P_N-1)

B propagation (vertical):
  b_mesh[0][col] = b_vec_data[col]
  b_mesh[row+1][col] = PE[row][col].b_out    (row = 0..P_M-1)

Valid propagation:
  v_mesh[row][0] = a_vec_valid && a_vec_mask[row]
  v_mesh[row][col+1] = PE[row][col].valid_out (A-valid chain, col = 0..P_N-1)
  
  v_bmesh[0][col] = b_vec_valid && b_vec_mask[col]
  v_bmesh[row+1][col] = v_bmesh[row][col]    (B-valid independent, row = 0..P_M-2)

PE valid_in:
  valid_in[row][col] = v_mesh[row][col] && v_bmesh[row][col] && tile_mask_cfg[row*P_N+col]
```

#### 7.8.2. Control FSM

状态机：`IDLE -> COMPUTE -> COMMIT -> DONE`

| State | Description | acc_clear | acc_hold | Duration |
|---|---|---|---|---|
| `IDLE` | 等待启动 | 1 | - | 直到 `core_start` |
| `COMPUTE` | 注入数据并计算 | 0 | 0 | `Tk + FILL_DRAIN_CYCLES` |
| `COMMIT` | 输出累加结果 | 0 | 1 | 1 拍 |
| `DONE` | 完成脉冲 | 0 | 1 | 1 拍 |

注：`FILL_DRAIN_CYCLES = P_M + P_N - 2`

#### 7.8.3. Error Detection

- `core_start && core_busy`：协议错误（启动时忙碌）
- `k_cnt > K_MAX`：K 维度溢出

#### 7.8.4. Timing

| Parameter | Value | Description |
|---|---|---|
| `T_fill` | `P_M + P_N - 2` | Wavefront 填满阵列 |
| `T_compute` | `Tk` | 所有 PE 有效计算 |
| `T_drain` | `P_M + P_N - 2` | Wavefront 排空阵列 |
| `T_total` | `Tk + 2*(P_M + P_N - 2)` | 单 k-chunk 总周期 |

### 7.9. Low Power Design (Optional)

- `valid=0` 时关闭 PE 乘法器输入翻转
- 空闲 tile 时门控 `k_cnt` 计数器
- debug 模式关闭时切断可选探针路径

### 7.10. Architecture Open Issues

- FP16 accumulate 精度在长 K 下误差累积明显 → **默认 FP32 accumulate**
- 大尺寸阵列高频时序压力大 → **增加 PE pipeline stage 并重算 fill/drain**
- 边界 mask 复杂时利用率下降 → **调整 tile 形状，减少尾块比例**

## 8. Integration Guide

- 与 `buffer_bank`：统一 lane 顺序与端序（小端）
- 与 `postproc`：统一 `acc_out_last` 语义（tile-last）
- 与 `tile_scheduler`：`core_start/core_done` 必须一一对应

## 9. Implementation Guide

建议落地顺序：
1. 单 PE 功能正确（FP16/FP32）—— `pe_cell`
2. 2x2 阵列连通和 valid 对齐 —— `systolic_core`
3. 参数化扩展到 `P_M x P_N`
4. 接入 `acc_ctrl` 与 tile 生命周期
5. 接入 `array_io_adapter` 处理 skew
6. 接入 `postproc` 做端到端仿真

## 10. Verification Guide

### 10.1. 功能测试

- 1x1、2x2、小矩阵、非整 tile
- 与软件黄金模型逐元素比较（ULP 阈值）
- 矩阵乘法验证：`D = A x B`，其中 `A` 为 `P_M x Tk`，`B` 为 `Tk x P_N`

### 10.2. 时序/控制测试

- fill/drain 周期准确性（检查 `core_done` 相对 `core_start` 的延迟）
- `start/done` 对齐和反压稳定性
- 连续 tile 启动测试

### 10.3. 异常测试

- mask 全零/全一
- reset during compute
- `core_start` 在 `core_busy` 期间触发（应报 `core_err`）

### 10.4. 覆盖建议

- mode 覆盖（FP16acc/FP32acc）
- lane mask 覆盖（边界 tile 场景）
- 状态机路径覆盖（IDLE/COMPUTE/COMMIT/DONE）

## 11. Registers

建议寄存器：

### 11.1 `CORE_CTRL` (0x000)

| Bit | Name | Type | Description |
|---|---|---|---|
| 0 | `core_en` | RW | 阵列使能 |
| 1 | `fp32_acc_en` | RW | 1=FP32 累加，0=FP16 累加 |
| 2 | `mask_en` | RW | 边界 mask 使能 |

### 11.2 `CORE_CFG0` (0x004)

| Field | Bits | Description |
|---|---|---|
| `tk_cfg` | [15:0] | K chunk 大小 |
| `fill_guard` | [23:16] | Fill 周期数（默认 `P_M+P_N-2`） |
| `drain_guard` | [31:24] | Drain 周期数（默认 `P_M+P_N-2`） |

### 11.3 `CORE_STATUS` (0x008)

| Bit | Name | Description |
|---|---|---|
| 0 | `core_busy` | 阵列计算中 |
| 1 | `core_done` | tile 完成（W1C） |
| 2 | `core_err` | 错误标志 |

### 11.4 `CORE_ERR_CODE` (0x00C)

| Bit | Name | Description |
|---|---|---|
| 0 | `illegal_mode` | 非法模式配置 |
| 1 | `protocol_mismatch` | 协议错误（start 时 busy） |
| 2 | `internal_overflow` | 内部溢出 |

### 11.5 Performance Counters

| Address | Name | Description |
|---|---|---|
| 0x010 | `CORE_PERF_ACTIVE` | 有效计算周期 |
| 0x014 | `CORE_PERF_STALL` | 停滞周期 |
| 0x018 | `CORE_PERF_FILL` | Fill 周期 |
| 0x01C | `CORE_PERF_DRAIN` | Drain 周期 |

## 12. Reference

- `ARCHITECTURE.md`
- `spec/modules.md`
- `spec/dma_axi_access_spec.md`
- `spec/onchip_buffer_reorder_spec.md`

## 13. Open Issues & Workaround

1. **Open Issue**: 大尺寸阵列在高频下时序压力大。
   **Workaround**: 增加 PE pipeline stage 并重算 fill/drain 参数。
2. **Open Issue**: FP16 accumulate 在长 K 下误差累积明显。
   **Workaround**: 默认启用 FP32 accumulate。
3. **Open Issue**: 边界 mask 复杂时利用率下降。
   **Workaround**: 调整 tile 形状，优先减少尾块比例。
4. **Open Issue**: `array_io_adapter` skew 逻辑增加面积。
   **Workaround**: MVP 阶段用外部 testbench 模拟 skew，后续版本硬化。
