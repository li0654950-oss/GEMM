# Top-Level & System Control Module Spec (Internal)

## 1. Revision History (Internal Documentation)

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1 | 2026-04-30 | Codex | Initial draft for top-level and system-control modules (`gemm_top/csr_if/irq_ctrl/tile_scheduler`). |

## 2. Terms/Abbreviations

- GEMM: General Matrix Multiply (`D = A×B + C`)
- SA: Systolic Array
- CSR: Control and Status Register
- IRQ: Interrupt Request
- DMA: Direct Memory Access
- AXI: Advanced eXtensible Interface
- CDC: Clock Domain Crossing
- RDC: Reset Domain Crossing
- W1C: Write 1 to Clear
- W1P: Write 1 Pulse
- Tm/Tn/Tk: Tile sizes in M/N/K dimensions

## 3. Overview

本规格定义“顶层与系统控制”范围，覆盖：
- `gemm_top`
- `csr_if`
- `irq_ctrl`（可并入 `csr_if`）
- `tile_scheduler`

目标：对外提供可配置、可观测、可中断的 GEMM 控制平面；对内组织 DMA/Buffer/Compute 的 tile 级调度。

### 3.1. Block Diagram

```text
                    +---------------------------+
AXI4-Lite (cfg) --> | csr_if + irq_ctrl         | --> irq_o
                    | CTRL/STATUS/ERR/PERF CSR  |
                    +-------------+-------------+
                                  |
                                  | cfg/status handshake
                                  v
                    +---------------------------+
                    | tile_scheduler            |
                    | m/n/k loops + FSM         |
                    +----+-----------+----------+
                         |           |
                         |           |
                   dma_req|           |compute_ctrl
                         v           v
                     +-------+    +--------+
                     | dma_* |    | SA core|
                     +-------+    +--------+
```

### 3.2. Features

- 支持参数化维度/地址/stride/tile 配置
- 支持 `start/busy/done/irq` 控制闭环
- 支持错误上报（非法维度、地址越界、AXI 错误）
- 支持 tile 级调度和边界 mask
- 支持性能计数器（周期、等待、吞吐字节）

## 4. Port List and Parameters (Internal Documentation)

### 4.1 Top-Level Ports (`gemm_top`)

- `clk`, `rst_n`
- AXI4-Lite Slave:
  - `s_axil_aw*`, `s_axil_w*`, `s_axil_b*`, `s_axil_ar*`, `s_axil_r*`
- AXI4 Master Read/Write to memory:
  - `m_axi_ar*`, `m_axi_r*`, `m_axi_aw*`, `m_axi_w*`, `m_axi_b*`
- `irq_o`

### 4.2 Internal Control Interfaces

- `cfg_*` from `csr_if` to `tile_scheduler`:
  - `cfg_m/n/k`, `cfg_tile_m/n/k`, `cfg_addr_a/b/c/d`, `cfg_stride_a/b/c/d`
- Scheduler outputs:
  - `rd_req_*`, `wr_req_*`, `compute_start`, `compute_done`
- Status returns:
  - `sch_busy`, `sch_done`, `sch_err`, `err_code`, `perf_*`

### 4.3 Key Parameters

- `AXIL_ADDR_W` (default 16)
- `AXI_DATA_W` (default 256)
- `ADDR_W` (default 64)
- `DIM_W` (default 16)
- `STRIDE_W` (default 32)
- `TILE_W` (default 16)

## 5. Functional Descriptions

### 5.1. Normal Function

1. Host 通过 AXI4-Lite 配置 CSR（维度/地址/stride/tile）
2. Host 写 `CTRL.start=1`（W1P）
3. `tile_scheduler` 进入 `busy`，按 `(m0,n0,k0)` 触发 DMA 和计算
4. 全部 tile 完成后置位 `done`，若 `irq_en=1` 拉起中断
5. Host 读取状态/计数器，W1C 清除 `done`

### 5.1.1. Configuration Methods(Optional)

推荐配置顺序：
1. 写 `soft_reset=1`（可选）
2. 写 `DIM_*`
3. 写 `ADDR_*`
4. 写 `STRIDE_*`
5. 写 `TILE_*`
6. 写 `irq_en`
7. 写 `start=1`

### 5.2. Diagnostic Function(Optional)

- 运行中可读 `STATUS`、`ERR_CODE`、`PERF_COUNTER`
- 异常时可读取当前 tile 索引（建议保留 debug CSR）

### 5.2.1. Configuration Methods(Optional)

- 设置 `diag_en`（如实现）后开放额外 debug 视图寄存器

## 6. Test/Debug Modes (Internal Documentation)

- `test_mode`（可选）：强制进入可重复时序路径
- `perf_freeze`（可选）：冻结性能计数器快照

### 6.1.1. Configuration Methods

- 通过 `DEBUG_CTRL` 寄存器写入：
  - bit0 `test_mode_en`
  - bit1 `perf_freeze`

## 7. Architecture Descriptions (Internal Documentation)

### 7.1. Architecture Overview

控制平面由 `csr_if + irq_ctrl + tile_scheduler` 构成，数据平面由 DMA/Buffer/Compute 组成。控制平面仅发请求与收状态，不直接处理矩阵数据。

### 7.2. Clocks and Resets

- 主时钟域：`clk`
- 异步低有效复位：`rst_n`
- 复位后 CSR 清零、状态机回 `IDLE`、中断拉低

### 7.2.1. Clock and Reset Description / Logic Circuit (Optional)

