# Postprocess & Numeric Module Spec (Internal)

## 1. Revision History (Internal Documentation)

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1 | 2026-04-30 | Codex | Initial draft for postprocess and numeric modules (`postproc/fp_add_c/fp_round_sat`). |

## 2. Terms/Abbreviations

- Postproc: Post-processing stage after systolic accumulation
- RNE: Round to Nearest, ties to Even
- SAT: Saturation
- DENORM: Subnormal number
- NaN: Not a Number
- Inf: Infinity
- ULP: Unit in the Last Place
- Bypass: 旁路模式（不执行某功能）

## 3. Overview

本规格定义 GEMM 后处理与数值模块，覆盖：
- `postproc`
- `fp_add_c`
- `fp_round_sat`

目标：将计算核心输出的累加结果与 `C` 融合，执行舍入/饱和/异常值策略，并输出写回格式一致的 `D` 数据流。

### 3.1. Block Diagram

```text
        from systolic_core (acc)
                 |
                 v
        +-------------------+
        | postproc          |
        | ctrl + pipeline   |
        +---------+---------+
                  |
        +---------+---------+
        | fp_add_c          | <---- optional C tile stream
        | add / bypass      |
        +---------+---------+
                  |
        +---------+---------+
        | fp_round_sat      |
        | round + sat + exc |
        +---------+---------+
                  |
                  v
             to d_storer
```

### 3.2. Features

- 支持 `acc + C` 融合与 C 旁路
- 支持 FP32->FP16 转换（默认）
- 支持舍入模式配置（默认 RNE）
- 支持溢出饱和、NaN/Inf 处理策略统一
- 支持边界 mask 下 lane 级抑制
- 支持统计计数（overflow/denorm/nan/inf）

## 4. Port List and Parameters (Internal Documentation)

### 4.1 `postproc`

- Input
  - `clk`, `rst_n`
  - `pp_start`, `pp_mode`
  - `acc_valid`, `acc_data`, `acc_last`, `acc_mask`
  - `c_valid`, `c_data`, `c_last`
- Output
  - `d_valid`, `d_data`, `d_last`, `d_mask`
  - `pp_busy`, `pp_done`, `pp_err`

### 4.2 `fp_add_c`

- Input: `x_valid`, `x_data`(acc), `c_valid`, `c_data`, `add_en`
- Output: `y_valid`, `y_data`, `add_exc`

### 4.3 `fp_round_sat`

- Input: `in_valid`, `in_data`, `round_mode`, `sat_en`
- Output: `out_valid`, `out_data_fp16`, `num_exc_flags`

### 4.4 Key Parameters

- `ACC_W` (default 32)
- `OUT_W` (default 16)
- `LANES` (default aligned to `P_N`)
- `ROUND_MODE_DFT` (default RNE)
- `SAT_EN_DFT` (default 1)
- `NAN_POLICY` (default quiet-NaN propagate)

## 5. Functional Descriptions

### 5.1. Normal Function

1. `postproc` 接收 `acc` 向量与可选 `C` 向量
2. `fp_add_c` 执行 `acc + C` 或旁路 `acc`
3. `fp_round_sat` 将内部精度转换为输出精度
4. 根据策略处理 NaN/Inf/overflow/underflow
5. 输出 `d_valid/d_last` 给 `d_storer`

### 5.1.1. Configuration Methods(Optional)

建议可配置项：
- `add_c_en`（开启/关闭 C 融合）
- `round_mode`（RNE/RTZ/RUP/RDN）
- `sat_en`
- `nan_policy`、`inf_policy`

### 5.2. Diagnostic Function(Optional)

建议导出：
- `nan_cnt`, `inf_cnt`, `overflow_cnt`, `underflow_cnt`
- `bypass_cnt`（C 旁路次数）
- `stall_cnt`（等待 C 或下游 backpressure）

### 5.2.1. Configuration Methods(Optional)

- `DEBUG_PP_CTRL`：
  - `dbg_hold_output`
  - `dbg_force_nan`

## 6. Test/Debug Modes (Internal Documentation)

- `force_bypass_c_mode`：强制走 `acc` 旁路
- `force_round_mode`：固定舍入模式进行一致性回归
- `force_exception_mode`：注入特殊值序列

### 6.1.1. Configuration Methods

- `DEBUG_PP_MODE[0]`：force_bypass_c
- `DEBUG_PP_MODE[1]`：force_round_mode
- `DEBUG_PP_MODE[2]`：force_exception

## 7. Architecture Descriptions (Internal Documentation)

### 7.1. Architecture Overview

后处理路径采用 2~3 级流水：
- Stage0：输入对齐与 mask 应用
- Stage1：`fp_add_c`
- Stage2：`fp_round_sat`

若启用旁路，Stage1 可直通。

### 7.2. Clocks and Resets

- 主时钟：`clk`
- 异步低有效复位：`rst_n`
- 复位行为：流水 valid 清零、状态计数清零、`done` 拉低

### 7.2.1. Clock and Reset Description / Logic Circuit (Optional)

- 每级 stage 采用 `valid/ready` 反压协议
- `pp_start` 仅在 idle 接收，锁存配置上下文

### 7.2.2. CDC Synchronization Scheme (Optional)

若与上游/下游异频：
- 输入输出各放置 async FIFO
- 异常计数寄存器跨域读取采用快照握手

### 7.2.3. RDC Synchronization Scheme (Optional)

- `pp_done` 电平保持至 CSR 读/清
- reset 中断后丢弃未完成 vector，防止半拍数据提交

