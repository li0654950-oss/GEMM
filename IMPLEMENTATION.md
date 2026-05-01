# GEMM Accelerator Implementation Specification
# 总设计实现规格 (v1.0)

**版本**: v1.0  
**日期**: 2026-05-02  
**项目**: 脉动阵列 FP16 GEMM (D = A×B + C)  
**目标**: 1 TOPS 峰值，AXI4 接口  
**文档类型**: 实现规格（Implementation Spec），直接指导 RTL 编码  

---

## 1. 文档定位

本文档整合 `ARCHITECTURE.md` + `spec/*.md` 中的设计决策，输出**可直接用于 RTL 编码**的精确规格。涵盖：
- 全部 25 个模块的精确端口定义（位宽、方向、极性）
- 模块间接口匹配表（信号名、位宽、源→宿）
- 关键状态机：状态定义、转换条件、输出动作
- 时序规格：时钟频率、关键路径、feed-through 约束
- 参数化策略：全局参数、模块级参数、localparam 规则
- 编码优先级与依赖关系图

---

## 2. 全局参数与命名规范

### 2.1 全局参数（定义于 `gemm_pkg.sv`）

```systemverilog
package gemm_pkg;
    // 阵列维度
    parameter int P_M             = 4;      // 阵列行数
    parameter int P_N             = 4;      // 阵列列数
    
    // 数据位宽
    parameter int ELEM_W          = 16;     // FP16
    parameter int ACC_W           = 32;     // FP32 累加器
    parameter int ELEM_BYTES      = 2;      // FP16 = 2 bytes
    
    // 地址与配置
    parameter int ADDR_W          = 64;     // 地址位宽
    parameter int DIM_W           = 16;     // M/N/K 维度位宽
    parameter int STRIDE_W        = 32;     // stride 位宽
    parameter int TILE_W          = 16;     // tile size 位宽
    
    // AXI4 总线
    parameter int AXI_DATA_W      = 256;    // AXI4 数据位宽
    parameter int AXI_ID_W        = 4;      // AXI ID 位宽
    parameter int AXI_STRB_W      = AXI_DATA_W / 8;
    parameter int AXI_ADDR_W      = ADDR_W;
    parameter int MAX_BURST_LEN   = 16;     // beats per burst (ARLEN=15)
    parameter int MAX_BURST_BYTES = MAX_BURST_LEN * (AXI_DATA_W / 8);
    
    // Buffer
    parameter int BUF_BANKS       = 8;      // bank 数量
    parameter int BUF_DEPTH       = 2048;   // 每 bank 深度
    parameter int BUF_ADDR_W      = $clog2(BUF_DEPTH);
    
    // 性能与边界
    parameter int K_MAX           = 4096;   // 最大 K 维度
    parameter int OUTSTANDING_RD  = 8;      // 读最大 outstanding
    parameter int OUTSTANDING_WR  = 8;      // 写最大 outstanding
    
    // 舍入模式 (RNE = 0, RTZ = 1, RUP = 2, RDN = 3)
    typedef enum logic [1:0] {
        RNE = 2'b00,
        RTZ = 2'b01,
        RUP = 2'b10,
        RDN = 2'b11
    } round_mode_t;
endpackage
```

### 2.2 命名规范

| 对象 | 风格 | 示例 |
|------|------|------|
| 模块名 | `snake_case` | `systolic_core`, `axi_rd_master` |
| 信号名 | `snake_case` | `core_start`, `acc_out_valid` |
| 输入前缀 | `i_` 或直接 | `i_a_vec_data` / `a_vec_data` |
| 输出前缀 | `o_` 或直接 | `o_core_done` / `core_done` |
| 参数 | `UPPER_CASE` | `P_M`, `AXI_DATA_W` |
| localparam | `UPPER_CASE` | `FILL_DRAIN_CYCLES`, `ACC_W` |
| 时钟/复位 | `clk`, `rst_n`（低有效） | |
| valid/ready | `_valid`, `_ready` | `wr_valid`, `wr_ready` |
| last | `_last` | `rd_data_last`, `d_last` |
| 状态机类型 | `*_state_t` | `core_state_t`, `sched_state_t` |

---

## 3. 模块间连接总表

### 3.1 顶层连接图

```text
                    AXI4-Lite Slave (s_axil_*)
                           |
                           v
                   +------------------+
                   |     csr_if       |
                   |  + irq_ctrl      |
                   +--------+---------+
                            | cfg_* (DIM/ADDR/STRIDE/TILE)
                            v
                   +------------------+
                   | tile_scheduler   |
                   +----+-------+-----+
                        |       |
       rd_req/wr_req   |       | compute_start
                        |       |
                        v       v
    +-------------------+       +-------------------+
    |   dma_rd  + rd_addr_gen   |   systolic_core   |
    |   axi_rd_master           |   + array_io_ad   |
    +-----------+---------------+   +-------+-------+
                |                           |
    A/B/C data  |                   acc_out_data
                |                           |
                v                           v
    +-------------------+       +-------------------+
    |   buffer_bank     |       |     postproc      |
    |   a_loader/b/c    |       |   fp_add_c        |
    |   d_storer        |       |   fp_round_sat    |
    +-------------------+       +--------+----------+
                                         |
                                D data   |
                                         v
                                +-------------------+
                                |   dma_wr + wr_addr|
                                |   axi_wr_master   |
                                +---------+---------+
                                          |
                                          v
                                   AXI4 Master (m_axi_*)
```

