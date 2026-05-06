# Postprocess & Numeric Module Spec (Internal)

## 1. Revision History (Internal Documentation)

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1 | 2026-04-30 | Codex | Initial draft for postprocess and numeric modules (`postproc/fp_add_c/fp_round_sat`). |
| v0.2 | 2026-05-02 | Digital Design | Complete port lists, address mapping, pipeline stages, integration with systolic_core/d_storer. Align with RTL implementation. |
| v0.3 | 2026-05-02 | Digital Design | Refined datapath width, handshake protocol, exception handling, and verification strategy. |
| v0.4 | 2026-05-04 | Digital Design | Update default parameters to P_M=4, P_N=4. Verified with Verilator. |

## 2. Terms/Abbreviations

- Postproc: Post-processing stage after systolic accumulation
- RNE: Round to Nearest, ties to Even
- RTZ: Round Toward Zero
- RUP: Round Up (toward +inf)
- RDN: Round Down (toward -inf)
- SAT: Saturation
- DENORM: Subnormal number
- NaN: Not a Number
- Inf: Infinity
- ULP: Unit in the Last Place
- Bypass: 旁路模式（不执行某功能）
- Lane: 独立数据通道（对应一个 PE 输出）
- QNaN: Quiet NaN
- SNaN: Signaling NaN

## 3. Overview

本规格定义 GEMM 后处理与数值模块，覆盖：
- `postproc`：后处理顶层控制与流水线
- `fp_add_c`：可选 C tile 累加融合
- `fp_round_sat`：FP32→FP16 转换、舍入与饱和

目标：将计算核心输出的 FP32 累加结果与可选 C tile 融合，执行数值处理后输出 FP16 数据流给 `d_storer`。

### 3.1. Block Diagram

```text
        from systolic_core (acc)
                 |
                 v
        +-------------------+
        | postproc          |
        | ctrl + pipeline   |
        | Stage0: align/mask|
        +---------+---------+
                  |
        +---------+---------+
        | fp_add_c          | <---- optional C tile stream (from c_loader)
        | FP32 add / bypass |       or buffer_bank C_BUF
        | Stage1            |
        +---------+---------+
                  |
        +---------+---------+
        | fp_round_sat      |
        | FP32→FP16         |
        | round + sat + exc |
        | Stage2            |
        +---------+---------+
                  |
                  v
             to d_storer
```

### 3.2. Features

- 支持 `acc + C` 融合与 C 旁路（`add_c_en` 控制）
- 支持 FP32→FP16 转换（默认输出 FP16）
- 支持 4 种舍入模式（RNE/RTZ/RUP/RDN），默认 RNE
- 支持溢出饱和、NaN/Inf 统一处理策略
- 支持边界 tile mask lane 级抑制（无效 lane 输出 0）
- 支持异常统计计数（overflow/denorm/nan/inf/underflow）
- 支持流水线反压（valid/ready 握手）

## 4. Port List and Parameters (Internal Documentation)

### 4.1 Global Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `P_M` | int | 4 | 阵列行数 |
| `P_N` | int | 4 | 阵列列数 |
| `ELEM_W` | int | 16 | FP16 输出元素位宽 |
| `ACC_W` | int | 32 | FP32 累加器位宽 |
| `LANES` | int | P_M*P_N | 并行处理通道数 |
| `ROUND_MODE_DFT` | int | 2'b00 | 默认舍入模式：00=RNE |
| `SAT_EN_DFT` | bit | 1'b1 | 默认使能饱和 |
| `NAN_POLICY` | int | 2'b00 | NaN 策略：00=propagate QNaN |

### 4.2 `postproc` 顶层模块

#### 4.2.1 Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `P_M` | int | 4 | 阵列行数 |
| `P_N` | int | 4 | 阵列列数 |
| `ELEM_W` | int | 16 | 输出 FP16 位宽 |
| `ACC_W` | int | 32 | 输入 FP32 位宽 |
| `LANES` | int | P_M*P_N | 并行 lane 数 |

#### 4.2.2 Port List — 系统接口

| Signal | Direction | Width | Description |
|---|---|---|---|
| `clk` | Input | 1 | 主时钟 |
| `rst_n` | Input | 1 | 异步低有效复位 |
| `pp_start` | Input | 1 | tile 启动脉冲，锁存配置上下文 |
| `pp_busy` | Output | 1 | 后处理忙标志 |
| `pp_done` | Output | 1 | tile 完成后处理完成脉冲 |
| `pp_err` | Output | 1 | 协议或非法配置错误 |

