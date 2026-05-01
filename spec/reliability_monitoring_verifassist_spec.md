# Reliability, Monitoring & Verification-Assist Module Spec (Internal)

## 1. Revision History (Internal Documentation)

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1 | 2026-04-30 | Codex | Initial draft for reliability/monitoring/verification-assist modules (`err_checker/perf_counter/trace_debug_if`). |
| v0.2 | 2026-05-02 | Digital Design | Complete port lists, FSM, logic design, and register map. |

## 2. Terms/Abbreviations

- ECC: Error Correcting Code
- Parity: 奇偶校验
- SBE/DBE: Single-Bit Error / Double-Bit Error
- CSR: Control and Status Register
- IRQ: Interrupt Request
- W1C: Write-1-to-Clear
- W1P: Write 1 Pulse
- TO: Timeout
- KPI: Key Performance Indicator
- Trace: 运行时状态导出信息
- UVM: Universal Verification Methodology

## 3. Overview

本规格定义“可靠性、监控与验证辅助”模块，覆盖：
- `err_checker`
- `perf_counter`
- `trace_debug_if`（可选）

目标：统一错误检测上报、性能统计与可观测调试导出，支撑 bring-up、性能调优与回归验证闭环。

### 3.1. Block Diagram

```text
                      +----------------------+
                      |   tile_scheduler     |
                      +----+-------------+---+
                           |             |
                 status/evt|             |fsm_idx
                           v             v
                +----------------+   +----------------+
                | err_checker    |   | trace_debug_if |
                | addr/resp/prot |   | state export   |
                +-------+--------+   +--------+-------+
                        |                     |
                        +----------+----------+
                                   |
                                   v
                           +---------------+
                           | perf_counter  |
                           | cycles/bytes  |
                           +-------+-------+
                                   |
                                   v
                               csr_if/irq
```

### 3.2. Features

- 地址对齐、维度合法性、越界与协议响应错误检查
- 错误事件分类与 `err_code` 聚合上报
- 周期/吞吐/等待类性能计数器（64-bit）
- 可选 trace 导出（状态机、tile 索引、stall 原因）
- 支持计数器快照、冻结与清零
- 支持事件触发中断（done/err/threshold）
- 支持错误注入与自检模式（验证辅助）

## 4. Port List and Parameters (Internal Documentation)

### 4.1 `err_checker`

#### 4.1.1 Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `ADDR_W` | int | 64 | 地址位宽 |
| `DIM_W` | int | 16 | 维度位宽 |
| `STRIDE_W` | int | 32 | stride 位宽 |
| `TILE_W` | int | 16 | tile 尺寸位宽 |
| `ERR_CODE_W` | int | 16 | 错误码位宽 |
| `TIMEOUT_CYCLES` | int | 1000000 | 默认超时周期 |

#### 4.1.2 Port List

**时钟复位**

| `clk` | Input | 1 | 主时钟 |
| `rst_n` | Input | 1 | 异步低有效复位 |

**配置检查输入**

| `chk_valid` | Input | 1 | 检查触发（start 时） |
| `cfg_m` | Input | DIM_W | M 维度 |
| `cfg_n` | Input | DIM_W | N 维度 |
| `cfg_k` | Input | DIM_W | K 维度 |
| `cfg_tile_m` | Input | TILE_W | Tm |
| `cfg_tile_n` | Input | TILE_W | Tn |
| `cfg_tile_k` | Input | TILE_W | Tk |
| `cfg_addr_a` | Input | ADDR_W | A 地址 |
| `cfg_addr_b` | Input | ADDR_W | B 地址 |
| `cfg_addr_c` | Input | ADDR_W | C 地址 |
| `cfg_addr_d` | Input | ADDR_W | D 地址 |
| `cfg_stride_a` | Input | STRIDE_W | A stride |
| `cfg_stride_b` | Input | STRIDE_W | B stride |
| `cfg_stride_c` | Input | STRIDE_W | C stride |
| `cfg_stride_d` | Input | STRIDE_W | D stride |

**运行时事件输入**

| `axi_rresp` | Input | 2 | AXI RRESP |
| `axi_rresp_valid` | Input | 1 | RRESP 有效 |
| `axi_bresp` | Input | 2 | AXI BRESP |
| `axi_bresp_valid` | Input | 1 | BRESP 有效 |
| `fsm_state` | Input | 8 | tile_scheduler 状态 |
| `fsm_err` | Input | 1 | scheduler 错误 |
| `core_err` | Input | 1 | core 错误 |
| `pp_err` | Input | 1 | postproc 错误 |
| `timeout_evt` | Input | 1 | 外部超时事件 |

