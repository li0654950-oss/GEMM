# Compute Core (Systolic Array) Module Spec (Internal)

## 1. Revision History (Internal Documentation)

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1 | 2026-04-30 | Codex | Initial draft for compute core modules (`systolic_core/pe_cell/acc_ctrl/array_io_adapter`). |

## 2. Terms/Abbreviations

- SA: Systolic Array
- PE: Processing Element
- MAC: Multiply-Accumulate
- FMA: Fused Multiply-Add
- FP16: IEEE 754 half precision
- FP32: IEEE 754 single precision
- Fill/Drain: 阵列灌入/排空阶段
- ULP: Unit in the Last Place

## 3. Overview

本规格定义 GEMM 计算核心（脉动阵列）模块，覆盖：
- `systolic_core`
- `pe_cell`
- `acc_ctrl`
- `array_io_adapter`

目标：实现 `D = A×B + C` 中 `A×B` 主计算路径，并与上游 buffer、下游后处理协同达到可配置吞吐与可验证精度。

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
- 支持 fill/drain 周期控制
- 支持边界 tile mask（无效 lane 自动屏蔽）
- 提供性能计数点（active/stall/fill/drain）

## 4. Port List and Parameters (Internal Documentation)

### 4.1 `systolic_core`

- Input
  - `clk`, `rst_n`
  - `core_start`, `core_mode`
  - `a_vec_valid`, `a_vec_data`, `a_vec_mask`
  - `b_vec_valid`, `b_vec_data`, `b_vec_mask`
  - `k_iter_cfg`, `tile_mask_cfg`
- Output
  - `core_busy`, `core_done`
  - `acc_out_valid`, `acc_out_data`, `acc_out_last`
  - `core_err`

### 4.2 `pe_cell`

- Input: `a_in`, `b_in`, `acc_in`, `valid_in`, `mode`
- Output: `a_out`, `b_out`, `acc_out`, `valid_out`, `sat_flag`（可选）

### 4.3 `acc_ctrl`

- Input: `tile_start`, `k_chunk_start`, `k_chunk_last`, `pe_acc_data`
- Output: `acc_clear`, `acc_hold`, `acc_commit`, `tile_done`

### 4.4 `array_io_adapter`

- Input: `buf_a_data`, `buf_b_data`, `issue_valid`, `mask_cfg`
- Output: `a_vec_*`, `b_vec_*`, `issue_ready`

### 4.5 Key Parameters

- `P_M`, `P_N`（阵列维度）
- `ELEM_W` (default 16)
- `ACC_W` (default 32)
- `K_MAX` (default 4096)
- `PIPE_STAGES_PE` (default 1)
- `ROUND_MODE` (default RNE)

## 5. Functional Descriptions

### 5.1. Normal Function

1. `array_io_adapter` 将 buffer 数据组织成每拍注入向量
2. `systolic_core` 按拍将 A 左入、B 上入，在 PE 内执行 MAC
3. `acc_ctrl` 在 `k0` 片段间控制清零/保持/提交
4. 完成 `Tk + fill + drain` 后输出 tile 累加结果
5. 输出送入 `postproc` 执行 `+C/round/cast`

### 5.1.1. Configuration Methods(Optional)

建议可配置：
- 累加模式：FP16 accumulate / FP32 accumulate
- `Tk` 与 fill/drain guard cycles
- 边界 mask 开关

### 5.2. Diagnostic Function(Optional)

建议可观测项：
- `cycle_active`, `cycle_fill`, `cycle_drain`, `cycle_stall`
- `valid_utilization`（有效 MAC 比例）
- `sat_flag_count`（若支持饱和统计）

### 5.2.1. Configuration Methods(Optional)

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

### 7.2.1. Clock and Reset Description / Logic Circuit (Optional)

- 每级 PE 建议寄存 `a/b/valid`
- `core_start` 采用单拍脉冲并锁存任务上下文

### 7.2.2. CDC Synchronization Scheme (Optional)

若 buffer 与 core 异频：
- 向量输入走 async FIFO
- `core_done` 采用 pulse-stretch + 双触发同步

### 7.2.3. RDC Synchronization Scheme (Optional)

- 多复位域场景下，`start` 必须等待 core 域 ready
- 异常复位后丢弃未提交 partial，防止脏数据外泄

### 7.3. Top Main Interfaces (Optional)

- 上游：`buffer_bank`/`array_io_adapter`
- 下游：`postproc`
- 控制：`tile_scheduler`

### 7.4. Architecture Scheme Comparison (Optional)

- 方案 A：输出驻留（Output-Stationary, OS）
  - 优点：局部累加访存少
  - 缺点：控制更复杂
- 方案 B：权重驻留（Weight-Stationary, WS）
  - 优点：某些模型复用高
  - 缺点：GEMM 通用性下搬运复杂

本项目建议：优先 OS 方案。

