# Top-Level & System Control Module Spec (Internal)

## 1. Revision History (Internal Documentation)

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1 | 2026-04-30 | Codex | Initial draft for top-level and system-control modules (`gemm_top/csr_if/irq_ctrl/tile_scheduler`). |
| v0.2 | 2026-05-02 | Digital Design | Complete port lists, FSM, CSR map, and logic design. Align with RTL implementation. |

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
- PE_M/PE_N: 物理阵列维度（等于 P_M/P_N）

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
- 支持 AXI4-Lite CSR 接口（32-bit 寄存器访问）

## 4. Port List and Parameters (Internal Documentation)

### 4.1 `gemm_top`

#### 4.1.1 Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `P_M` | int | 2 | PE 阵列行数 |
| `P_N` | int | 2 | PE 阵列列数 |
| `ELEM_W` | int | 16 | FP16 元素位宽 |
| `ACC_W` | int | 32 | 累加器位宽 |
| `ADDR_W` | int | 64 | 地址位宽 |
| `AXIL_ADDR_W` | int | 16 | AXI4-Lite 地址位宽 |
| `AXI_DATA_W` | int | 256 | AXI4 数据位宽 |
| `AXI_ID_W` | int | 4 | AXI ID 位宽 |
| `DIM_W` | int | 16 | 维度位宽 |
| `STRIDE_W` | int | 32 | stride 位宽 |
| `TILE_W` | int | 16 | tile 尺寸位宽 |
| `MAX_BURST_LEN` | int | 16 | 最大 burst beat 数 |
| `OUTSTANDING_RD` | int | 8 | 最大读 outstanding |
| `OUTSTANDING_WR` | int | 8 | 最大写 outstanding |
| `BUF_BANKS` | int | 4 | buffer bank 数 |
| `BUF_DEPTH` | int | 512 | 每 bank 深度 |

#### 4.1.2 AXI4-Lite Slave Interface (CSR)

| Signal | Direction | Width | Description |
|---|---|---|---|
| `s_axil_aclk` | Input | 1 | AXI4-Lite 时钟（与 core 同频或异步） |
| `s_axil_aresetn` | Input | 1 | AXI4-Lite 复位 |
| `s_axil_awaddr` | Input | AXIL_ADDR_W | 写地址 |
| `s_axil_awprot` | Input | 3 | 写保护 |
| `s_axil_awvalid` | Input | 1 | 写地址有效 |
| `s_axil_awready` | Output | 1 | 写地址就绪 |
| `s_axil_wdata` | Input | 32 | 写数据 |
| `s_axil_wstrb` | Input | 4 | 写字节使能 |
| `s_axil_wvalid` | Input | 1 | 写数据有效 |
| `s_axil_wready` | Output | 1 | 写数据就绪 |
| `s_axil_bresp` | Output | 2 | 写响应 |
| `s_axil_bvalid` | Output | 1 | 写响应有效 |
| `s_axil_bready` | Input | 1 | 写响应就绪 |
| `s_axil_araddr` | Input | AXIL_ADDR_W | 读地址 |
| `s_axil_arprot` | Input | 3 | 读保护 |
| `s_axil_arvalid` | Input | 1 | 读地址有效 |
| `s_axil_arready` | Output | 1 | 读地址就绪 |
| `s_axil_rdata` | Output | 32 | 读数据 |
| `s_axil_rresp` | Output | 2 | 读响应 |
| `s_axil_rvalid` | Output | 1 | 读数据有效 |
| `s_axil_rready` | Input | 1 | 读数据就绪 |

#### 4.1.3 AXI4 Master Read Interface