### 3.2 跨模块接口匹配表

#### 3.2.1 csr_if ↔ tile_scheduler

| 信号 | 源 | 宿 | 位宽 | 说明 |
|------|-----|-----|------|------|
| `cfg_m` | csr_if | scheduler | DIM_W | M 维度 |
| `cfg_n` | csr_if | scheduler | DIM_W | N 维度 |
| `cfg_k` | csr_if | scheduler | DIM_W | K 维度 |
| `cfg_tile_m` | csr_if | scheduler | TILE_W | Tm |
| `cfg_tile_n` | csr_if | scheduler | TILE_W | Tn |
| `cfg_tile_k` | csr_if | scheduler | TILE_W | Tk |
| `cfg_addr_a` | csr_if | scheduler | ADDR_W | A 基址 |
| `cfg_addr_b` | csr_if | scheduler | ADDR_W | B 基址 |
| `cfg_addr_c` | csr_if | scheduler | ADDR_W | C 基址 |
| `cfg_addr_d` | csr_if | scheduler | ADDR_W | D 基址 |
| `cfg_stride_a` | csr_if | scheduler | STRIDE_W | A stride |
| `cfg_stride_b` | csr_if | scheduler | STRIDE_W | B stride |
| `cfg_stride_c` | csr_if | scheduler | STRIDE_W | C stride |
| `cfg_stride_d` | csr_if | scheduler | STRIDE_W | D stride |
| `cfg_start` | csr_if | scheduler | 1 | W1P 启动脉冲 |
| `cfg_irq_en` | csr_if | scheduler | 1 | 中断使能 |
| `sch_busy` | scheduler | csr_if | 1 | 调度器忙碌 |
| `sch_done` | scheduler | csr_if | 1 | 完成标志 |
| `sch_err` | scheduler | csr_if | 1 | 错误标志 |
| `err_code` | scheduler | csr_if | 4 | 错误码 |

#### 3.2.2 tile_scheduler ↔ dma_rd

| 信号 | 源 | 宿 | 位宽 | 说明 |
|------|-----|-----|------|------|
| `rd_req_valid` | scheduler | dma_rd | 1 | 读请求有效 |
| `rd_req_type` | scheduler | dma_rd | 2 | 00=A, 01=B, 10=C |
| `rd_req_base` | scheduler | dma_rd | ADDR_W | 读基址 |
| `rd_req_rows` | scheduler | dma_rd | DIM_W | 行数 |
| `rd_req_cols` | scheduler | dma_rd | DIM_W | 列数 |
| `rd_req_stride` | scheduler | dma_rd | STRIDE_W | 行stride |
| `rd_req_ready` | dma_rd | scheduler | 1 | 读请求就绪 |
| `rd_done` | dma_rd | scheduler | 1 | 读完成 |
| `rd_err` | dma_rd | scheduler | 1 | 读错误 |

#### 3.2.3 tile_scheduler ↔ systolic_core

| 信号 | 源 | 宿 | 位宽 | 说明 |
|------|-----|-----|------|------|
| `compute_start` | scheduler | core | 1 | 启动脉冲 |
| `compute_mode` | scheduler | core | 1 | 0=FP16acc, 1=FP32acc |
| `compute_k_iter` | scheduler | core | TILE_W | Tk |
| `compute_mask` | scheduler | core | P_M*P_N | 边界 tile mask |
| `core_busy` | core | scheduler | 1 | 计算中 |
| `core_done` | core | scheduler | 1 | 完成脉冲 |
| `core_err` | core | scheduler | 1 | 错误 |

#### 3.2.4 dma_rd ↔ buffer_bank (via a_loader/b_loader)

| 信号 | 源 | 宿 | 位宽 | 说明 |
|------|-----|-----|------|------|
| `dma_rd_data_valid` | axi_rd | loader | 1 | 读数据有效 |
| `dma_rd_data` | axi_rd | loader | AXI_DATA_W | 读数据 |
| `dma_rd_data_last` | axi_rd | loader | 1 | 当前 burst 最后 |
| `buf_wr_valid` | loader | buffer | 1 | 写 buffer 有效 |
| `buf_wr_addr` | loader | buffer | BUF_ADDR_W | 写地址 |
| `buf_wr_data` | loader | buffer | AXI_DATA_W | 写数据 |
| `buf_wr_mask` | loader | buffer | AXI_STRB_W | 字节掩码 |
| `buf_wr_ready` | buffer | loader | 1 | 写就绪 |

#### 3.2.5 buffer_bank ↔ array_io_adapter ↔ systolic_core