#### 4.2.3 Port List — 配置接口（来自 CSR/scheduler）

| Signal | Direction | Width | Description |
|---|---|---|---|
| `add_c_en` | Input | 1 | 1=启用 C tile 融合，0=旁路 |
| `round_mode` | Input | 2 | 00=RNE, 01=RTZ, 10=RUP, 11=RDN |
| `sat_en` | Input | 1 | 1=溢出时饱和，0=溢出时保留 Inf |
| `tile_mask` | Input | LANES | per-lane mask（1=valid，边界 tile 使用） |

#### 4.2.4 Port List — 上游输入（来自 systolic_core）

| Signal | Direction | Width | Description |
|---|---|---|---|
| `acc_valid` | Input | 1 | 累加结果有效（单拍脉冲，COMMIT 状态） |
| `acc_data` | Input | LANES*ACC_W | 扁平化 FP32 累加器输出 |
| `acc_last` | Input | 1 | tile 最后一个累加输出 |

#### 4.2.5 Port List — 上游输入 C（来自 c_loader / C_BUF）

| Signal | Direction | Width | Description |
|---|---|---|---|
| `c_valid` | Input | 1 | C tile 数据有效 |
| `c_ready` | Output | 1 | postproc 可接收 C 数据 |
| `c_data` | Input | LANES*ELEM_W | 扁平化 FP16 C tile 数据 |
| `c_last` | Input | 1 | C tile 最后拍 |

#### 4.2.6 Port List — 下游输出（至 d_storer）

| Signal | Direction | Width | Description |
|---|---|---|---|
| `d_valid` | Output | 1 | 后处理结果有效 |
| `d_ready` | Input | 1 | d_storer 可接收 |
| `d_data` | Output | LANES*ELEM_W | 扁平化 FP16 输出数据 |
| `d_last` | Output | 1 | tile 最后输出拍 |
| `d_mask` | Output | LANES | per-lane 字节掩码（边界 tile 使用） |

#### 4.2.7 Port List — 异常统计（至 CSR）

| Signal | Direction | Width | Description |
|---|---|---|---|
| `exc_nan_cnt` | Output | 16 | NaN 异常计数（sticky，需 W1C 清零） |
| `exc_inf_cnt` | Output | 16 | Inf 异常计数 |
| `exc_ovf_cnt` | Output | 16 | 溢出计数 |
| `exc_udf_cnt` | Output | 16 | 下溢/underflow 计数 |
| `exc_denorm_cnt` | Output | 16 | 非正规数计数 |

### 4.3 `fp_add_c`

#### 4.3.1 Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `ACC_W` | int | 32 | 累加器位宽（FP32） |
| `ELEM_W` | int | 16 | C 数据位宽（FP16） |
| `LANES` | int | 4 | 并行 lane 数（P_M*P_N） |

#### 4.3.2 Port List

| Signal | Direction | Width | Description |
|---|---|---|---|
| `clk` | Input | 1 | 主时钟 |
| `rst_n` | Input | 1 | 异步低有效复位 |
| `add_en` | Input | 1 | 1=执行 acc+C，0=旁路 acc |
| `lane_mask` | Input | LANES | per-lane 使能掩码 |
| `x_valid` | Input | 1 | FP32 acc 输入有效 |
| `x_data` | Input | LANES*ACC_W | FP32 累加结果 |
| `c_valid` | Input | 1 | FP16 C 输入有效 |
| `c_data` | Input | LANES*ELEM_W | FP16 C 数据 |
| `y_valid` | Output | 1 | 输出有效 |
| `y_data` | Output | LANES*ACC_W | FP32 加法结果或旁路 acc |
| `add_exc` | Output | LANES | per-lane 加法异常标志 |

#### 4.3.3 功能描述

1. **旁路模式**（`add_en=0`）：`y_data = x_data`，`y_valid = x_valid`
2. **融合模式**（`add_en=1`）：
   - C 数据 FP16→FP32 扩展（保留符号位、指数偏移）
   - 执行 FP32 加法：`y_data[lane] = x_data[lane] + c_ext[lane]`
   - `lane_mask[lane]=0` 时该 lane 输出 0
3. **异常检测**：
   - 若 x 或 c 为 NaN → 输出 QNaN，置位 `add_exc`
   - 若 x 或 c 为 Inf 且符号相反 → 输出 QNaN（无穷减无穷），置位 `add_exc`
   - 正常 Inf 加减 → 输出 Inf，不置位

