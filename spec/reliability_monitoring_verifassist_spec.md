# Reliability, Monitoring & Verification-Assist Module Spec (Internal)

## 1. Revision History (Internal Documentation)

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1 | 2026-04-30 | Codex | Initial draft for reliability/monitoring/verification-assist modules (`err_checker/perf_counter/trace_debug_if`). |

## 2. Terms/Abbreviations

- ECC: Error Correcting Code
- Parity: 奇偶校验
- SBE/DBE: Single-Bit Error / Double-Bit Error
- CSR: Control and Status Register
- IRQ: Interrupt Request
- W1C: Write-1-to-Clear
- TO: Timeout
- KPI: Key Performance Indicator
- Trace: 运行时状态导出信息

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
- 周期/吞吐/等待类性能计数器
- 可选 trace 导出（状态机、tile 索引、stall 原因）
- 支持计数器快照、冻结与清零
- 支持事件触发中断（done/err/threshold）

## 4. Port List and Parameters (Internal Documentation)

### 4.1 `err_checker`

- Input
  - `clk`, `rst_n`
  - `cfg_dim_*`, `cfg_addr_*`, `cfg_stride_*`, `cfg_tile_*`
  - `axi_rresp`, `axi_bresp`, `axi_timeout_evt`
  - `fsm_state`, `req_meta`
- Output
  - `err_valid`, `err_code`, `err_addr`, `err_src`
  - `fatal_err`, `warn_err`

### 4.2 `perf_counter`

- Input
  - `clk`, `rst_n`
  - `core_busy`, `core_active`, `dma_wait`, `wr_wait`
  - `axi_rd_beat`, `axi_wr_beat`
  - `snap_req`, `clr_req`, `freeze_req`
- Output
  - `cycle_total`, `cycle_compute`, `cycle_dma_wait`
  - `axi_rd_bytes`, `axi_wr_bytes`
  - `stall_reason_cnt[*]`

### 4.3 `trace_debug_if` (Optional)

- Input: `state_idx`, `tile_idx_m/n/k`, `stall_code`, `timestamp`
- Output: `trace_valid`, `trace_data`, `trace_overflow`

### 4.4 Key Parameters

- `ERR_CODE_W` (default 16)
- `PERF_CNT_W` (default 64)
- `TRACE_W` (default 128)
- `TRACE_FIFO_DEPTH` (default 256)
- `TIMEOUT_CYCLES` (default configurable)

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

### 7.5. Sub-Module XXX_CTL (Optional)

`XXX_CTL` 对应监控控制器（err/perf/trace 协调）。

### 7.5.1. Overview

- 负责事件路由、优先级仲裁、寄存器可见性控制

### 7.5.2. Sub-Module XXX_RDCTL

#### 7.5.2.1. Overview

- 负责采集读路径相关事件（如 rd_wait、rresp_err）

#### 7.5.2.2. Logic Design

- 捕获 `rresp` 异常并映射错误码
- 按周期累计 `rd_wait` 时长
- 将事件时间戳压入 trace FIFO（可选）

### 7.5.3.  Sub-Module XXX_WRCTL

#### 7.5.3.1. Overview

- 负责采集写路径相关事件（如 wr_wait、bresp_err）

#### 7.5.3.2. Logic Design

- 捕获 `bresp` 异常并映射错误码
- 统计 `axi_wr_bytes` 与写等待周期
- 触发阈值中断（可选）

### 7.5.4.  Logic Design

建议状态机：
`IDLE -> MONITOR -> LATCH_ERR -> REPORT -> RESUME`

### 7.6. Sub-Module XXX_DP (Optional)

- 错误码组合 datapath
- 计数器加法器 datapath
- trace 打包 datapath（state/tile/time/stall）

### 7.7. Sub-Module XXX_MEM(Optional)

- 错误锁存寄存器组
- 64-bit 计数器阵列
- trace FIFO（可选）

### 7.8. Logic Design (Optional)

错误优先级建议：
1. `fatal protocol error`
2. `address/range error`
3. `timeout error`
4. `warning-level perf anomaly`

计数器建议采用饱和计数，溢出置 `cnt_ovf` 标志。

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

## 10. Verification Guide (Internal Documentation)

- 功能测试：
  - 地址未对齐、越界、非法维度
  - RRESP/BRESP 异常映射
  - done/err IRQ 行为
- 计数测试：
  - 周期/字节计数准确性
  - freeze/snapshot/clear 时序
- 调试测试：
  - trace FIFO 溢出与回读一致性
  - 错误注入路径
- 覆盖建议：
  - 错误码覆盖
  - stall 原因覆盖
  - 计数器边界（接近溢出）覆盖

## 11. Registers

建议寄存器：
- `MON_CTRL`
  - bit0 `mon_en`
  - bit1 `trace_en`
  - bit2 `freeze_cnt`
- `ERR_MASK`
- `ERR_STATUS`
  - `err_valid`, `fatal_err`, `warn_err`
- `ERR_CODE`
- `ERR_ADDR`
- `PERF_CYCLE_TOTAL`
- `PERF_CYCLE_COMPUTE`
- `PERF_CYCLE_DMA_WAIT`
- `PERF_AXI_RD_BYTES`
- `PERF_AXI_WR_BYTES`
- `TRACE_STATUS`
  - `trace_level`, `trace_ovf`

## 12. Reference (Internal Documentation)

- `ARCHITECTURE.md`
- `spec/modules.md`
- `spec/dma_axi_access_spec.md`
- `spec/systolic_compute_core_spec.md`
- `spec/postprocess_numeric_spec.md`

## 13. Open Issues & Workaround (Internal Documentation)

1. **Open Issue**: 错误事件高峰期可能淹没 trace FIFO。  
   **Workaround**: 启用采样/过滤并提高 FIFO 深度。
2. **Open Issue**: 计数器过多增加读写负担。  
   **Workaround**: 提供分组快照寄存器与按需启用。
3. **Open Issue**: 不同模块错误码定义易漂移。  
   **Workaround**: 维护统一错误码字典并在 RTL lint 阶段检查。