**错误输出**

| `err_valid` | Output | 1 | 错误有效脉冲 |
| `err_code` | Output | ERR_CODE_W | 错误码 |
| `err_addr` | Output | ADDR_W | 错误地址 |
| `err_src` | Output | 8 | 错误源 |
| `fatal_err` | Output | 1 | 致命错误 |
| `warn_err` | Output | 1 | 警告错误 |

### 4.2 `perf_counter`

#### 4.2.1 Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `PERF_CNT_W` | int | 64 | 计数器位宽 |
| `NUM_STALL_REASONS` | int | 8 | stall 原因数量 |
| `AXI_DATA_W` | int | 256 | AXI 数据位宽 |

#### 4.2.2 Port List

**时钟复位**

| `clk` | Input | 1 | 主时钟 |
| `rst_n` | Input | 1 | 异步低有效复位 |

**控制**

| `cnt_start` | Input | 1 | 计数器启动（scheduler 发出） |
| `cnt_stop` | Input | 1 | 计数器停止 |
| `cnt_clear` | Input | 1 | 计数器清零（W1P） |
| `cnt_freeze` | Input | 1 | 冻结计数 |
| `snap_req` | Input | 1 | 快照请求 |

**事件输入**

| `core_busy` | Input | 1 | 计算忙碌 |
| `core_active` | Input | 1 | 计算活跃（有有效 MAC） |
| `dma_rd_wait` | Input | 1 | DMA 读等待 |
| `dma_wr_wait` | Input | 1 | DMA 写等待 |
| `axi_rd_beat` | Input | 1 | AXI 读 beat |
| `axi_wr_beat` | Input | 1 | AXI 写 beat |
| `stall_reason` | Input | NUM_STALL_REASONS | stall 原因向量 |

**计数器输出**

| `cycle_total` | Output | PERF_CNT_W | 总周期 |
| `cycle_compute` | Output | PERF_CNT_W | 计算周期 |
| `cycle_dma_wait` | Output | PERF_CNT_W | DMA 等待周期 |
| `axi_rd_bytes` | Output | PERF_CNT_W | AXI 读字节 |
| `axi_wr_bytes` | Output | PERF_CNT_W | AXI 写字节 |
| `stall_reason_cnt` | Output | NUM_STALL_REASONS*PERF_CNT_W | stall 原因计数 |
| `snap_valid` | Output | 1 | 快照有效 |

### 4.3 `trace_debug_if` (Optional)

#### 4.3.1 Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `TRACE_W` | int | 128 | trace 数据位宽 |
| `TRACE_FIFO_DEPTH` | int | 256 | FIFO 深度 |
| `TILE_W` | int | 16 | tile 索引位宽 |

#### 4.3.2 Port List

**时钟复位**

| `clk` | Input | 1 | 主时钟 |
| `rst_n` | Input | 1 | 异步低有效复位 |

**控制**

| `trace_en` | Input | 1 | trace 使能 |
| `trace_freeze` | Input | 1 | trace 冻结 |
| `trace_clr` | Input | 1 | trace 清零 |

**事件输入**

| `fsm_state` | Input | 8 | 状态机状态 |
| `tile_idx_m` | Input | TILE_W | tile m 索引 |
| `tile_idx_n` | Input | TILE_W | tile n 索引 |
| `tile_idx_k` | Input | TILE_W | tile k 索引 |
| `stall_code` | Input | 8 | stall 原因码 |
| `timestamp` | Input | 64 | 时间戳 |
| `event_valid` | Input | 1 | 事件有效 |

**输出**

| `trace_valid` | Output | 1 | trace 数据有效 |
| `trace_data` | Output | TRACE_W | trace 数据 |
| `trace_ready` | Input | 1 | trace 就绪 |
| `trace_overflow` | Output | 1 | FIFO 溢出 |
| `trace_level` | Output | TRACE_FIFO_DEPTH 位宽 | FIFO 水位 |

## 5. Functional Descriptions

### 5.1. Normal Function