### 4.4 `fp_round_sat`

#### 4.4.1 Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `ACC_W` | int | 32 | 输入 FP32 位宽 |
| `ELEM_W` | int | 16 | 输出 FP16 位宽 |
| `LANES` | int | 4 | 并行 lane 数 |

#### 4.4.2 Port List

| Signal | Direction | Width | Description |
|---|---|---|---|
| `clk` | Input | 1 | 主时钟 |
| `rst_n` | Input | 1 | 异步低有效复位 |
| `round_mode` | Input | 2 | 00=RNE, 01=RTZ, 10=RUP, 11=RDN |
| `sat_en` | Input | 1 | 1=溢出饱和为最大 FP16 值 |
| `lane_mask` | Input | LANES | per-lane 使能掩码 |
| `in_valid` | Input | 1 | 输入有效 |
| `in_data` | Input | LANES*ACC_W | FP32 输入数据 |
| `out_valid` | Output | 1 | 输出有效 |
| `out_data` | Output | LANES*ELEM_W | FP16 输出数据 |
| `exc_flags` | Output | LANES*5 | per-lane 异常标志：[4]=NaN,[3]=Inf,[2]=OVF,[1]=UDF,[0]=DENORM |

#### 4.4.3 功能描述

1. **NaN 处理**：
   - 输入为 NaN → 输出 QNaN（sign=0, exp=0x1F, mant=0x200），置位 `exc_flags[4]`
   - SNaN → 静默化后输出，置位 `exc_flags[4]`
2. **Inf 处理**：
   - 输入为 Inf → 输出 Inf（sign保留, exp=0x1F, mant=0x000），置位 `exc_flags[3]`
3. **正常值转换**：
   - 提取 FP32 符号、指数、尾数
   - 指数范围检查：
     - 若指数 > 15（FP16 max）→ 溢出处理
     - 若指数 < -14（FP16 min）→ 下溢处理
   - 尾数舍入：根据 `round_mode` 截断或进位
4. **溢出处理**（`sat_en=1`）：
   - 正溢出 → `0x7BFF`（FP16 max ≈ 65504）
   - 负溢出 → `0xFBFF`（-FP16 max）
   - 置位 `exc_flags[2]`
5. **溢出处理**（`sat_en=0`）：
   - 正溢出 → `0x7C00`（+Inf）
   - 负溢出 → `0xFC00`（-Inf）
   - 置位 `exc_flags[2]` 和 `exc_flags[3]`
6. **下溢处理**：
   - 值太小（< 2^-24）→ flush to zero
   - 置位 `exc_flags[1]`（underflow）
7. **非正规数（DENORM）**：
   - FP16 输出不保留 DENORM，flush to zero
   - 置位 `exc_flags[0]`

## 5. Functional Descriptions

### 5.1. Normal Function

1. `postproc` 在 `pp_start` 后锁存配置（`add_c_en`, `round_mode`, `sat_en`, `tile_mask`）
2. 等待 `acc_valid` 脉冲（systolic_core COMMIT 状态输出）
3. Stage0（对齐）：`acc_data` 打入流水线寄存器
   - 若 `add_c_en=1` 且 `c_valid=0`， stall 等待 C 数据
4. Stage1（`fp_add_c`）：
   - `add_en=0`：直通 acc 数据
   - `add_en=1`：FP16 C → FP32 扩展后与 acc 相加
   - 应用 `lane_mask`，无效 lane 输出 0
5. Stage2（`fp_round_sat`）：
   - FP32→FP16 转换
   - 舍入/饱和/异常处理
   - 输出 `d_valid/d_data/d_last`
6. `d_last` 在 tile 最后输出时置位（跟随 `acc_last`）

### 5.1.1. Configuration Methods

配置来自 `tile_scheduler` 或 CSR 接口：

| 配置项 | 位宽 | 默认值 | 说明 |
|---|---|---|---|
| `add_c_en` | 1 | 0 | 1=启用 C 融合 |
| `round_mode` | 2 | 2'b00 | 00=RNE, 01=RTZ, 10=RUP, 11=RDN |
| `sat_en` | 1 | 1'b1 | 1=溢出饱和 |
| `tile_mask` | LANES | 全1 | per-lane 有效掩码 |

### 5.2. Pipeline Stages