| Signal | Direction | Width | Description |
|---|---|---|---|
| `m_axi_arid` | Output | AXI_ID_W | ARID |
| `m_axi_araddr` | Output | ADDR_W | ARADDR |
| `m_axi_arlen` | Output | 8 | ARLEN |
| `m_axi_arsize` | Output | 3 | ARSIZE |
| `m_axi_arburst` | Output | 2 | ARBURST |
| `m_axi_arlock` | Output | 1 | ARLOCK |
| `m_axi_arcache` | Output | 4 | ARCACHE |
| `m_axi_arprot` | Output | 3 | ARPROT |
| `m_axi_arvalid` | Output | 1 | ARVALID |
| `m_axi_arready` | Input | 1 | ARREADY |
| `m_axi_rid` | Input | AXI_ID_W | RID |
| `m_axi_rdata` | Input | AXI_DATA_W | RDATA |
| `m_axi_rresp` | Input | 2 | RRESP |
| `m_axi_rlast` | Input | 1 | RLAST |
| `m_axi_rvalid` | Input | 1 | RVALID |
| `m_axi_rready` | Output | 1 | RREADY |

#### 4.1.4 AXI4 Master Write Interface

| Signal | Direction | Width | Description |
|---|---|---|---|
| `m_axi_awid` | Output | AXI_ID_W | AWID |
| `m_axi_awaddr` | Output | ADDR_W | AWADDR |
| `m_axi_awlen` | Output | 8 | AWLEN |
| `m_axi_awsize` | Output | 3 | AWSIZE |
| `m_axi_awburst` | Output | 2 | AWBURST |
| `m_axi_awlock` | Output | 1 | AWLOCK |
| `m_axi_awcache` | Output | 4 | AWCACHE |
| `m_axi_awprot` | Output | 3 | AWPROT |
| `m_axi_awvalid` | Output | 1 | AWVALID |
| `m_axi_awready` | Input | 1 | AWREADY |
| `m_axi_wdata` | Output | AXI_DATA_W | WDATA |
| `m_axi_wstrb` | Output | AXI_DATA_W/8 | WSTRB |
| `m_axi_wlast` | Output | 1 | WLAST |
| `m_axi_wvalid` | Output | 1 | WVALID |
| `m_axi_wready` | Input | 1 | WREADY |
| `m_axi_bid` | Input | AXI_ID_W | BID |
| `m_axi_bresp` | Input | 2 | BRESP |
| `m_axi_bvalid` | Input | 1 | BVALID |
| `m_axi_bready` | Output | 1 | BREADY |

#### 4.1.5 Interrupt

| Signal | Direction | Width | Description |
|---|---|---|---|
| `irq_o` | Output | 1 | 中断输出（高有效） |

### 4.2 `csr_if`

#### 4.2.1 Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `AXIL_ADDR_W` | int | 16 | AXI4-Lite 地址位宽 |
| `DIM_W` | int | 16 | 维度位宽 |
| `ADDR_W` | int | 64 | 地址位宽 |
| `STRIDE_W` | int | 32 | stride 位宽 |
| `TILE_W` | int | 16 | tile 尺寸位宽 |
| `PERF_CNT_W` | int | 64 | 性能计数器位宽 |
| `ERR_CODE_W` | int | 16 | 错误码位宽 |

#### 4.2.2 Port List

**AXI4-Lite Slave**（同 4.1.2，略）

**到 tile_scheduler 的配置输出**

| Signal | Direction | Width | Description |
|---|---|---|---|
| `cfg_m` | Output | DIM_W | M 维度 |
| `cfg_n` | Output | DIM_W | N 维度 |
| `cfg_k` | Output | DIM_W | K 维度 |
| `cfg_tile_m` | Output | TILE_W | Tm |
| `cfg_tile_n` | Output | TILE_W | Tn |
| `cfg_tile_k` | Output | TILE_W | Tk |
| `cfg_addr_a` | Output | ADDR_W | A 基地址 |
| `cfg_addr_b` | Output | ADDR_W | B 基地址 |
| `cfg_addr_c` | Output | ADDR_W | C 基地址 |
| `cfg_addr_d` | Output | ADDR_W | D 基地址 |
| `cfg_stride_a` | Output | STRIDE_W | A stride |
| `cfg_stride_b` | Output | STRIDE_W | B stride |
| `cfg_stride_c` | Output | STRIDE_W | C stride |
| `cfg_stride_d` | Output | STRIDE_W | D stride |
| `cfg_add_c_en` | Output | 1 | 使能 C 融合 |
| `cfg_round_mode` | Output | 2 | round 模式 |
| `cfg_sat_en` | Output | 1 | 使能饱和 |
| `cfg_start` | Output | 1 | start 脉冲（W1P） |
| `cfg_soft_reset` | Output | 1 | soft reset 脉冲 |