| 信号 | 源 | 宿 | 位宽 | 说明 |
|------|-----|-----|------|------|
| `buf_a_data` | buffer | adapter | P_M*ELEM_W | A 向量 |
| `buf_b_data` | buffer | adapter | P_N*ELEM_W | B 向量 |
| `a_vec_valid` | adapter | core | 1 | A 注入有效 |
| `a_vec_data` | adapter | core | P_M*ELEM_W | A 注入数据 |
| `a_vec_mask` | adapter | core | P_M | A mask |
| `b_vec_valid` | adapter | core | 1 | B 注入有效 |
| `b_vec_data` | adapter | core | P_N*ELEM_W | B 注入数据 |
| `b_vec_mask` | adapter | core | P_N | B mask |
| `acc_out_valid` | core | postproc | 1 | 累加器输出有效 |
| `acc_out_data` | core | postproc | P_M*P_N*ACC_W | 累加器数据 |
| `acc_out_last` | core | postproc | 1 | tile 最后输出 |

#### 3.2.6 postproc ↔ d_storer ↔ dma_wr

| 信号 | 源 | 宿 | 位宽 | 说明 |
|------|-----|-----|------|------|
| `d_valid` | postproc | storer | 1 | D 数据有效 |
| `d_data` | postproc | storer | P_N*ELEM_W | D 数据 (FP16) |
| `d_last` | postproc | storer | 1 | tile 最后 |
| `dma_wr_data` | storer | axi_wr | AXI_DATA_W | 写数据 |
| `dma_wr_valid` | storer | axi_wr | 1 | 写数据有效 |
| `dma_wr_last` | storer | axi_wr | 1 | 写 burst 最后 |
| `dma_wr_strb` | storer | axi_wr | AXI_STRB_W | 字节 strobe |

---

## 4. 关键状态机详细规格

### 4.1 tile_scheduler 状态机

**状态定义**:
```systemverilog
typedef enum logic [3:0] {
    SCH_IDLE,
    SCH_PRECHECK,      // 检查维度合法性、地址对齐
    SCH_LOAD_AB,       // 发起 A/B 读请求
    SCH_LOAD_C,        // 发起 C 读请求（若启用+C）
    SCH_WAIT_BUF,      // 等待 buffer 就绪
    SCH_COMPUTE,       // 启动 systolic_core，等待 core_done
    SCH_WAIT_PP,       // 等待 postproc 完成
    SCH_STORE,         // 发起 D 写请求
    SCH_NEXT_TILE,     // 更新 tile 索引，切换 ping-pong
    SCH_DONE,
    SCH_ERR            // 错误状态，保持到 soft_reset
} sched_state_t;
```

**状态转换条件**:

| 当前状态 | 下一状态 | 条件 |
|----------|----------|------|
| IDLE | PRECHECK | `cfg_start && !sch_busy` |
| PRECHECK | LOAD_AB | 所有检查通过 |
| PRECHECK | ERR | 维度非法 / 地址未对齐 / 越界 |
| LOAD_AB | LOAD_C | `rd_done(A) && rd_done(B)` 且 `add_c_en=1` |
| LOAD_AB | WAIT_BUF | `rd_done(A) && rd_done(B)` 且 `add_c_en=0` |
| LOAD_C | WAIT_BUF | `rd_done(C)` |
| WAIT_BUF | COMPUTE | buffer 就绪（ping-pong 切换完成） |
| COMPUTE | WAIT_PP | `core_done` |
| COMPUTE | ERR | `core_err` |
| WAIT_PP | STORE | `pp_done` |
| STORE | NEXT_TILE | `wr_done` |
| STORE | ERR | `wr_err` |
| NEXT_TILE | LOAD_AB | `k0 < K`，继续下一个 k-chunk |
| NEXT_TILE | DONE | `m0 >= M && n0 >= N && k0 >= K` |
| DONE | IDLE | `sch_done` 已置位（W1C 后） |
| ERR | IDLE | `soft_reset=1` |

**输出动作**:

| 状态 | sch_busy | rd_req_valid | compute_start | wr_req_valid | 其他 |
|------|----------|-------------|---------------|-------------|------|
| IDLE | 0 | 0 | 0 | 0 | — |
| PRECHECK | 1 | 0 | 0 | 0 | 检查寄存器 |
| LOAD_AB | 1 | 1 (A/B交替) | 0 | 0 | — |
| LOAD_C | 1 | 1 (C) | 0 | 0 | — |
| WAIT_BUF | 1 | 0 | 0 | 0 | 等待 pp_switch_ack |
| COMPUTE | 1 | 0 | 1 | 0 | 等待 core_done |
| WAIT_PP | 1 | 0 | 0 | 0 | 等待 pp_done |
| STORE | 1 | 0 | 0 | 1 | 等待 wr_done |
| NEXT_TILE | 1 | 0 | 0 | 0 | 更新 tile 索引 |
| DONE | 0 | 0 | 0 | 0 | sch_done=1 |
| ERR | 0 | 0 | 0 | 0 | sch_err=1 |

### 4.2 systolic_core 状态机

已在 `spec/systolic_compute_core_spec.md` Section 7.8 定义，此处精确化：

```systemverilog
typedef enum logic [2:0] {
    CORE_IDLE,
    CORE_COMPUTE,       // 包含 fill + 有效计算 + drain
    CORE_COMMIT,        // 输出累加结果
    CORE_DONE
} core_state_t;
```

**关键参数**:
- `FILL_DRAIN_CYCLES = P_M + P_N - 2`（wavefront 传播延迟）
- `COMPUTE_CYCLES = k_iter_cfg + FILL_DRAIN_CYCLES`

**状态转换**:

| 当前 | 下一 | 条件 |
|------|------|------|
| IDLE | COMPUTE | `core_start && !core_busy` |
| COMPUTE | COMMIT | `k_cnt >= COMPUTE_CYCLES` |
| COMPUTE | ERR | `k_cnt > K_MAX`（溢出保护） |
| COMMIT | DONE | 1（单拍提交） |
| DONE | IDLE | 1（单拍完成） |

**输出**:

| 状态 | core_busy | acc_clear | acc_hold | acc_out_valid | acc_out_last |
|------|-----------|-----------|----------|---------------|--------------|
| IDLE | 0 | 1 | 1 | 0 | 0 |
| COMPUTE | 1 | 0 | 0 | 0 | 0 |
| COMMIT | 1 | 0 | 1 | 1 | 1 |
| DONE | 0 | 0 | 1 | 0 | 0 |

### 4.3 axi_rd_master 状态机

```systemverilog
typedef enum logic [2:0] {
    AXI_RD_IDLE,
    AXI_RD_ISSUE_AR,    // 发 AR 地址
    AXI_RD_RECV_R,      // 收 R 数据
    AXI_RD_DONE,
    AXI_RD_ERR
} axi_rd_state_t;
```

**协议要点**:
- `ARVALID` 高时 `ARADDR/ARLEN/ARSIZE/ARBURST` 必须稳定
- `RREADY` 可在任意时刻拉高/拉低（backpressure）
- `RLAST` 对应的 beat 必须接收后才算 burst 完成
- `RRESP != OKAY` → 转入 ERR 状态，锁存 `rd_err_code`

### 4.4 axi_wr_master 状态机

```systemverilog
typedef enum logic [2:0] {
    AXI_WR_IDLE,
    AXI_WR_ISSUE_AW,    // 发 AW 地址
    AXI_WR_SEND_W,      // 发 W 数据
    AXI_WR_WAIT_B,      // 等 B 响应
    AXI_WR_DONE,
    AXI_WR_ERR
} axi_wr_state_t;
```

**协议要点**:
- AW 和 W 通道独立，可同时发（outstanding > 1）
- `WLAST` 必须与最后数据同拍
- `WSTRB` 按有效字节置位，行尾短包需精确生成
- `BVALID` 到达后回收 outstanding credit
- `BRESP != OKAY` → 转入 ERR 状态

---

## 5. 时序规格

### 5.1 时钟域

| 时钟 | 频率 | 说明 | 来源 |
|------|------|------|------|
| `clk_core` | 1 GHz（目标） | 阵列、buffer、控制核心 | PLL |
| `clk_axi` | 500 MHz / 同频 | AXI4 总线接口 | SoC 互联 |

**注意**: MVP 阶段建议 `clk_core` 与 `clk_axi` 同源同频（或通过整数分频），避免 CDC 复杂度。

### 5.2 复位策略

```
rst_n (低有效) 异步断言，同步释放
├── 所有状态机 → IDLE
├── 所有寄存器 → 0 / 默认值
├── 累加器清零
├── CSR 保持（或按需求清零）
└── 复位释放后等待 2 拍再允许 start
```

### 5.3 关键路径与约束

| 路径 | 类型 | 约束建议 |
|------|------|----------|
| `acc_reg` → `fp_mul` → `fp_add` → `acc_reg` | 关键路径 | 单周期约束，重点优化 |
| `PE[i][j].a_out` → `PE[i][j+1].a_in` | feed-through | `set_multicycle_path 2` 或 `set_false_path`（纯传播） |
| `PE[i][j].b_out` → `PE[i+1][j].b_in` | feed-through | 同上 |
| `tile_scheduler` → `systolic_core` 控制 | 全局广播 | 做 CTS（时钟树平衡） |
| `axi_rd_master.AR` → 内存 → `R` | 外部路径 | 由 SoC 互联约束 |

### 5.4 握手协议时序

所有内部模块间接口采用 **valid/ready 握手**（AXI-Stream 风格）：

```
Cycle 1:  source_valid = 1, source_data = X, dest_ready = 0  → 未握手
Cycle 2:  source_valid = 1, source_data = X, dest_ready = 1  → 握手成功，数据传递
Cycle 3:  source_valid = 0 or next data                         → source 可更新
```

规则：
- `valid` 必须在 `ready` 为高时保持，直到握手完成
- `ready` 可在看到 `valid` 之前或之后拉高
- 数据在 `valid && ready` 的时钟上升沿采样

---

## 6. 各模块精确端口定义

### 6.1 `gemm_top`

**参数**: 透传所有子模块参数  
**端口**:

| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| `clk` | input | 1 | 主时钟 |
| `rst_n` | input | 1 | 异步低有效复位 |
| `s_axil_awaddr` | input | AXIL_ADDR_W | AXI4-Lite 写地址 |
| `s_axil_awvalid` | input | 1 | 写地址有效 |
| `s_axil_awready` | output | 1 | 写地址就绪 |
| `s_axil_wdata` | input | 32 | 写数据 |
| `s_axil_wstrb` | input | 4 | 写 strobe |
| `s_axil_wvalid` | input | 1 | 写数据有效 |
| `s_axil_wready` | output | 1 | 写数据就绪 |
| `s_axil_bresp` | output | 2 | 写响应 |
| `s_axil_bvalid` | output | 1 | 写响应有效 |
| `s_axil_bready` | input | 1 | 写响应就绪 |
| `s_axil_araddr` | input | AXIL_ADDR_W | 读地址 |
| `s_axil_arvalid` | input | 1 | 读地址有效 |
| `s_axil_arready` | output | 1 | 读地址就绪 |
| `s_axil_rdata` | output | 32 | 读数据 |
| `s_axil_rresp` | output | 2 | 读响应 |
| `s_axil_rvalid` | output | 1 | 读数据有效 |
| `s_axil_rready` | input | 1 | 读数据就绪 |
| `m_axi_arid` | output | AXI_ID_W | 读 ID |
| `m_axi_araddr` | output | AXI_ADDR_W | 读地址 |
| `m_axi_arlen` | output | 8 | 读 burst 长度 |
| `m_axi_arsize` | output | 3 | 读 burst 大小 |
| `m_axi_arburst` | output | 2 | 读 burst 类型 |
| `m_axi_arvalid` | output | 1 | 读地址有效 |
| `m_axi_arready` | input | 1 | 读地址就绪 |
| `m_axi_rid` | input | AXI_ID_W | 读响应 ID |
| `m_axi_rdata` | input | AXI_DATA_W | 读数据 |
| `m_axi_rresp` | input | 2 | 读响应 |
| `m_axi_rlast` | input | 1 | 读最后 |
| `m_axi_rvalid` | input | 1 | 读数据有效 |
| `m_axi_rready` | output | 1 | 读数据就绪 |
| `m_axi_awid` | output | AXI_ID_W | 写 ID |
| `m_axi_awaddr` | output | AXI_ADDR_W | 写地址 |
| `m_axi_awlen` | output | 8 | 写 burst 长度 |
| `m_axi_awsize` | output | 3 | 写 burst 大小 |
| `m_axi_awburst` | output | 2 | 写 burst 类型 |
| `m_axi_awvalid` | output | 1 | 写地址有效 |
| `m_axi_awready` | input | 1 | 写地址就绪 |
| `m_axi_wdata` | output | AXI_DATA_W | 写数据 |
| `m_axi_wstrb` | output | AXI_STRB_W | 写 strobe |
| `m_axi_wlast` | output | 1 | 写最后 |
| `m_axi_wvalid` | output | 1 | 写数据有效 |
| `m_axi_wready` | input | 1 | 写数据就绪 |
| `m_axi_bid` | input | AXI_ID_W | 写响应 ID |
| `m_axi_bresp` | input | 2 | 写响应 |
| `m_axi_bvalid` | input | 1 | 写响应有效 |
| `m_axi_bready` | output | 1 | 写响应就绪 |
| `irq_o` | output | 1 | 中断输出（高有效） |

### 6.2 `csr_if`

**端口**:

| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| `clk`, `rst_n` | input | 1 | — |
| `s_axil_*` | — | — | AXI4-Lite Slave（同 gemm_top） |
| `cfg_m` | output | DIM_W | — |
| `cfg_n` | output | DIM_W | — |
| `cfg_k` | output | DIM_W | — |
| `cfg_tile_m` | output | TILE_W | — |
| `cfg_tile_n` | output | TILE_W | — |
| `cfg_tile_k` | output | TILE_W | — |
| `cfg_addr_a/b/c/d` | output | ADDR_W | — |
| `cfg_stride_a/b/c/d` | output | STRIDE_W | — |
| `cfg_start` | output | 1 | W1P |
| `cfg_irq_en` | output | 1 | — |
| `cfg_soft_reset` | output | 1 | — |
| `sch_busy` | input | 1 | — |
| `sch_done` | input | 1 | — |
| `sch_err` | input | 1 | — |
| `err_code` | input | 4 | — |
| `perf_*` | input | 64 | 性能计数器组 |
| `irq_o` | output | 1 | — |

### 6.3 `tile_scheduler`

**端口**: 参见 Section 3.2 的接口匹配表。

### 6.4 `dma_rd` / `dma_wr`

**端口**: 参见 Section 3.2 的接口匹配表。

### 6.5 `axi_rd_master` / `axi_wr_master`

**端口**: 内部模块 ↔ AXI4 Master 通道（参见 `gemm_top` 端口定义）。

### 6.6 `buffer_bank`

**参数**:
- `BUF_BANKS` = 8
- `BUF_DEPTH` = 2048
- `VEC_W` = 256（与 AXI_DATA_W 对齐）

**端口**:

| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| `clk`, `rst_n` | input | 1 | — |
| `wr_valid` | input | 1 | 写请求 |
| `wr_bank_sel` | input | $clog2(BUF_BANKS) | bank 选择 |
| `wr_addr` | input | BUF_ADDR_W | 地址 |
| `wr_data` | input | AXI_DATA_W | 数据 |
| `wr_mask` | input | AXI_STRB_W | 字节掩码 |
| `wr_ready` | output | 1 | 写就绪 |
| `rd_req_valid` | input | 1 | 读请求 |
| `rd_bank_sel` | input | $clog2(BUF_BANKS) | bank 选择 |
| `rd_addr` | input | BUF_ADDR_W | 地址 |
| `rd_req_ready` | output | 1 | 读请求就绪 |
| `rd_data_valid` | output | 1 | 读数据有效 |
| `rd_data` | output | AXI_DATA_W | 读数据 |
| `pp_switch_req` | input | 1 | ping-pong 切换请求 |
| `pp_switch_ack` | output | 1 | 切换完成 |
| `conflict_stall` | output | 1 | bank 冲突停顿 |