```text
Cycle N:   acc_valid (systolic_core COMMIT)
Cycle N+1: Stage0 - 输入锁存
Cycle N+2: Stage1 - fp_add_c (若 add_c_en，需 c_valid 同步)
Cycle N+3: Stage2 - fp_round_sat
Cycle N+4: d_valid (输出至 d_storer)
```

- 旁路模式（`add_c_en=0`）：可压缩为 2 级流水（Stage0→Stage2）
- 融合模式（`add_c_en=1`）：固定 3 级流水
- 每级采用 `valid/ready` 反压，stall 时保持数据不变

### 5.3. Diagnostic Function

异常计数器（sticky 计数器，W1C 清零）：

| 计数器 | 宽度 | 触发条件 |
|---|---|---|
| `exc_nan_cnt` | 16 | 任何 lane 输出 NaN |
| `exc_inf_cnt` | 16 | 任何 lane 输出 Inf |
| `exc_ovf_cnt` | 16 | 任何 lane 发生溢出 |
| `exc_udf_cnt` | 16 | 任何 lane 发生下溢 |
| `exc_denorm_cnt` | 16 | 任何 lane 输入为 DENORM |

## 6. Test/Debug Modes (Internal Documentation)

### 6.1. Debug 模式

| 模式 | 编码 | 功能 |
|---|---|---|
| `force_bypass_c` | DEBUG_PP_MODE[0] | 强制 add_c 旁路 |
| `force_round_mode` | DEBUG_PP_MODE[1] | 固定 RNE 进行回归 |
| `force_exception` | DEBUG_PP_MODE[2] | 注入特殊值序列 |

### 6.2. 测试模式数据流

1. `force_bypass_c`：跳过 C 输入，直接 acc→round
2. `force_round_mode`：忽略 `round_mode` 配置，固定 RNE
3. `force_exception`：在 acc_data/c_data 中注入 NaN/Inf/DENORM 序列，验证异常处理

## 7. Architecture Descriptions (Internal Documentation)

### 7.1. Architecture Overview

后处理采用 2~3 级流水线，每级 1 个周期：

| Stage | 功能 | 数据格式 | 模块 |
|---|---|---|---|
| Stage0 | 输入对齐、mask 应用 | FP32 | postproc_ctrl |
| Stage1 | FP32 加法（acc + C） | FP32 | fp_add_c |
| Stage2 | FP32→FP16 转换 | FP16 | fp_round_sat |

旁路时 Stage1 直通。所有 stage 共享 `clk` 和 `rst_n`。

### 7.2. Clocks and Resets

- 主时钟：`clk`（与 systolic_core、d_storer 同频）
- 异步低有效复位：`rst_n`
- 复位行为：
  - 所有流水线 valid 清零
  - 异常计数器清零
  - `pp_busy`/`pp_done`/`pp_err` 清零
  - 配置上下文重置为默认值

### 7.3. Handshake Protocol

每级采用 valid/ready 握手：
- **前向**：`valid_out = stage_valid && (!next_stage_valid || next_stage_ready)`
- **反压**：`ready_out = !next_stage_valid || next_stage_ready`
- **Stall**：当下级未 ready 时，本级保持数据不变

```text
        stageN_valid ──────> stageN+1_valid
        stageN_ready <────── stageN+1_ready
        stageN_data  ──────> stageN+1_data
```

### 7.4. C 数据对齐策略

当 `add_c_en=1` 时：
1. `postproc` 接收 `acc_valid` 后检查 `c_valid`
2. 若 `c_valid=0`，stall Stage0 直到 C 数据到达
3. `c_last` 必须与 `acc_last` 同拍或提前到达
4. 若 `c_last` 晚于 `acc_last`，视为协议错误，置位 `pp_err`

### 7.5. Mask 处理

`tile_mask`（LANES-bit）定义：
- `mask[lane]=1`：该 lane 正常处理
- `mask[lane]=0`：该 lane 输出强制为 0，不计入异常统计

Mask 在 Stage0 应用，贯穿 Stage1→Stage2。

### 7.6. Exception Flag Propagation

per-lane 异常标志：`exc_flags[lane][4:0]`

| 位 | 名称 | 含义 |
|---|---|---|
| 4 | NaN | 输出为 NaN |
| 3 | Inf | 输出为 Inf |
| 2 | OVF | 发生溢出 |
| 1 | UDF | 发生下溢 |
| 0 | DENORM | 输入为非正规数 |