**从 tile_scheduler 的状态输入**

| Signal | Direction | Width | Description |
|---|---|---|---|
| `sch_busy` | Input | 1 | scheduler 忙碌 |
| `sch_done` | Input | 1 | scheduler 完成 |
| `sch_err` | Input | 1 | scheduler 错误 |
| `sch_err_code` | Input | ERR_CODE_W | 错误码 |
| `sch_tile_m_idx` | Input | TILE_W | 当前 tile m 索引 |
| `sch_tile_n_idx` | Input | TILE_W | 当前 tile n 索引 |
| `sch_tile_k_idx` | Input | TILE_W | 当前 tile k 索引 |

**性能计数器输入**

| Signal | Direction | Width | Description |
|---|---|---|---|
| `perf_cycle_total` | Input | PERF_CNT_W | 总周期 |
| `perf_cycle_compute` | Input | PERF_CNT_W | 计算周期 |
| `perf_cycle_dma_wait` | Input | PERF_CNT_W | DMA 等待周期 |
| `perf_axi_rd_bytes` | Input | PERF_CNT_W | AXI 读字节 |
| `perf_axi_wr_bytes` | Input | PERF_CNT_W | AXI 写字节 |

**中断控制**

| Signal | Direction | Width | Description |
|---|---|---|---|
| `irq_en` | Output | 1 | 中断使能 |
| `irq_o` | Output | 1 | 中断输出 |
| `irq_status` | Input | 8 | 中断状态源 |

### 4.3 `tile_scheduler`

#### 4.3.1 Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `P_M` | int | 2 | PE 阵列行数 |
| `P_N` | int | 2 | PE 阵列列数 |
| `DIM_W` | int | 16 | 维度位宽 |
| `ADDR_W` | int | 64 | 地址位宽 |
| `STRIDE_W` | int | 32 | stride 位宽 |
| `TILE_W` | int | 16 | tile 尺寸位宽 |
| `ELEM_W` | int | 16 | 元素位宽 |
| `ERR_CODE_W` | int | 16 | 错误码位宽 |

#### 4.3.2 Port List

**时钟复位**

| `clk` | Input | 1 | 主时钟 |
| `rst_n` | Input | 1 | 异步低有效复位 |

**来自 csr_if 的配置**

| `cfg_m` | Input | DIM_W | M 维度 |
| `cfg_n` | Input | DIM_W | N 维度 |
| `cfg_k` | Input | DIM_W | K 维度 |
| `cfg_tile_m` | Input | TILE_W | Tm |
| `cfg_tile_n` | Input | TILE_W | Tn |
| `cfg_tile_k` | Input | TILE_W | Tk |
| `cfg_addr_a` | Input | ADDR_W | A 基地址 |
| `cfg_addr_b` | Input | ADDR_W | B 基地址 |
| `cfg_addr_c` | Input | ADDR_W | C 基地址 |
| `cfg_addr_d` | Input | ADDR_W | D 基地址 |
| `cfg_stride_a` | Input | STRIDE_W | A stride |
| `cfg_stride_b` | Input | STRIDE_W | B stride |
| `cfg_stride_c` | Input | STRIDE_W | C stride |
| `cfg_stride_d` | Input | STRIDE_W | D stride |
| `cfg_add_c_en` | Input | 1 | 使能 C 融合 |
| `cfg_start` | Input | 1 | start 脉冲 |

**到 DMA 的读请求**