### 6.7 `a_loader` / `b_loader` / `c_loader`

**端口**（以 a_loader 为例，b_loader 同构）：

| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| `clk`, `rst_n` | input | 1 | — |
| `dma_data_valid` | input | 1 | DMA 数据有效 |
| `dma_data` | input | AXI_DATA_W | DMA 数据 |
| `dma_data_last` | input | 1 | burst 最后 |
| `tile_rows` | input | DIM_W | tile 行数 |
| `tile_cols` | input | DIM_W | tile 列数 |
| `tile_stride` | input | STRIDE_W | stride bytes |
| `buf_wr_valid` | output | 1 | buffer 写有效 |
| `buf_wr_addr` | output | BUF_ADDR_W | buffer 地址 |
| `buf_wr_data` | output | AXI_DATA_W | buffer 数据 |
| `buf_wr_mask` | output | AXI_STRB_W | 字节掩码 |
| `load_done` | output | 1 | 装载完成 |
| `load_err` | output | 1 | 装载错误 |

### 6.8 `d_storer`

**端口**:

| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| `clk`, `rst_n` | input | 1 | — |
| `post_valid` | input | 1 | 后处理数据有效 |
| `post_data` | input | P_N*ELEM_W | D tile 数据 |
| `post_last` | input | 1 | tile 最后 |
| `store_rows` | input | DIM_W | 存储行数 |
| `store_cols` | input | DIM_W | 存储列数 |
| `store_stride` | input | STRIDE_W | stride bytes |
| `dma_wr_valid` | output | 1 | 写 DMA 有效 |
| `dma_wr_data` | output | AXI_DATA_W | 写数据 |
| `dma_wr_last` | output | 1 | burst 最后 |
| `dma_wr_strb` | output | AXI_STRB_W | 字节 strobe |
| `store_done` | output | 1 | 存储完成 |
| `store_err` | output | 1 | 存储错误 |

### 6.9 `systolic_core`

**端口**: 参见 Section 3.2.5 及 `spec/systolic_compute_core_spec.md` Section 4.1。

### 6.10 `pe_cell`

**端口**: 参见 `spec/systolic_compute_core_spec.md` Section 4.2 及已验证的 RTL (`rtl/pe_cell.sv`)。

### 6.11 `array_io_adapter`

**端口**: 参见 Section 3.2.5 及 `spec/systolic_compute_core_spec.md` Section 4.4。

### 6.12 `postproc`

**端口**: 参见 Section 3.2.6 及 `spec/postprocess_numeric_spec.md` Section 4.1。

### 6.13 `fp_add_c`

**端口**: 参见 `spec/postprocess_numeric_spec.md` Section 4.2。

### 6.14 `fp_round_sat`

**端口**: 参见 `spec/postprocess_numeric_spec.md` Section 4.3。

### 6.15 `err_checker`

**端口**: 参见 `spec/reliability_monitoring_verifassist_spec.md` Section 4.1。

### 6.16 `perf_counter`

**端口**: 参见 `spec/reliability_monitoring_verifassist_spec.md` Section 4.2。

### 6.17 `trace_debug_if`

**端口**: 参见 `spec/reliability_monitoring_verifassist_spec.md` Section 4.3。

---

## 7. 编码优先级与依赖图

### 7.1 模块依赖 DAG

```
pe_cell (叶子)
    |
    v
systolic_core  <--- array_io_adapter
    |
    v
postproc  <--- fp_add_c, fp_round_sat
    |
    v
d_storer

buffer_bank
    ^
    |
a_loader, b_loader, c_loader
    ^
    |
dma_rd  <--- rd_addr_gen  <--- axi_rd_master
dma_wr  <--- wr_addr_gen  <--- axi_wr_master
    ^
    |
tile_scheduler  <--- csr_if (+ irq_ctrl)
    ^
    |
gemm_top (顶层)

erf_checker, perf_counter, trace_debug_if (可独立，最后接入)
```

### 7.2 批次建议（基于 M1-M4）

#### M1: 可运行闭环（最小可用系统）

目标：单个 tile，无双缓冲，可正确完成一次矩阵乘法。

| 顺序 | 模块 | 依赖 | 验证方式 |
|------|------|------|----------|
| 1 | `pe_cell` | 无 | Unit TB（已完成） |
| 2 | `systolic_core` | pe_cell | 2x2 阵列矩阵乘法 TB |
| 3 | `array_io_adapter` | systolic_core | skew 注入 + 阵列 TB |
| 4 | `buffer_bank` | 无 | 单口读写 TB |
| 5 | `a_loader` / `b_loader` | buffer_bank | 数据重排 TB |
| 6 | `dma_rd` + `axi_rd_master` | a_loader, b_loader | AXI stub 回环 TB |
| 7 | `postproc` | systolic_core | FP32→FP16 转换 TB |
| 8 | `d_storer` | postproc | 打包 TB |
| 9 | `dma_wr` + `axi_wr_master` | d_storer | AXI stub 回环 TB |
| 10 | `csr_if` | 无 | CSR 读写 TB |
| 11 | `tile_scheduler` | csr_if, dma_rd, dma_wr, core | 端到端单 tile TB |
| 12 | `gemm_top` | 全部 | 端到端系统集成 TB |