异常统计仅在 `lane_mask=1` 时累加。

## 8. Integration Guide (Internal Documentation)

### 8.1. 与 systolic_core 对接

```text
systolic_core.acc_out_valid ──> postproc.acc_valid
systolic_core.acc_out_data  ──> postproc.acc_data[LANES*ACC_W-1:0]
systolic_core.acc_out_last   ──> postproc.acc_last
```

- `acc_out_valid` 在 systolic_core COMMIT 状态产生单拍脉冲
- `acc_out_data` 为 FP32 格式（P_M*P_N 个累加器扁平化）
- `acc_out_last` 标识 tile 最后一个输出（单 tile 时恒为 1）

### 8.2. 与 c_loader / C_BUF 对接

```text
c_loader.c_valid ──> postproc.c_valid
postproc.c_ready  ──> c_loader.c_ready
c_loader.c_data   ──> postproc.c_data[LANES*ELEM_W-1:0]
c_loader.c_last   ──> postproc.c_last
```

- C tile 数据为 FP16 格式，与 acc 输出 lane 对齐
- `c_ready` 由 postproc 反压控制

### 8.3. 与 d_storer 对接

```text
postproc.d_valid ──> d_storer.post_valid
postproc.d_data  ──> d_storer.post_data[LANES*ELEM_W-1:0]
postproc.d_last  ──> d_storer.post_last
d_storer.post_ready ──> postproc.d_ready
```

- 输出 FP16 格式，lane 顺序与 systolic_core PE 阵列一致
- `d_last` 标识 tile 最后输出

## 9. Implementation Guide (Internal Documentation)

### 9.1. 建议实现步骤

1. **Phase 1**：实现 `fp_round_sat` 独立模块 + testbench
   - 验证正常值转换精度（与软件黄金模型比对，误差 ≤ 0.5 ULP）
   - 验证 4 种 round mode
   - 验证 NaN/Inf/overflow/underflow/DENORM 处理
2. **Phase 2**：实现 `fp_add_c` 独立模块 + testbench
   - 验证 FP32 加法（旁路模式和融合模式）
   - 验证 C 数据 FP16→FP32 扩展
   - 验证 lane mask 和异常检测
3. **Phase 3**：封装 `postproc` 顶层
   - 连接 Stage0→Stage1→Stage2 流水线
   - 实现 valid/ready 握手与反压
   - 实现配置锁存、异常计数、debug 模式
4. **Phase 4**：集成验证
   - 与 `systolic_core` + `d_storer` 联合测试
   - 端到端单 tile 测试（A×B + C → D）

### 9.2. RTL 编码要点

- 所有时序逻辑使用 `always_ff @(posedge clk or negedge rst_n)`
- 组合逻辑使用 `always_comb`
- FP32→FP16 转换使用组合逻辑（Stage2 纯组合或单周期寄存）
- 异常检测使用组合逻辑，计数器使用时序逻辑
- 流水线 valid 信号使用寄存器，数据使用寄存器
- Verilator 兼容：避免 `always_ff` 内嵌 `int` 声明

### 9.3. 数值参考

FP16 关键常量（用于饱和和边界检查）：

| 值 | FP16 编码 | 说明 |
|---|---|---|
| +max | 0x7BFF | 最大正规数 ≈ 65504 |
| -max | 0xFBFF | 最小正规数 ≈ -65504 |
| +Inf | 0x7C00 | 正无穷 |
| -Inf | 0xFC00 | 负无穷 |
| QNaN | 0x7E00 | 静默 NaN |
| SNaN | 0x7D00 | 信号 NaN（最小） |

FP32→FP16 转换黄金模型（Python）：
```python
import numpy as np

def fp32_to_fp16_rne(x):
    """Round FP32 to FP16 using RNE"""
    return np.float16(x)  # numpy 默认 RNE
```

## 10. Verification Guide (Internal Documentation)

### 10.1. 功能用例

| 用例 | 描述 | 通过标准 |
|---|---|---|
| T1: bypass | add_c_en=0，acc 直通 | d_data == acc（精度转换后） |
| T2: add_c | add_c_en=1，acc + C | 与软件模型比对，误差 ≤ 0.5 ULP |
| T3: round modes | 4 种 round mode | 与 numpy 对应模式比对 |
| T4: NaN/Inf | 注入 NaN/Inf | 按策略正确处理，计数器累加 |
| T5: overflow | 输入 > FP16 max | sat_en=1 时饱和，sat_en=0 时 Inf |
| T6: underflow | 输入 < FP16 min | flush to zero，计数器累加 |
| T7: DENORM | 输入 FP32 DENORM | flush to zero，计数器累加 |
| T8: mask | tile_mask 部分 lane=0 | 无效 lane 输出 0，不计异常 |
| T9: backpressure | d_ready 拉低 | 流水线 stall，数据不丢失 |
| T10: reset | rst_n 断言 | 流水线清零，计数器清零 |