| `rd_req_valid` | Output | 1 | 读请求有效 |
| `rd_req_ready` | Input | 1 | 读请求就绪 |
| `rd_req_type` | Output | 2 | 00=A, 01=B, 10=C |
| `rd_req_base_addr` | Output | ADDR_W | 起始地址 |
| `rd_req_rows` | Output | TILE_W | 行数 |
| `rd_req_cols` | Output | TILE_W | 列数 |
| `rd_req_stride` | Output | STRIDE_W | stride |
| `rd_req_last` | Output | 1 | 本轮最后一个请求 |

**到 DMA 的写请求**

| `wr_req_valid` | Output | 1 | 写请求有效 |
| `wr_req_ready` | Input | 1 | 写请求就绪 |
| `wr_req_base_addr` | Output | ADDR_W | 起始地址 |
| `wr_req_rows` | Output | TILE_W | 行数 |
| `wr_req_cols` | Output | TILE_W | 列数 |
| `wr_req_stride` | Output | STRIDE_W | stride |
| `wr_req_last` | Output | 1 | 本轮最后一个请求 |

**到 systolic_core 的计算控制**

| `core_start` | Output | 1 | 计算开始脉冲 |
| `core_done` | Input | 1 | 计算完成脉冲 |
| `core_busy` | Input | 1 | 计算忙碌 |
| `core_err` | Input | 1 | 计算错误 |

**到 postproc 的控制**

| `pp_start` | Output | 1 | postproc 开始脉冲 |
| `pp_done` | Input | 1 | postproc 完成脉冲 |
| `pp_busy` | Input | 1 | postproc 忙碌 |

**Buffer ping-pong 控制**

| `pp_switch_req` | Output | 1 | ping-pong 切换请求 |
| `pp_switch_ack` | Input | 1 | ping-pong 切换确认 |

**状态输出到 csr_if**

| `sch_busy` | Output | 1 | 忙碌 |
| `sch_done` | Output | 1 | 完成脉冲 |
| `sch_err` | Output | 1 | 错误脉冲 |
| `sch_err_code` | Output | ERR_CODE_W | 错误码 |
| `sch_tile_m_idx` | Output | TILE_W | 当前 tile m 索引 |
| `sch_tile_n_idx` | Output | TILE_W | 当前 tile n 索引 |
| `sch_tile_k_idx` | Output | TILE_W | 当前 tile k 索引 |
| `tile_mask` | Output | P_M*P_N | 当前 tile 边界 mask |

**性能计数器触发**

| `cnt_start` | Output | 1 | 计数器启动 |
| `cnt_stop` | Output | 1 | 计数器停止 |

## 5. Functional Descriptions

### 5.1. Normal Function

1. Host 通过 AXI4-Lite 配置 CSR（维度/地址/stride/tile/模式）
2. Host 写 `CTRL.start=1`（W1P）
3. `tile_scheduler` 进入 `busy`，按 `(m0,n0,k0)` 循环：
   - 对于每个 tile：
     a. 发起 A/B (及 C) 读请求
     b. 等待读完成，切换 ping-pong buffer
     c. 触发 `core_start` 计算
     d. 等待 `core_done`
     e. 若 `k` 是最后一轮，触发 `pp_start` 后处理
     f. 若 `k` 完成且需写回，触发 D 写请求
4. 全部 tile 完成后置位 `done`，若 `irq_en=1` 拉起中断
5. Host 读取状态/计数器，W1C 清除 `done`

### 5.1.1. Configuration Methods(Optional)

推荐配置顺序：
1. 写 `soft_reset=1`（可选）
2. 写 `DIM_*`
3. 写 `ADDR_*`
4. 写 `STRIDE_*`
5. 写 `TILE_*`
6. 写 `MODE_*`（add_c_en, round_mode, sat_en）
7. 写 `irq_en`
8. 写 `start=1`

### 5.2. Diagnostic Function(Optional)

- 运行中可读 `STATUS`、`ERR_CODE`、`PERF_COUNTER`
- 异常时可读取当前 tile 索引（debug CSR）
- 支持性能计数器快照与冻结

### 5.2.1. Configuration Methods(Optional)

- 设置 `diag_en`（如实现）后开放额外 debug 视图寄存器
- `DEBUG_CTRL` 寄存器控制 trace 和 freeze