- 所有控制寄存器使用同步释放复位
- `start` 由 W1P 产生单拍脉冲并同步到 scheduler

### 7.2.2. CDC Synchronization Scheme (Optional)

若 DMA/Compute 不同频域：
- 控制信号：双触发器同步
- 请求/响应：valid-ready 握手 + 异步 FIFO（建议）

### 7.2.3. RDC Synchronization Scheme (Optional)

跨复位域信号要求 reset-safe：
- 复位撤销后等待 2~3 拍再开启请求
- done/irq 采用源域锁存 + 目标域同步

### 7.3. Top Main Interfaces (Optional)

- Host 接口：AXI4-Lite CSR
- Memory 接口：AXI4 Read/Write
- Core 接口：`compute_start/compute_done`

### 7.4. Architecture Scheme Comparison (Optional)

- 方案A：`irq_ctrl` 并入 `csr_if`（逻辑简单，推荐）
- 方案B：`irq_ctrl` 独立（扩展性高，门数略增）

### 7.5. Sub-Module XXX_CTL (Optional)

此处 `XXX_CTL` 指 `tile_scheduler`。

### 7.5.1. Overview

- 负责 tile 循环、边界处理、流水并行控制

### 7.5.2. Sub-Module XXX_RDCTL

#### 7.5.2.1. Overview

- 生成 A/B/C 读请求
- 管理 ping-pong 读入目标 buffer

#### 7.5.2.2. Logic Design

- 根据 `(m0,n0,k0)` 与 `stride` 计算本轮读范围
- 若边界 tile，发起裁剪长度

### 7.5.3.  Sub-Module XXX_WRCTL

#### 7.5.3.1. Overview

- 管理 D tile 写回

#### 7.5.3.2. Logic Design

- 在 `k0` 全完成后触发写请求
- 等待 B channel OK 再进入 `NEXT_TILE`

### 7.5.4.  Logic Design

建议 FSM：
`IDLE -> PRECHECK -> LOAD -> COMPUTE -> STORE -> NEXT -> DONE/ERR`

### 7.6. Sub-Module XXX_DP (Optional)

此处 `XXX_DP` 指控制相关 datapath：
- tile index 计数器
- 边界 mask 生成器
- 性能计数累加器

### 7.7. Sub-Module XXX_MEM(Optional)

控制面相关小存储：
- CSR 寄存器组
- Debug/Counter 寄存器组

### 7.8. Logic Design (Optional)

- `start` 仅在 `IDLE` 接受
- 任何错误进入 `ERR` 并保持 `busy=0 done=1 err=1`
- `done` 由 W1C 清除

### 7.9. Low Power Design (Optional)

- `busy=0` 时门控部分计数器时钟
- 空闲阶段关闭可选 debug 路径

### 7.10. Architecture Open Issues (Optional)

- 是否需要多任务命令队列（当前默认单任务）
- `ERR_CODE` 是否扩展为多 bit 位图

## 8. Integration Guide (Internal Documentation)

- 与 SoC 集成时，确保 AXI 地址空间映射连续
- 中断线接入系统中断控制器
- 推荐保留寄存器镜像供驱动层调试

## 9. Implementation Guide (Internal Documentation)

- 先实现 `csr_if + tile_scheduler` 的最小闭环
- 再接入 DMA 与 compute handshake
- 最后补齐异常路径与 debug/perf

## 10. Verification Guide (Internal Documentation)

- CSR 读写：合法/非法地址访问
- 启停流程：start->busy->done
- 异常流程：非法维度、地址未对齐、AXI SLVERR
- 中断流程：`irq_en=0/1` 两种路径
- 计数器：执行前后增量检查

## 11. Registers

| Name | Offset | Type | Description |
|---|---:|---|---|
| CTRL | 0x000 | RW | bit0 start(W1P), bit1 soft_reset, bit2 irq_en |
| STATUS | 0x004 | RW | bit0 busy, bit1 done(W1C), bit2 err |
| ERR_CODE | 0x008 | RO | 错误码 |
| DIM_M | 0x010 | RW | M |
| DIM_N | 0x014 | RW | N |
| DIM_K | 0x018 | RW | K |
| ADDR_A | 0x020 | RW | A base |
| ADDR_B | 0x024 | RW | B base |
| ADDR_C | 0x028 | RW | C base |
| ADDR_D | 0x02C | RW | D base |
| STRIDE_A | 0x030 | RW | A stride bytes |
| STRIDE_B | 0x034 | RW | B stride bytes |
| STRIDE_C | 0x038 | RW | C stride bytes |
| STRIDE_D | 0x03C | RW | D stride bytes |
| TILE_M | 0x040 | RW | Tm |
| TILE_N | 0x044 | RW | Tn |
| TILE_K | 0x048 | RW | Tk |
| ARRAY_CFG | 0x04C | RO | PE_M/PE_N |
| PERF0..N | 0x050+ | RO | 周期/字节/等待等计数器 |

## 12. Reference (Internal Documentation)

- `README.md`（项目目标与接口要求）
- `ARCHITECTURE.md`（总体架构说明）
- `spec/modules.md`（模块清单）

## 13. Open Issues & Workaround (Internal Documentation)

- Open Issue: 单任务模型无法覆盖高吞吐命令链路
  - Workaround: 软件串行下发任务，等待 done 后再发下一任务
- Open Issue: debug CSR 位宽与性能计数器宽度未最终冻结
  - Workaround: 当前按 32-bit CSR、64-bit counter 实现