#### M2: 功能完整（+ 边界处理 + 错误路径 + C 融合）

- `c_loader` + `fp_add_c`
- `err_checker`
- 边界 tile mask（非整 tile 裁剪）
- 完整状态机异常路径

#### M3: 性能优化（+ 双缓冲 + 性能计数器）

- `buffer_bank` ping-pong 切换
- `perf_counter`
- Burst 优化（max burst length）
- Bank 冲突仲裁增强

#### M4: 工程化（+ 中断 + 调试 + 回归）

- `irq_ctrl`（可并入 csr_if）
- `trace_debug_if`
- 覆盖率收敛
- 回归脚本

---

## 8. 验证规格

### 8.1 测试用例矩阵

| 维度 | 值 | 说明 |
|------|-----|------|
| M, N, K | 1, 4, 65, 1024, 2049 | 边界：1（最小）、4（对齐 tile）、65（非整 tile）、2049（大矩阵+1） |
| Tm, Tn, Tk | 4, 4, 64（默认） | tile 尺寸 |
| Stride | 连续、非连续 | 测试地址生成 |
| 数据模式 | 全0、全1、单位矩阵、随机 | 覆盖特殊值 |
| 数值类型 | 正常、subnormal、Inf、NaN | 后处理路径验证 |
| 累加模式 | FP16acc、FP32acc | 精度模式覆盖 |
| C 融合 | 旁路、启用 | postproc 路径覆盖 |

### 8.2 覆盖率目标

| 类型 | 目标 | 方法 |
|------|------|------|
| 行覆盖率 | >95% | 代码插桩 |
| FSM 状态覆盖率 | 100% | 所有状态/转换必须触发 |
| 分支覆盖率 | >90% | if/case 分支 |
| 表达式覆盖率 | >85% | 复杂条件 |
| 功能覆盖率 | 100% | 测试用例矩阵全部通过 |

### 8.3 参考模型接口

```python
# tools/golden_model.py
def gemm_fp16(A, B, C=None, acc_mode='fp32'):
    """
    A: MxK FP16 numpy array
    B: KxN FP16 numpy array
    C: MxN FP16 numpy array (optional)
    Returns: D MxN FP16
    """
    import numpy as np
    A_f = A.astype(np.float32)
    B_f = B.astype(np.float32)
    acc = A_f @ B_f  # FP32 accumulate
    if C is not None:
        C_f = C.astype(np.float32)
        acc = acc + C_f
    # Round to FP16
    return acc.astype(np.float16)
```

---

## 9. 寄存器映射（整合版）

### 9.1 CSR 地址空间（AXI4-Lite，16-bit 地址）