## 6. Test/Debug Modes (Internal Documentation)

- `test_mode`（可选）：强制进入可重复时序路径
- `perf_freeze`（可选）：冻结性能计数器快照
- `single_step`（可选）：每 tile 暂停等待软件继续

### 6.1.1. Configuration Methods

- 通过 `DEBUG_CTRL` 寄存器写入：
  - bit0 `test_mode_en`
  - bit1 `perf_freeze`
  - bit2 `single_step`

## 7. Architecture Descriptions (Internal Documentation)

### 7.1. Architecture Overview

控制平面由 `csr_if + tile_scheduler` 构成，数据平面由 DMA/Buffer/Compute/Postproc 组成。控制平面仅发请求与收状态，不直接处理矩阵数据。

`irq_ctrl` 并入 `csr_if`（逻辑简单，推荐）。

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
- Postproc 接口：`pp_start/pp_done`

### 7.4. Architecture Scheme Comparison (Optional)

- 方案A：`irq_ctrl` 并入 `csr_if`（逻辑简单，推荐）
- 方案B：`irq_ctrl` 独立（扩展性高，门数略增）

### 7.5. Sub-Module `tile_scheduler`

#### 7.5.1. Overview

负责 tile 循环、边界处理、流水并行控制。

#### 7.5.2. Logic Design

**Tile 循环结构：**

```
for m0 = 0 to M-1 step Tm:
    for n0 = 0 to N-1 step Tn:
        for k0 = 0 to K-1 step Tk:
            // 1. 读 A tile (m0,k0)
            // 2. 读 B tile (k0,n0)
            // 3. 若 add_c_en 且 k0==0，读 C tile (m0,n0)
            // 4. 等待读完成
            // 5. 切换 ping-pong buffer
            // 6. 触发 core_start
            // 7. 等待 core_done
            // 8. 若 k0+Tk >= K，触发 postproc + D 写回
```

**状态机：**

```
IDLE -> (cfg_start && !busy) -> PRECHECK
PRECHECK -> (check_pass) -> LOAD_AB
PRECHECK -> (check_fail) -> ERR
LOAD_AB -> (rd_req_ready && ab_cmd_sent) -> LOAD_C
LOAD_AB -> (!add_c_en) -> WAIT_RD
LOAD_C -> (rd_req_ready && c_cmd_sent) -> WAIT_RD
WAIT_RD -> (rd_done) -> COMPUTE
COMPUTE -> (core_done) -> CHECK_K
CHECK_K -> (k_rem > 0) -> NEXT_K
CHECK_K -> (k_rem == 0 && !last_tile) -> STORE
CHECK_K -> (k_rem == 0 && last_tile) -> DONE
NEXT_K -> (1 cycle) -> LOAD_AB
STORE -> (wr_done) -> CHECK_MN
CHECK_MN -> (mn_rem > 0) -> NEXT_MN
CHECK_MN -> (mn_rem == 0) -> DONE
DONE -> (1 cycle) -> IDLE
ERR -> (soft_reset) -> IDLE
```

**边界 mask 生成：**

对于 tile `(m0,n0)`：
- `act_rows = min(Tm, M - m0)`
- `act_cols = min(Tn, N - n0)`
- `tile_mask[i] = (i/P_N < act_rows) && (i%P_N < act_cols)`

**地址计算：**

- A tile: `addr = addr_a + m0*stride_a + k0*ELEM_BYTES`
- B tile: `addr = addr_b + k0*stride_b + n0*ELEM_BYTES`
- C tile: `addr = addr_c + m0*stride_c + n0*ELEM_BYTES`
- D tile: `addr = addr_d + m0*stride_d + n0*ELEM_BYTES`

**预检查（PRECHECK）：**

- `M/N/K == 0` → `ERR_ILLEGAL_DIM`
- `Tm/Tn/Tk == 0` → `ERR_ILLEGAL_TILE`
- `addr_a/b/c/d` 未对齐到 `ELEM_BYTES` → `ERR_ADDR_ALIGN`
- `stride_a/b/c/d` 未对齐 → `ERR_STRIDE_ALIGN`
- `Tm > M || Tn > N || Tk > K` → `ERR_TILE_OVERSIZE`