1. `err_checker` 实时监听配置与运行事件
2. 发现错误时锁存 `err_code/err_addr/err_src`
3. `perf_counter` 按周期和事件增量统计 KPI
4. `trace_debug_if`（若启用）导出关键运行轨迹
5. 通过 `csr_if` 暴露状态/计数并可触发 IRQ

### 5.1.1. Configuration Methods(Optional)

建议可配：
- `err_mask`（屏蔽非致命错误）
- `timeout_cycles`
- 计数器 freeze/snapshot 窗口
- trace 采样率与过滤条件

### 5.2. Diagnostic Function(Optional)

- 读取最近错误记录（code/src/addr/time）
- 读取性能计数器快照
- 读取 trace 缓冲水位与溢出标志

### 5.2.1. Configuration Methods(Optional)

- `DEBUG_MON_CTRL`
  - `dbg_err_inject_en`
  - `dbg_trace_freeze`

## 6. Test/Debug Modes (Internal Documentation)

- `force_err_mode`：强制注入指定错误码
- `counter_self_test_mode`：计数器自检增量模式
- `trace_loop_mode`：trace 固定模式循环输出

### 6.1.1. Configuration Methods

- `DEBUG_MON_MODE[0]`：force_err
- `DEBUG_MON_MODE[1]`：counter_self_test
- `DEBUG_MON_MODE[2]`：trace_loop

## 7. Architecture Descriptions (Internal Documentation)

### 7.1. Architecture Overview

该子系统采用“事件采集 + 判定聚合 + 统计/追踪输出”架构：
- 判定聚合：`err_checker`
- 统计：`perf_counter`
- 追踪：`trace_debug_if`

### 7.2. Clocks and Resets

- 主时钟 `clk`
- 异步低有效复位 `rst_n`
- 复位后：
  - 错误锁存清空
  - 计数器清零
  - trace FIFO 清空

### 7.2.1. Clock and Reset Description / Logic Circuit (Optional)

- 错误路径优先级高于性能统计写入
- 计数器在 `freeze=1` 时保持

### 7.2.2. CDC Synchronization Scheme (Optional)

若事件源异频：
- 事件脉冲采用同步器 + 脉冲展宽
- trace 事件可经 async FIFO 跨域

### 7.2.3. RDC Synchronization Scheme (Optional)

- reset 撤销顺序：先事件源后监控域
- `err_valid` 保持至 CSR 侧 W1C

### 7.3. Top Main Interfaces (Optional)

- 上游：scheduler、DMA、compute、postproc
- 下游：csr_if、irq_ctrl、验证环境

### 7.4. Architecture Scheme Comparison (Optional)

- 方案 A：集中式监控（单点聚合）
  - 优点：接口统一，软件简单
  - 缺点：单点拥塞风险
- 方案 B：分布式监控（子模块本地计数）
  - 优点：扩展灵活
  - 缺点：软件聚合复杂

建议：MVP 用方案 A。

### 7.5. Sub-Module `err_checker`

#### 7.5.1. Overview

统一错误检测与上报。

#### 7.5.2. Logic Design

**检查阶段：**

| 阶段 | 检查内容 | 错误码 |
|---|---|---|
| 配置检查 | M/N/K==0, Tm/Tn/Tk==0 | ERR_ILLEGAL_DIM/TILE |
| 配置检查 | addr 未对齐 | ERR_ADDR_ALIGN |
| 配置检查 | stride 未对齐 | ERR_STRIDE_ALIGN |
| 配置检查 | Tm>M/Tn>N/Tk>K | ERR_TILE_OVERSIZE |
| 运行检查 | RRESP!=OKAY | ERR_AXI_RD_RESP |
| 运行检查 | BRESP!=OKAY | ERR_AXI_WR_RESP |
| 运行检查 | FSM 进入 ERR | ERR_FSM |
| 运行检查 | core_err | ERR_CORE |
| 运行检查 | pp_err | ERR_PP |
| 运行检查 | 超时 | ERR_TIMEOUT |

**错误锁存：**

```
if (any_error_detected && !err_mask[err_type]) begin
    err_valid   <= 1'b1;
    err_code    <= err_type;
    err_addr    <= associated_addr;
    err_src     <= error_source_id;
    fatal_err   <= is_fatal;
    warn_err    <= !is_fatal;
end
```

- `err_valid` 保持直到 CSR W1C 清除
- `fatal_err` 导致 scheduler 停止
- `warn_err` 仅记录不停止