### 10.2. 时序用例

| 用例 | 描述 |
|---|---|
| T11: c_late | C 数据晚于 acc 到达 | Stall 等待，不丢数据 |
| T12: c_early | C 数据早于 acc 到达 | 缓冲或丢弃策略 |
| T13: reset_during_flush | flush 阶段 reset | 不输出半拍数据 |
| T14: multi-tile | 连续多个 tile | 配置上下文正确切换 |

### 10.3. 覆盖率目标

- 行覆盖率 > 95%
- 舍入模式覆盖：4 种模式全部测试
- 异常类型覆盖：NaN/Inf/OVF/UDF/DENORM 全部触发
- 状态机覆盖：IDLE/ALIGN/PROCESS/FLUSH/DONE 全部路径
- 交叉覆盖：round_mode × sat_en × add_c_en

## 11. Registers

建议 CSR 寄存器：

### 11.1. PP_CTRL (RW)

| 位 | 名称 | 默认值 | 说明 |
|---|---|---|---|
| 0 | `pp_en` | 0 | 后处理使能 |
| 1 | `add_c_en` | 0 | C 融合使能 |
| 2 | `sat_en` | 1 | 饱和使能 |
| 3 | `pp_start` | 0 | 启动脉冲（W1P） |

### 11.2. PP_CFG0 (RW)

| 位 | 名称 | 默认值 | 说明 |
|---|---|---|---|
| 1:0 | `round_mode` | 2'b00 | 00=RNE, 01=RTZ, 10=RUP, 11=RDN |
| 4:2 | `nan_policy` | 3'b000 | NaN 处理策略 |
| 7:5 | `inf_policy` | 3'b000 | Inf 处理策略 |

### 11.3. PP_STATUS (RO)

| 位 | 名称 | 说明 |
|---|---|---|
| 0 | `pp_busy` | 后处理忙 |
| 1 | `pp_done` | 后处理完成（W1C） |
| 2 | `pp_err` | 协议错误 |

### 11.4. PP_ERR_CODE (RO)

| 位 | 名称 | 说明 |
|---|---|---|
| 0 | `protocol_align_err` | acc/C 对齐错误 |
| 1 | `illegal_mode` | 非法 round_mode |

### 11.5. 异常计数器 (RO, W1C)

| 地址偏移 | 名称 | 说明 |
|---|---|---|
| 0x10 | `PP_NAN_CNT` | NaN 计数 |
| 0x14 | `PP_INF_CNT` | Inf 计数 |
| 0x18 | `PP_OVF_CNT` | 溢出计数 |
| 0x1C | `PP_UDF_CNT` | 下溢计数 |
| 0x20 | `PP_DENORM_CNT` | 非正规数计数 |

## 12. Reference (Internal Documentation)

- `ARCHITECTURE.md`
- `spec/modules.md`
- `spec/systolic_compute_core_spec.md`
- `spec/onchip_buffer_reorder_spec.md`
- `rtl/systolic_core.sv`
- `rtl/d_storer.sv`
- `rtl/pe_cell.sv`

## 13. Open Issues & Workaround (Internal Documentation)

1. **Open Issue**: C 流偶发迟到导致后处理停顿。  
   **Workaround**: 增加输入对齐 FIFO 深度或优先预取 C。MVP 阶段通过 stall 等待处理。
2. **Open Issue**: 极端数据下异常计数过多影响观测开销。  
   **Workaround**: 支持采样计数或窗口计数模式。MVP 阶段使用 16-bit sticky 计数器。
3. **Open Issue**: 多模式支持导致控制复杂。  
   **Workaround**: MVP 固化 RNE+sat+bypass 支持，仅保留最小配置开关。完整模式在 M3 阶段补齐。
4. **Open Issue**: FP32→FP16 转换精度与 hardened IP 差异。  
   **Workaround**: 使用软件黄金模型（numpy）作为参考，RTL 实现组合逻辑转换，允许 ≤ 0.5 ULP 误差。