### 7.6. Sub-Module `csr_if`

#### 7.6.1. Overview

AXI4-Lite 从设备，实现 CSR 寄存器访问与中断控制。

#### 7.6.2. Logic Design

**AXI4-Lite 写时序：**

```
AWVALID && AWREADY -> 锁存写地址
WVALID && WREADY -> 锁存写数据，按 WSTRB 更新寄存器
-> BVALID（1 拍后）
-> BREADY 清零 BVALID
```

**AXI4-Lite 读时序：**

```
ARVALID && ARREADY -> 锁存读地址
-> RVALID + RDATA（组合或 1 拍后）
-> RREADY 清零 RVALID
```

**寄存器更新规则：**

| 寄存器 | 类型 | 说明 |
|---|---|---|
| `CTRL` | RW | bit0=start(W1P), bit1=soft_reset, bit2=irq_en |
| `STATUS` | RW | bit0=busy(RO), bit1=done(W1C), bit2=err(W1C) |
| `ERR_CODE` | RO | 错误码，写任意值清零 |
| `DIM_*` | RW | 维度配置 |
| `ADDR_*` | RW | 地址配置 |
| `STRIDE_*` | RW | stride 配置 |
| `TILE_*` | RW | tile 尺寸配置 |
| `MODE` | RW | add_c_en, round_mode, sat_en |
| `PERF_*` | RO | 性能计数器 |

**W1P/W1C 处理：**
- `CTRL.start`：写 1 产生单周期脉冲 `cfg_start`，自动清零
- `STATUS.done`：写 1 清零 `sch_done` 锁存
- `STATUS.err`：写 1 清零 `sch_err` 锁存

**中断生成：**

```
irq_o = irq_en && (sch_done || sch_err)
```

- `sch_done` 上升沿锁存到 `irq_pending`
- `sch_err` 上升沿锁存到 `irq_pending`
- 读 `STATUS` 或写 W1C 清除对应位

### 7.7. Sub-Module `irq_ctrl`（并入 csr_if）

#### 7.7.1. Overview

中断聚合与屏蔽。

#### 7.7.2. Logic Design

**中断源：**

| 位 | 源 | 说明 |
|---|---|---|
| 0 | `sch_done` | 任务完成 |
| 1 | `sch_err` | 任务错误 |
| 2 | `dma_rd_err` | DMA 读错误 |
| 3 | `dma_wr_err` | DMA 写错误 |
| 4 | `core_err` | 计算错误 |
| 5 | `pp_err` | 后处理错误 |
| 6 | `timeout` | 超时 |
| 7 | `perf_threshold` | 性能阈值（可选） |

**中断屏蔽：**
- `IRQ_MASK` 寄存器（默认 0xFF，全部屏蔽）
- `irq_o = |(irq_status & ~irq_mask) & irq_en`

### 7.8. Data Path Design

#### 7.8.1. 配置数据通路

```
AXI4-Lite write -> csr_if decode -> cfg_* registers -> tile_scheduler
```

#### 7.8.2. 状态数据通路

```
tile_scheduler -> sch_busy/done/err/err_code -> csr_if status registers -> AXI4-Lite read
```

#### 7.8.3. 性能计数器通路

```
tile_scheduler cnt_start/stop -> perf_counter -> csr_if perf registers
```

### 7.9. Low Power Design (Optional)

- `busy=0` 时门控部分计数器时钟
- 空闲阶段关闭可选 debug 路径
- CSR 访问时动态使能寄存器读端口

### 7.10. Architecture Open Issues (Optional)

- 是否需要多任务命令队列（当前默认单任务）
- `ERR_CODE` 是否扩展为多 bit 位图
- 是否支持 tile 级流水线 overlap（读下一个 tile 同时计算当前 tile）

## 8. Integration Guide (Internal Documentation)