**超时检测：**

```
timeout_cnt++ when busy
if (timeout_cnt >= TIMEOUT_CYCLES) begin
    timeout_evt <= 1'b1;
end
```

### 7.6. Sub-Module `perf_counter`

#### 7.6.1. Overview

性能 KPI 统计。

#### 7.6.2. Logic Design

**计数器列表：**

| 计数器 | 触发条件 | 说明 |
|---|---|---|
| `cycle_total` | `cnt_start` 到 `cnt_stop` | 总周期 |
| `cycle_compute` | `core_active` | 有效计算周期 |
| `cycle_dma_wait` | `dma_rd_wait || dma_wr_wait` | DMA 等待 |
| `axi_rd_bytes` | `axi_rd_beat` | 每 beat + AXI_DATA_W/8 |
| `axi_wr_bytes` | `axi_wr_beat` | 每 beat + AXI_DATA_W/8 |
| `stall_reason_cnt[i]` | `stall_reason[i]` | stall 原因计数 |

**计数器控制：**

```
if (cnt_clear) all_counters <= 0;
else if (!cnt_freeze) begin
    if (cnt_started) cycle_total++;
    if (core_active) cycle_compute++;
    if (dma_rd_wait || dma_wr_wait) cycle_dma_wait++;
    // ...
end
```

**快照机制：**

```
if (snap_req) begin
    snap_registers <= counters;
    snap_valid <= 1'b1;
end
```

### 7.7. Sub-Module `trace_debug_if`

#### 7.7.1. Overview

运行时状态追踪导出。

#### 7.7.2. Logic Design

**Trace 包格式（128-bit）：**

| 字段 | 位宽 | 说明 |
|---|---|---|
| `timestamp` | 64 | 时间戳 |
| `fsm_state` | 8 | 状态机状态 |
| `tile_m` | 8 | tile m 索引（截断） |
| `tile_n` | 8 | tile n 索引（截断） |
| `tile_k` | 8 | tile k 索引（截断） |
| `stall_code` | 8 | stall 原因 |
| `event_type` | 8 | 事件类型 |
| `reserved` | 16 | 保留 |

**FIFO 管理：**
- 深度：TRACE_FIFO_DEPTH
- 写使能：`trace_en && event_valid`
- 读使能：`trace_valid && trace_ready`
- 溢出：`trace_overflow` 置位直到清零

**事件过滤：**
- 支持按 `event_type` 过滤（如只记录状态切换）
- 支持按 `stall_code` 过滤（如只记录 DMA 等待）

### 7.8. Data Path Design

#### 7.8.1. 错误数据通路

```
tile_scheduler/DMA/Core/Postproc -> err_checker -> err_valid/code/addr -> csr_if -> IRQ
```

#### 7.8.2. 性能数据通路

```
tile_scheduler/DMA/Core -> perf_counter -> counters -> csr_if -> AXI4-Lite read
```

#### 7.8.3. Trace 数据通路

```
tile_scheduler -> trace_debug_if -> FIFO -> trace_data/valid -> 验证平台/调试器
```

### 7.9. Low Power Design (Optional)

- 空闲阶段门控 trace 打包逻辑
- 关闭 trace 时停用 FIFO 写时钟
- 低功耗模式下性能计数可降采样

### 7.10. Architecture Open Issues (Optional)

- trace 带宽对总线/CSR访问影响评估
- 超时阈值是否需按模块独立配置
- 错误码位宽与软件兼容策略

## 8. Integration Guide (Internal Documentation)

- 与 CSR：统一错误码与计数器地址映射
- 与 IRQ：定义 err/done/threshold 中断优先级
- 与验证平台：统一 trace 解码格式

## 9. Implementation Guide (Internal Documentation)

建议顺序：
1. `err_checker`（基础错误路径）
2. `perf_counter`（基础 KPI）
3. `trace_debug_if`（可选增强）
4. 加入错误注入与自检模式

编码建议：
- 计数器使用显式 64-bit 加法，检查溢出
- 错误锁存使用 `always_ff` 保证单周期脉冲
- trace FIFO 使用标准 dual-port SRAM 模型

## 10. Verification Guide (Internal Documentation)

### 10.1. 功能测试

| 测试 | 描述 |
|---|---|
| T1 | 地址未对齐检测 |
| T2 | 越界检测（M=0） |
| T3 | 非法维度检测 |
| T4 | RRESP/BRESP 异常映射 |
| T5 | done/err IRQ 行为 |