### 7.3. Top Main Interfaces (Optional)

- 上游：`systolic_core`（acc 流）与 `c_loader`（C 流）
- 下游：`d_storer`
- 控制：`tile_scheduler/csr_if`

### 7.4. Architecture Scheme Comparison (Optional)

- 方案 A：向量并行后处理（lane-wise）
  - 优点：吞吐高，与阵列带宽匹配
  - 缺点：面积较大
- 方案 B：标量时分后处理
  - 优点：面积小
  - 缺点：吞吐受限，易成瓶颈

建议：默认采用方案 A。

### 7.5. Sub-Module XXX_CTL (Optional)

`XXX_CTL` 对应 `postproc` 控制子模块。

### 7.5.1. Overview

- 负责输入对齐、模式选择、流水推进、完成上报

### 7.5.2. Sub-Module XXX_RDCTL

#### 7.5.2.1. Overview

- 管理 acc/C 输入接收与同步对齐

#### 7.5.2.2. Logic Design

- 当 `add_c_en=1`：要求 `acc_valid && c_valid` 才推进
- 当 `add_c_en=0`：仅 `acc_valid` 推进并计 `bypass_cnt`
- mask lane 在进入 Stage1 前可置零/保留（按策略）

### 7.5.3.  Sub-Module XXX_WRCTL

#### 7.5.3.1. Overview

- 管理后处理结果输出与反压处理

#### 7.5.3.2. Logic Design

- `out_ready=0` 时保持 stage valid 与数据不变
- `d_last` 与 tile 结束对齐传播
- 异常 flags 与数据同拍绑定输出

### 7.5.4.  Logic Design

建议状态机：
`IDLE -> ALIGN -> PROCESS -> FLUSH -> DONE`

### 7.6. Sub-Module XXX_DP (Optional)

- 数值 datapath：add、round、sat
- 异常检测 datapath：NaN/Inf/overflow/underflow
- mask datapath：lane 级裁剪

### 7.7. Sub-Module XXX_MEM(Optional)

- 可选输入对齐 FIFO
- 可选输出 skid buffer
- 统计计数器寄存器组

### 7.8. Logic Design (Optional)

数值策略建议：
1. `sum = add_c_en ? (acc + c) : acc`
2. 若 `isNaN(sum)`：按 `nan_policy` 输出 quiet-NaN
3. 若 `isInf(sum)`：按 `inf_policy` 透传/饱和
4. 正常值：按 `round_mode` 转 FP16，溢出按 `sat_en` 处理

### 7.9. Low Power Design (Optional)

- lane mask=0 时关闭对应 lane 运算翻转
- 长时间 bypass 时可关停 `fp_add_c` 局部时钟
- debug 模式关闭后门控异常探针逻辑

### 7.10. Architecture Open Issues (Optional)

- 非正规数（DENORM）是 flush-to-zero 还是保留
- NaN payload 是否保真透传
- 是否支持 BF16 输出模式（当前未纳入 MVP）

## 8. Integration Guide (Internal Documentation)

- 与 `systolic_core`：统一 `acc_last` 与 tile 边界语义
- 与 `c_loader`：明确 C 流有效性与对齐策略
- 与 `d_storer`：统一输出端序和短包 mask 语义

## 9. Implementation Guide (Internal Documentation)

建议实现步骤：
1. 先实现 `fp_round_sat`（独立可测）
2. 接入 `fp_add_c` 和 bypass 模式
3. 封装 `postproc` 控制与 backpressure
4. 添加异常计数和 debug 模式

## 10. Verification Guide (Internal Documentation)

- 功能用例：
  - `acc + C` 与 bypass 两路径
  - 正常值、边界值、特殊值（NaN/Inf/subnormal）
  - 多种 round mode 对比软件黄金模型
- 时序用例：
  - 输入不同步到达（acc 早于 C）
  - 下游 backpressure
  - reset during flush
- 覆盖建议：
  - 模式覆盖（add/bypass、round mode）
  - 异常类型覆盖
  - 状态机路径覆盖

## 11. Registers

建议寄存器：
- `PP_CTRL`
  - bit0 `pp_en`
  - bit1 `add_c_en`
  - bit2 `sat_en`
- `PP_CFG0`
  - bit1:0 `round_mode`
  - bit4:2 `nan_policy`
  - bit7:5 `inf_policy`
- `PP_STATUS`
  - `pp_busy`, `pp_done`
- `PP_ERR_CODE`
  - bit0 `protocol_align_err`
  - bit1 `illegal_mode`
- `PP_NUM_NAN_CNT`
- `PP_NUM_INF_CNT`
- `PP_NUM_OVF_CNT`
- `PP_NUM_UDF_CNT`

## 12. Reference (Internal Documentation)

- `ARCHITECTURE.md`
- `spec/modules.md`
- `spec/systolic_compute_core_spec.md`
- `spec/onchip_buffer_reorder_spec.md`

## 13. Open Issues & Workaround (Internal Documentation)

1. **Open Issue**: C 流偶发迟到导致后处理停顿。  
   **Workaround**: 增加输入对齐 FIFO 深度或优先预取 C。
2. **Open Issue**: 极端数据下异常计数过多影响观测开销。  
   **Workaround**: 支持采样计数或窗口计数模式。
3. **Open Issue**: 多模式支持导致控制复杂。  
   **Workaround**: MVP 固化 RNE+sat，仅保留最小配置开关。