- 与 SoC 集成时，确保 AXI 地址空间映射连续
- 中断线接入系统中断控制器
- 推荐保留寄存器镜像供驱动层调试
- `gemm_top` 实例化顺序：
  1. `csr_if`
  2. `tile_scheduler`
  3. `dma_rd` + `rd_addr_gen` + `axi_rd_master`
  4. `dma_wr` + `wr_addr_gen` + `axi_wr_master`
  5. `buffer_bank`（A/B ping-pong）
  6. `a_loader` + `b_loader`
  7. `systolic_core`
  8. `postproc`
  9. `d_storer`

## 9. Implementation Guide (Internal Documentation)

- 先实现 `csr_if + tile_scheduler` 的最小闭环（仅状态机，不接 DMA）
- 再接入 DMA 与 compute handshake
- 最后补齐异常路径与 debug/perf
- 编码建议：
  - CSR 地址解码使用 `casez` 或查找表
  - 状态机使用 `typedef enum logic`
  - tile 循环计数器使用 `for` 生成或显式状态机

## 10. Verification Guide (Internal Documentation)

### 10.1. 功能测试

| 测试 | 描述 |
|---|---|
| T1 | CSR 读写：合法地址访问 |
| T2 | CSR 读写：非法地址返回 SLVERR |
| T3 | 启停流程：start->busy->done->W1C->idle |
| T4 | 中断流程：`irq_en=0` 时不触发 |
| T5 | 中断流程：`irq_en=1` 时 done 触发 irq |
| T6 | 异常流程：非法维度（M=0）进入 ERR |
| T7 | 异常流程：地址未对齐进入 ERR |
| T8 | Tile 循环：单 tile M=Tn, N=Tn, K=Tk |
| T9 | Tile 循环：多 tile M=2*Tm, N=2*Tn, K=2*Tk |
| T10 | 边界 mask：非完整 tile 正确生成 |

### 10.2. 性能测试

| 测试 | 描述 |
|---|---|
| T11 | 性能计数器：周期计数准确 |
| T12 | 性能计数器：freeze/snapshot 时序 |

### 10.3. 覆盖建议

- CSR 地址覆盖（全部寄存器）
- 状态机状态覆盖（IDLE/PRECHECK/LOAD/COMPUTE/STORE/DONE/ERR）
- Tile 循环边界覆盖（单 tile/多 tile/边界 tile）
- 错误码覆盖（全部错误类型）

## 11. Registers