### 10.2. 计数测试

| 测试 | 描述 |
|---|---|
| T6 | 周期/字节计数准确性 |
| T7 | freeze/snapshot/clear 时序 |
| T8 | 计数器溢出处理 |

### 10.3. 调试测试

| 测试 | 描述 |
|---|---|
| T9 | trace FIFO 溢出与回读一致性 |
| T10 | 错误注入路径 |
| T11 | trace 过滤功能 |

### 10.4. 覆盖建议

- 错误码覆盖（全部错误类型）
- stall 原因覆盖
- 计数器边界（接近溢出）覆盖
- trace FIFO 满/空/半满覆盖

## 11. Registers

| 名称 | 偏移 | 类型 | 说明 |
|---|---|---|---|
| `MON_CTRL` | 0x000 | RW | bit0 mon_en, bit1 trace_en, bit2 freeze_cnt |
| `ERR_MASK` | 0x004 | RW | 错误屏蔽位图 |
| `ERR_STATUS` | 0x008 | RO | bit0 err_valid, bit1 fatal_err, bit2 warn_err |
| `ERR_CODE` | 0x00C | RO | 错误码 |
| `ERR_ADDR` | 0x010 | RO | 错误地址（低 32 位） |
| `ERR_ADDR_HI` | 0x014 | RO | 错误地址（高 32 位） |
| `ERR_SRC` | 0x018 | RO | 错误源 |
| `ERR_TIME` | 0x01C | RO | 错误时间戳 |
| `PERF_CYCLE_TOTAL` | 0x020 | RO | 总周期（低 32） |
| `PERF_CYCLE_TOTAL_HI` | 0x024 | RO | 总周期（高 32） |
| `PERF_CYCLE_COMPUTE` | 0x028 | RO | 计算周期（低 32） |
| `PERF_CYCLE_COMPUTE_HI` | 0x02C | RO | 计算周期（高 32） |
| `PERF_CYCLE_DMA_WAIT` | 0x030 | RO | DMA 等待（低 32） |
| `PERF_CYCLE_DMA_WAIT_HI` | 0x034 | RO | DMA 等待（高 32） |
| `PERF_AXI_RD_BYTES` | 0x038 | RO | AXI 读字节（低 32） |
| `PERF_AXI_RD_BYTES_HI` | 0x03C | RO | AXI 读字节（高 32） |
| `PERF_AXI_WR_BYTES` | 0x040 | RO | AXI 写字节（低 32） |
| `PERF_AXI_WR_BYTES_HI` | 0x044 | RO | AXI 写字节（高 32） |
| `PERF_STALL_CNT_0` | 0x050 | RO | stall 原因 0 计数 |
| `PERF_STALL_CNT_1` | 0x054 | RO | stall 原因 1 计数 |
| ... | ... | ... | ... |
| `PERF_STALL_CNT_7` | 0x06C | RO | stall 原因 7 计数 |
| `TRACE_STATUS` | 0x070 | RO | bit0 trace_ovf, bit15:1 trace_level |
| `TRACE_DATA` | 0x074 | RO | trace FIFO 读数据（低 32） |
| `TRACE_DATA_HI` | 0x078 | RO | trace FIFO 读数据（高 32） |
| `DEBUG_MON_CTRL` | 0x080 | RW | bit0 err_inject, bit1 cnt_self_test, bit2 trace_loop |
| `DEBUG_ERR_INJECT` | 0x084 | RW | 注入错误码 |

## 12. Reference (Internal Documentation)

- `ARCHITECTURE.md`
- `spec/modules.md`
- `spec/dma_axi_access_spec.md`
- `spec/systolic_compute_core_spec.md`
- `spec/postprocess_numeric_spec.md`
- `spec/top_system_control_spec.md`

## 13. Open Issues & Workaround (Internal Documentation)

1. **Open Issue**: 错误事件高峰期可能淹没 trace FIFO。  
   **Workaround**: 启用采样/过滤并提高 FIFO 深度。
2. **Open Issue**: 计数器过多增加读写负担。  
   **Workaround**: 提供分组快照寄存器与按需启用。
3. **Open Issue**: 不同模块错误码定义易漂移。  
   **Workaround**: 维护统一错误码字典并在 RTL lint 阶段检查。