### 7.5. Sub-Module XXX_CTL (Optional)

`XXX_CTL` 对应 `acc_ctrl`（计算控制子模块）。

### 7.5.1. Overview

- 管理 `k` 维分段、累加生命周期、tile 完成时机

### 7.5.2. Sub-Module XXX_RDCTL

#### 7.5.2.1. Overview

- 负责读取/接收本轮向量发射节拍控制（issue control）

#### 7.5.2.2. Logic Design

- 当 `a_vec_valid && b_vec_valid && core_busy` 时推进 `k_cnt`
- fill 阶段仅推进数据，不提交 tile_done
- mask lane 在 valid 路径拉低

### 7.5.3.  Sub-Module XXX_WRCTL

#### 7.5.3.1. Overview

- 负责累加结果提交与输出节拍控制（commit control）

#### 7.5.3.2. Logic Design

- `k_chunk_start` 触发 `acc_clear`
- `k_chunk_middle` 保持 `acc_hold`
- `k_chunk_last` + drain 结束触发 `acc_commit/tile_done`

### 7.5.4.  Logic Design

建议状态机：
`IDLE -> FILL -> COMPUTE -> DRAIN -> COMMIT -> DONE`

### 7.6. Sub-Module XXX_DP (Optional)

- `k_cnt`/`fill_cnt`/`drain_cnt` 计数器
- lane mask 展开
- FP mode 选择 datapath

### 7.7. Sub-Module XXX_MEM(Optional)

- PE 内部累加寄存阵列
- 可选小型结果暂存 FIFO

### 7.8. Logic Design (Optional)

PE 计算建议：
1. `mul = a_in * b_in`
2. `acc_next = acc_prev + mul`
3. `a_in/b_in` 同拍前传到相邻 PE
4. `valid` 与 `mask` 同步传播

总延时估计（单 `k0`）：
- 有效 MAC：`Tk`
- Fill/Drain：`(P_M-1) + (P_N-1)`

### 7.9. Low Power Design (Optional)

- `valid=0` 时关闭 PE 乘法器输入翻转
- 空闲 tile 时门控 `k_cnt/fill_cnt/drain_cnt`
- debug 模式关闭时切断可选探针路径

### 7.10. Architecture Open Issues (Optional)

- FP16 accumulate 精度是否可接受（依 workload）
- PE 深流水增加频率但会拉长 fill/drain
- 是否引入稀疏跳零优化（当前未纳入 MVP）

## 8. Integration Guide (Internal Documentation)

- 与 `buffer_bank`：统一 lane 顺序与端序
- 与 `postproc`：统一 `acc_out_last` 语义（tile-last）
- 与 scheduler：`core_start/core_done` 必须一一对应

## 9. Implementation Guide (Internal Documentation)

建议落地顺序：
1. 单 PE 功能正确（FP16/FP32）
2. 2x2 阵列连通和 valid 对齐
3. 参数化扩展到 `P_MxP_N`
4. 接入 `acc_ctrl` 与 tile 生命周期
5. 接入 adapter/postproc 做端到端仿真

## 10. Verification Guide (Internal Documentation)

- 功能测试：
  - 1x1、2x2、小矩阵、非整 tile
  - 与软件黄金模型逐元素比较（ULP 阈值）
- 时序/控制测试：
  - fill/drain 周期准确性
  - `start/done` 对齐和反压稳定性
- 异常测试：
  - mask 全零/全一
  - reset during compute
- 覆盖建议：
  - mode 覆盖（FP16acc/FP32acc）
  - lane mask 覆盖
  - 状态机路径覆盖

## 11. Registers

建议寄存器：
- `CORE_CTRL`
  - bit0 `core_en`
  - bit1 `fp32_acc_en`
  - bit2 `mask_en`
- `CORE_CFG0`
  - `tk_cfg`
  - `fill_guard`
  - `drain_guard`
- `CORE_STATUS`
  - `core_busy`, `core_done`
- `CORE_ERR_CODE`
  - bit0 `illegal_mode`
  - bit1 `protocol_mismatch`
  - bit2 `internal_overflow`
- `CORE_PERF_ACTIVE`
- `CORE_PERF_STALL`

## 12. Reference (Internal Documentation)

- `ARCHITECTURE.md`
- `spec/modules.md`
- `spec/dma_axi_access_spec.md`
- `spec/onchip_buffer_reorder_spec.md`

## 13. Open Issues & Workaround (Internal Documentation)

1. **Open Issue**: 大尺寸阵列在高频下时序压力大。  
   **Workaround**: 增加 PE pipeline stage 并重算 fill/drain 参数。
2. **Open Issue**: FP16 accumulate 在长 K 下误差累积明显。  
   **Workaround**: 默认启用 FP32 accumulate。
3. **Open Issue**: 边界 mask 复杂时利用率下降。  
   **Workaround**: 调整 tile 形状，优先减少尾块比例。