| 名称 | 偏移 | 类型 | 说明 |
|---|---|---|---|
| `CTRL` | 0x000 | RW | bit0 start(W1P), bit1 soft_reset, bit2 irq_en |
| `STATUS` | 0x004 | RW | bit0 busy(RO), bit1 done(W1C), bit2 err(W1C) |
| `ERR_CODE` | 0x008 | RO | 错误码 |
| `IRQ_MASK` | 0x00C | RW | 中断屏蔽 |
| `IRQ_STATUS` | 0x010 | RO | 中断状态 |
| `DIM_M` | 0x020 | RW | M |
| `DIM_N` | 0x024 | RW | N |
| `DIM_K` | 0x028 | RW | K |
| `ADDR_A` | 0x030 | RW | A 基地址（低 32 位） |
| `ADDR_A_HI` | 0x034 | RW | A 基地址（高 32 位） |
| `ADDR_B` | 0x038 | RW | B 基地址（低 32 位） |
| `ADDR_B_HI` | 0x03C | RW | B 基地址（高 32 位） |
| `ADDR_C` | 0x040 | RW | C 基地址（低 32 位） |
| `ADDR_C_HI` | 0x044 | RW | C 基地址（高 32 位） |
| `ADDR_D` | 0x048 | RW | D 基地址（低 32 位） |
| `ADDR_D_HI` | 0x04C | RW | D 基地址（高 32 位） |
| `STRIDE_A` | 0x050 | RW | A stride |
| `STRIDE_B` | 0x054 | RW | B stride |
| `STRIDE_C` | 0x058 | RW | C stride |
| `STRIDE_D` | 0x05C | RW | D stride |
| `TILE_M` | 0x060 | RW | Tm |
| `TILE_N` | 0x064 | RW | Tn |
| `TILE_K` | 0x068 | RW | Tk |
| `MODE` | 0x06C | RW | bit0 add_c_en, bit2:1 round_mode, bit3 sat_en |
| `ARRAY_CFG` | 0x070 | RO | bit7:0 PE_M, bit15:8 PE_N |
| `TILE_IDX_M` | 0x074 | RO | 当前 tile m 索引 |
| `TILE_IDX_N` | 0x078 | RO | 当前 tile n 索引 |
| `TILE_IDX_K` | 0x07C | RO | 当前 tile k 索引 |
| `PERF_CYCLE_TOTAL` | 0x080 | RO | 总周期（低 32 位） |
| `PERF_CYCLE_TOTAL_HI` | 0x084 | RO | 总周期（高 32 位） |
| `PERF_CYCLE_COMPUTE` | 0x088 | RO | 计算周期（低 32 位） |
| `PERF_CYCLE_COMPUTE_HI` | 0x08C | RO | 计算周期（高 32 位） |
| `PERF_CYCLE_DMA_WAIT` | 0x090 | RO | DMA 等待周期（低 32 位） |
| `PERF_CYCLE_DMA_WAIT_HI` | 0x094 | RO | DMA 等待周期（高 32 位） |
| `PERF_AXI_RD_BYTES` | 0x098 | RO | AXI 读字节（低 32 位） |
| `PERF_AXI_RD_BYTES_HI` | 0x09C | RO | AXI 读字节（高 32 位） |
| `PERF_AXI_WR_BYTES` | 0x0A0 | RO | AXI 写字节（低 32 位） |
| `PERF_AXI_WR_BYTES_HI` | 0x0A4 | RO | AXI 写字节（高 32 位） |
| `DEBUG_CTRL` | 0x0B0 | RW | bit0 test_mode, bit1 perf_freeze, bit2 single_step |

### 11.1. 错误码定义

| 错误码 | 值 | 说明 |
|---|---|---|
| `ERR_NONE` | 0x00 | 无错误 |
| `ERR_ILLEGAL_DIM` | 0x01 | 维度非法（M/N/K=0） |
| `ERR_ILLEGAL_TILE` | 0x02 | tile 尺寸非法（Tm/Tn/Tk=0） |
| `ERR_ADDR_ALIGN` | 0x03 | 地址未对齐 |
| `ERR_STRIDE_ALIGN` | 0x04 | stride 未对齐 |
| `ERR_TILE_OVERSIZE` | 0x05 | tile 大于矩阵 |
| `ERR_DMA_RD` | 0x10 | DMA 读错误 |
| `ERR_DMA_WR` | 0x11 | DMA 写错误 |
| `ERR_AXI_RD_RESP` | 0x20 | AXI RRESP 错误 |
| `ERR_AXI_WR_RESP` | 0x21 | AXI BRESP 错误 |
| `ERR_CORE` | 0x30 | 计算核心错误 |
| `ERR_PP` | 0x40 | 后处理错误 |
| `ERR_TIMEOUT` | 0x50 | 超时 |

## 12. Reference (Internal Documentation)

- `README.md`（项目目标与接口要求）
- `ARCHITECTURE.md`（总体架构说明）
- `spec/modules.md`（模块清单）
- `spec/dma_axi_access_spec.md`（DMA 接口）
- `spec/systolic_compute_core_spec.md`（计算核心）
- `spec/postprocess_numeric_spec.md`（后处理）

## 13. Open Issues & Workaround (Internal Documentation)

- Open Issue: 单任务模型无法覆盖高吞吐命令链路
  - Workaround: 软件串行下发任务，等待 done 后再发下一任务
- Open Issue: debug CSR 位宽与性能计数器宽度未最终冻结
  - Workaround: 当前按 32-bit CSR、64-bit counter 实现
- Open Issue: tile 级流水线 overlap 未实现
  - Workaround: 当前为单 tile 串行（读->算->写），后续可加入双缓冲 overlap