| 偏移 | 名称 | 类型 | 位域 | 说明 |
|------|------|------|------|------|
| 0x000 | CTRL | RW | [0] start(W1P), [1] soft_reset, [2] irq_en | 控制 |
| 0x004 | STATUS | RW | [0] busy, [1] done(W1C), [2] err | 状态 |
| 0x008 | ERR_CODE | RO | [3:0] | 错误码 |
| 0x00C | CORE_CTRL | RW | [0] core_en, [1] fp32_acc_en, [2] mask_en | 核心控制 |
| 0x010 | CORE_CFG0 | RW | [15:0] tk_cfg, [23:16] fill_guard, [31:24] drain_guard | 核心配置 |
| 0x014 | CORE_STATUS | RO | [0] core_busy, [1] core_done, [2] core_err | 核心状态 |
| 0x018 | CORE_ERR_CODE | RO | [0] illegal_mode, [1] protocol, [2] overflow | 核心错误 |
| 0x01C | CORE_PERF_ACTIVE | RO | [63:0] | 有效计算周期 |
| 0x024 | CORE_PERF_STALL | RO | [63:0] | 停滞周期 |
| 0x02C | CORE_PERF_FILL | RO | [63:0] | Fill 周期 |
| 0x034 | CORE_PERF_DRAIN | RO | [63:0] | Drain 周期 |
| 0x040 | DMA_CTRL | RW | [0] rd_en, [1] wr_en, [4:2] arb_mode | DMA 控制 |
| 0x044 | DMA_CFG0 | RW | [7:0] max_burst_len, [15:8] outstanding_rd, [23:16] outstanding_wr | DMA 配置 |
| 0x048 | DMA_STATUS | RO | [0] rd_busy, [1] wr_busy, [2] rd_done, [3] wr_done | DMA 状态 |
| 0x04C | DMA_ERR_CODE | RO | [0] addr_align, [1] cross_4k, [2] rresp_err, [3] bresp_err, [4] timeout | DMA 错误 |
| 0x050 | DMA_ERR_ADDR | RO | [63:0] | 错误地址 |
| 0x058 | DMA_PERF_RD_BYTES | RO | [63:0] | 读字节数 |
| 0x060 | DMA_PERF_WR_BYTES | RO | [63:0] | 写字节数 |
| 0x068 | BUF_CTRL | RW | [0] pp_enable, [1] reorder_en, [2] c_loader_en | Buffer 控制 |
| 0x06C | BUF_STATUS | RO | [0] load_busy, [1] store_busy, [2] switch_busy | Buffer 状态 |
| 0x070 | BUF_ERR_CODE | RO | [0] bank_oob, [1] addr_oob, [2] mask_illegal, [3] switch_conflict | Buffer 错误 |
| 0x074 | BUF_PERF_CONFLICT | RO | [63:0] | 冲突次数 |
| 0x07C | PP_CTRL | RW | [0] pp_en, [1] add_c_en, [2] sat_en | 后处理控制 |
| 0x080 | PP_CFG0 | RW | [1:0] round_mode, [4:2] nan_policy, [7:5] inf_policy | 后处理配置 |
| 0x084 | PP_STATUS | RO | [0] pp_busy, [1] pp_done | 后处理状态 |
| 0x088 | PP_NUM_NAN_CNT | RO | [31:0] | NaN 计数 |
| 0x08C | PP_NUM_INF_CNT | RO | [31:0] | Inf 计数 |
| 0x090 | PP_NUM_OVF_CNT | RO | [31:0] | 溢出计数 |
| 0x094 | PP_NUM_UDF_CNT | RO | [31:0] | 下溢计数 |
| 0x098 | MON_CTRL | RW | [0] mon_en, [1] trace_en, [2] freeze_cnt | 监控控制 |
| 0x09C | ERR_MASK | RW | [15:0] | 错误屏蔽 |
| 0x0A0 | ERR_STATUS | RO | [0] err_valid, [1] fatal, [2] warn | 错误状态 |
| 0x0A4 | TRACE_STATUS | RO | [0] trace_level, [1] trace_ovf | Trace 状态 |
| 0x100 | DIM_M | RW | [DIM_W-1:0] | M 维度 |
| 0x104 | DIM_N | RW | [DIM_W-1:0] | N 维度 |
| 0x108 | DIM_K | RW | [DIM_W-1:0] | K 维度 |
| 0x110 | ADDR_A | RW | [ADDR_W-1:0] | A 基址 |
| 0x118 | ADDR_B | RW | [ADDR_W-1:0] | B 基址 |
| 0x120 | ADDR_C | RW | [ADDR_W-1:0] | C 基址 |
| 0x128 | ADDR_D | RW | [ADDR_W-1:0] | D 基址 |
| 0x130 | STRIDE_A | RW | [STRIDE_W-1:0] | A stride |
| 0x134 | STRIDE_B | RW | [STRIDE_W-1:0] | B stride |
| 0x138 | STRIDE_C | RW | [STRIDE_W-1:0] | C stride |
| 0x13C | STRIDE_D | RW | [STRIDE_W-1:0] | D stride |
| 0x140 | TILE_M | RW | [TILE_W-1:0] | Tm |
| 0x144 | TILE_N | RW | [TILE_W-1:0] | Tn |
| 0x148 | TILE_K | RW | [TILE_W-1:0] | Tk |
| 0x14C | ARRAY_CFG | RO | [15:0] P_M, [31:16] P_N | 阵列配置（只读） |

---

## 10. 附录：错误码字典

| 模块 | 错误码 | 名称 | 说明 |
|------|--------|------|------|
| tile_scheduler | 1 | ILLEGAL_DIM | M/N/K = 0 或超过最大值 |
| tile_scheduler | 2 | ADDR_ALIGN | 地址未按 AXI 对齐 |
| tile_scheduler | 3 | ADDR_OOB | 地址越界 |
| tile_scheduler | 4 | PROTOCOL | start 时 busy |
| dma_rd | 5 | RD_ALIGN | 读地址对齐错误 |
| dma_rd | 6 | RD_CROSS_4K | burst 跨 4KB 边界 |
| dma_rd | 7 | RD_RRESP | AXI RRESP 非 OKAY |
| dma_rd | 8 | RD_TIMEOUT | 读超时 |
| dma_wr | 9 | WR_ALIGN | 写地址对齐错误 |
| dma_wr | 10 | WR_CROSS_4K | 写 burst 跨 4KB 边界 |
| dma_wr | 11 | WR_BRESP | AXI BRESP 非 OKAY |
| dma_wr | 12 | WR_TIMEOUT | 写超时 |
| buffer_bank | 13 | BUF_BANK_OOB | bank 选择越界 |
| buffer_bank | 14 | BUF_ADDR_OOB | 地址越界 |
| systolic_core | 15 | CORE_K_OVF | K 计数溢出 |
| systolic_core | 16 | CORE_PROTOCOL | start 时 busy |
| postproc | 17 | PP_ALIGN | 输入未对齐 |
| postproc | 18 | PP_ILLEGAL_MODE | 非法模式配置 |
| err_checker | 19 | MON_FATAL | 致命错误聚合 |
| err_checker | 20 | MON_WARN | 警告级错误聚合 |

---

**文档结束**  
**维护者**: 项目技术负责人  
**更新策略**: 每次新增模块 RTL 或变更接口时同步更新对应章节。
