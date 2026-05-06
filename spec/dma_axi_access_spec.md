# DMA & AXI Access Module Spec (Internal)

## 1. Revision History (Internal Documentation)

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1 | 2026-04-30 | Codex | Initial draft for DMA and AXI access modules (`dma_rd/rd_addr_gen/axi_rd_master/dma_wr/wr_addr_gen/axi_wr_master`). |
| v0.2 | 2026-05-02 | Digital Design | Complete port lists, FSM, and logic design. Align with RTL implementation. |
| v0.3 | 2026-05-04 | Digital Design | Align default parameters with RTL (BUF_BANKS=8, BUF_DEPTH=2048, MAX_BURST_LEN=16). Verified with Verilator. |

## 2. Terms/Abbreviations

- DMA: Direct Memory Access
- AXI: Advanced eXtensible Interface
- AXI4-Lite: AXI low-bandwidth control interface
- Burst: AXI INCR burst transaction
- Beat: One data transfer unit in a burst
- Outstanding: Issued but not yet completed AXI transaction count
- WSTRB: AXI write byte-lane strobe
- SLA: Scheduler-Level Arbitration（本文用于表示读请求选择策略）
- Tm/Tn/Tk: Tile size in M/N/K dimensions
- 4K: 4KB address boundary crossing
- AR: Read Address channel
- AW: Write Address channel
- R: Read Data channel
- W: Write Data channel
- B: Write Response channel

## 3. Overview

本规格覆盖 GEMM 数据搬运平面中的 DMA 与 AXI 访问子系统，目标是为 `A/B/C` 读入和 `D` 写回提供高吞吐、可裁剪边界、可错误上报的标准 AXI4 主设备行为。

覆盖模块：
- 读链路：`dma_rd`、`rd_addr_gen`、`axi_rd_master`
- 写链路：`dma_wr`、`wr_addr_gen`、`axi_wr_master`

### 3.1. Block Diagram

```text
                      +-------------------------+
                      | tile_scheduler          |
                      | rd_req / wr_req control |
                      +-----------+-------------+
                                  |
                 +----------------+----------------+
                 |                                 |
                 v                                 v
         +---------------+                 +---------------+
         | dma_rd        |                 | dma_wr        |
         | req arb + QoS |                 | req queue     |
         +------+--------+                 +------+--------+
                |                                 |
                v                                 v
         +---------------+                 +---------------+
         | rd_addr_gen   |                 | wr_addr_gen   |
         | burst split   |                 | burst split   |
         +------+--------+                 +------+--------+
                | AR cmd / len                      | AW/W cmd
                v                                   v
         +---------------+                 +---------------+
         | axi_rd_master |                 | axi_wr_master |
         | AR + R check  |                 | AW/W/B check  |
         +------+--------+                 +------+--------+
                |                                   |
                +--------------- AXI4 --------------+
                                DDR/HBM
```

### 3.2. Features

- 支持 A/B/C 多源读请求仲裁与顺序保持
- 支持 D tile 写回与边界裁剪
- 支持 stride 地址映射、按 burst 最大长度自动拆包
- 支持 AXI 错误响应上报（SLVERR/DECERR）
- 支持 backpressure（R/W 通道停顿）
- 支持可配置 outstanding 深度与 burst 长度上限
- 地址生成不跨 4KB 边界自动拆分

## 4. Port List and Parameters (Internal Documentation)

### 4.1 `dma_rd`

读请求仲裁与数据分发控制器。

#### 4.1.1 Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `ADDR_W` | int | 64 | 地址位宽 |
| `DIM_W` | int | 16 | 维度位宽 |
| `STRIDE_W` | int | 32 | stride 位宽 |
| `AXI_DATA_W` | int | 256 | AXI 数据位宽 |
| `MAX_BURST_LEN` | int | 16 | 最大 burst beat 数 |
| `OUTSTANDING_RD` | int | 8 | 最大读 outstanding 数 |

#### 4.1.2 Port List

| Signal | Direction | Width | Description |
|---|---|---|---|
| `clk` | Input | 1 | 主时钟 |
| `rst_n` | Input | 1 | 异步低有效复位 |

**读请求接口（来自 tile_scheduler）**

| `rd_req_valid` | Input | 1 | 读请求有效 |
| `rd_req_ready` | Output | 1 | 读请求就绪 |
| `rd_req_type` | Input | 2 | 请求类型：2'b00=A, 2'b01=B, 2'b10=C |
| `rd_req_base_addr` | Input | ADDR_W | tile 起始字节地址 |
| `rd_req_rows` | Input | DIM_W | tile 行数 |
| `rd_req_cols` | Input | DIM_W | tile 列数（元素数） |
| `rd_req_stride` | Input | STRIDE_W | 行 stride（字节） |
| `rd_req_last` | Input | 1 | 当前 scheduler 轮次的最后一个请求 |

**读数据输出（到 buffer loader）**

| `rd_data_valid` | Output | 1 | 读数据有效 |
| `rd_data_ready` | Input | 1 | 下游就绪 |
| `rd_data_payload` | Output | AXI_DATA_W | AXI R 通道数据 |
| `rd_data_last` | Output | 1 | 当前 burst 最后一 beat |
| `rd_data_type` | Output | 2 | 数据归属类型（A/B/C） |

**完成与错误**

| `rd_done` | Output | 1 | 读 tile 完成脉冲 |
| `rd_err` | Output | 1 | 读错误脉冲 |
| `rd_err_code` | Output | 8 | 错误码 |

**到 axi_rd_master 的内部命令接口**

| `axi_rd_cmd_valid` | Output | 1 | AR 命令有效 |
| `axi_rd_cmd_ready` | Input | 1 | AR 命令就绪 |
| `axi_rd_cmd_addr` | Output | ADDR_W | AR 地址 |
| `axi_rd_cmd_len` | Output | 8 | ARLEN（burst len-1） |
| `axi_rd_cmd_size` | Output | 3 | ARSIZE（log2(bytes/beat)） |

**从 axi_rd_master 的数据返回接口**

| `axi_rd_data_valid` | Input | 1 | R 通道数据有效 |
| `axi_rd_data_ready` | Output | 1 | R 通道数据就绪 |
| `axi_rd_data_payload` | Input | AXI_DATA_W | R 通道数据 |
| `axi_rd_data_last` | Input | 1 | RLAST |
| `axi_rd_resp` | Input | 2 | RRESP |

### 4.2 `rd_addr_gen`

2D tile 地址到线性 burst 序列生成器。

#### 4.2.1 Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `ADDR_W` | int | 64 | 地址位宽 |
| `DIM_W` | int | 16 | 维度位宽 |
| `STRIDE_W` | int | 32 | stride 位宽 |
| `AXI_DATA_W` | int | 256 | AXI 数据位宽 |
| `MAX_BURST_LEN` | int | 16 | 最大 burst beat 数 |

#### 4.2.2 Port List

| Signal | Direction | Width | Description |
|---|---|---|---|
| `clk` | Input | 1 | 主时钟 |
| `rst_n` | Input | 1 | 异步低有效复位 |
| `start` | Input | 1 | 开始生成脉冲（由 dma_rd 发出） |
| `base_addr` | Input | ADDR_W | tile 起始字节地址 |
| `rows` | Input | DIM_W | 行数 |
| `cols` | Input | DIM_W | 列元素数 |
| `stride` | Input | STRIDE_W | 行 stride（字节） |
| `elem_bytes` | Input | 3 | 每元素字节数（FP16=2） |

**Burst 命令输出**

| `cmd_valid` | Output | 1 | burst 命令有效 |
| `cmd_ready` | Input | 1 | burst 命令就绪 |
| `cmd_addr` | Output | ADDR_W | burst 起始地址 |
| `cmd_len` | Output | 8 | ARLEN（burst len-1） |
| `cmd_bytes` | Output | 16 | 本 burst 有效字节数 |
| `cmd_last` | Output | 1 | 当前 tile 最后一 burst |

### 4.3 `axi_rd_master`

AXI4 读主设备协议层。

#### 4.3.1 Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `ADDR_W` | int | 64 | 地址位宽 |
| `AXI_DATA_W` | int | 256 | AXI 数据位宽 |
| `AXI_ID_W` | int | 4 | AXI ID 位宽 |
| `MAX_BURST_LEN` | int | 16 | 最大 burst beat 数 |
| `OUTSTANDING_RD` | int | 8 | 最大 outstanding 数 |

#### 4.3.2 AXI AR Channel

| Signal | Direction | Width | Description |
|---|---|---|---|
| `m_axi_arvalid` | Output | 1 | ARVALID |
| `m_axi_arready` | Input | 1 | ARREADY |
| `m_axi_arid` | Output | AXI_ID_W | ARID |
| `m_axi_araddr` | Output | ADDR_W | ARADDR |
| `m_axi_arlen` | Output | 8 | ARLEN |
| `m_axi_arsize` | Output | 3 | ARSIZE |
| `m_axi_arburst` | Output | 2 | ARBURST = INCR |
| `m_axi_arcache` | Output | 4 | ARCACHE |
| `m_axi_arprot` | Output | 3 | ARPROT |

#### 4.3.3 AXI R Channel

| Signal | Direction | Width | Description |
|---|---|---|---|
| `m_axi_rvalid` | Input | 1 | RVALID |
| `m_axi_rready` | Output | 1 | RREADY |
| `m_axi_rid` | Input | AXI_ID_W | RID |
| `m_axi_rdata` | Input | AXI_DATA_W | RDATA |
| `m_axi_rresp` | Input | 2 | RRESP |
| `m_axi_rlast` | Input | 1 | RLAST |

#### 4.3.4 Internal Interfaces

| Signal | Direction | Width | Description |
|---|---|---|---|
| `cmd_valid` | Input | 1 | 内部 AR 命令有效 |
| `cmd_ready` | Output | 1 | 内部 AR 命令就绪 |
| `cmd_addr` | Input | ADDR_W | AR 地址 |
| `cmd_len` | Input | 8 | ARLEN |
| `cmd_size` | Input | 3 | ARSIZE |
| `data_valid` | Output | 1 | 内部数据有效 |
| `data_ready` | Input | 1 | 内部数据就绪 |
| `data_payload` | Output | AXI_DATA_W | 数据 |
| `data_last` | Output | 1 | 当前 burst 最后 beat |
| `resp_err` | Output | 1 | 收到 RRESP!=OKAY |

### 4.4 `dma_wr`

写请求控制器与数据汇聚。

#### 4.4.1 Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `ADDR_W` | int | 64 | 地址位宽 |
| `DIM_W` | int | 16 | 维度位宽 |
| `STRIDE_W` | int | 32 | stride 位宽 |
| `AXI_DATA_W` | int | 256 | AXI 数据位宽 |
| `MAX_BURST_LEN` | int | 16 | 最大 burst beat 数 |
| `OUTSTANDING_WR` | int | 8 | 最大写 outstanding 数 |

#### 4.4.2 Port List

| Signal | Direction | Width | Description |
|---|---|---|---|
| `clk` | Input | 1 | 主时钟 |
| `rst_n` | Input | 1 | 异步低有效复位 |

**写请求接口（来自 tile_scheduler）**

| `wr_req_valid` | Input | 1 | 写请求有效 |
| `wr_req_ready` | Output | 1 | 写请求就绪 |
| `wr_req_base_addr` | Input | ADDR_W | tile 起始字节地址 |
| `wr_req_rows` | Input | DIM_W | tile 行数 |
| `wr_req_cols` | Input | DIM_W | tile 列元素数 |
| `wr_req_stride` | Input | STRIDE_W | 行 stride（字节） |
| `wr_req_last` | Input | 1 | 当前 scheduler 轮次的最后一个请求 |

**写数据输入（来自 d_storer）**

| `wr_data_valid` | Input | 1 | 写数据有效 |
| `wr_data_ready` | Output | 1 | 写数据就绪 |
| `wr_data_payload` | Input | AXI_DATA_W | 写数据 |
| `wr_data_last` | Input | 1 | 当前 burst 最后 beat |

**完成与错误**

| `wr_done` | Output | 1 | 写 tile 完成脉冲 |
| `wr_err` | Output | 1 | 写错误脉冲 |
| `wr_err_code` | Output | 8 | 错误码 |

**到 axi_wr_master 的内部接口**

| `axi_wr_cmd_valid` | Output | 1 | AW 命令有效 |
| `axi_wr_cmd_ready` | Input | 1 | AW 命令就绪 |
| `axi_wr_cmd_addr` | Output | ADDR_W | AW 地址 |
| `axi_wr_cmd_len` | Output | 8 | AWLEN |
| `axi_wr_cmd_size` | Output | 3 | AWSIZE |
| `axi_wr_data_valid` | Output | 1 | W 通道数据有效 |
| `axi_wr_data_ready` | Input | 1 | W 通道数据就绪 |
| `axi_wr_data_payload` | Output | AXI_DATA_W | WDATA |
| `axi_wr_data_last` | Output | 1 | WLAST |
| `axi_wr_data_strb` | Output | AXI_DATA_W/8 | WSTRB |
| `axi_wr_resp` | Input | 2 | BRESP |
| `axi_wr_resp_valid` | Input | 1 | BVALID |

### 4.5 `wr_addr_gen`

2D tile 地址到线性 burst 序列生成器（写侧）。

#### 4.5.1 Parameters

同 `rd_addr_gen`。

#### 4.5.2 Port List

同 `rd_addr_gen`，信号名前缀由 `cmd_` 改为 `wr_cmd_`。

### 4.6 `axi_wr_master`

AXI4 写主设备协议层。

#### 4.6.1 Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `ADDR_W` | int | 64 | 地址位宽 |
| `AXI_DATA_W` | int | 256 | AXI 数据位宽 |
| `AXI_ID_W` | int | 4 | AXI ID 位宽 |
| `MAX_BURST_LEN` | int | 16 | 最大 burst beat 数 |
| `OUTSTANDING_WR` | int | 8 | 最大 outstanding 数 |

#### 4.6.2 AXI AW Channel

| Signal | Direction | Width | Description |
|---|---|---|---|
| `m_axi_awvalid` | Output | 1 | AWVALID |
| `m_axi_awready` | Input | 1 | AWREADY |
| `m_axi_awid` | Output | AXI_ID_W | AWID |
| `m_axi_awaddr` | Output | ADDR_W | AWADDR |
| `m_axi_awlen` | Output | 8 | AWLEN |
| `m_axi_awsize` | Output | 3 | AWSIZE |
| `m_axi_awburst` | Output | 2 | AWBURST = INCR |
| `m_axi_awcache` | Output | 4 | AWCACHE |
| `m_axi_awprot` | Output | 3 | AWPROT |

#### 4.6.3 AXI W Channel

| Signal | Direction | Width | Description |
|---|---|---|---|
| `m_axi_wvalid` | Output | 1 | WVALID |
| `m_axi_wready` | Input | 1 | WREADY |
| `m_axi_wdata` | Output | AXI_DATA_W | WDATA |
| `m_axi_wstrb` | Output | AXI_DATA_W/8 | WSTRB |
| `m_axi_wlast` | Output | 1 | WLAST |

#### 4.6.4 AXI B Channel

| Signal | Direction | Width | Description |
|---|---|---|---|
| `m_axi_bvalid` | Input | 1 | BVALID |
| `m_axi_bready` | Output | 1 | BREADY |
| `m_axi_bid` | Input | AXI_ID_W | BID |
| `m_axi_bresp` | Input | 2 | BRESP |

#### 4.6.5 Internal Interfaces

| Signal | Direction | Width | Description |
|---|---|---|---|
| `cmd_valid` | Input | 1 | AW 命令有效 |
| `cmd_ready` | Output | 1 | AW 命令就绪 |
| `cmd_addr` | Input | ADDR_W | AW 地址 |
| `cmd_len` | Input | 8 | AWLEN |
| `cmd_size` | Input | 3 | AWSIZE |
| `data_valid` | Input | 1 | W 通道数据有效 |
| `data_ready` | Output | 1 | W 通道数据就绪 |
| `data_payload` | Input | AXI_DATA_W | WDATA |
| `data_last` | Input | 1 | WLAST |
| `data_strb` | Input | AXI_DATA_W/8 | WSTRB |
| `resp_err` | Output | 1 | 收到 BRESP!=OKAY |

### 4.7 Key Parameters (Summary)

| Parameter | Type | Default | Description |
|---|---|---|---|
| `ADDR_W` | int | 64 | 地址位宽 |
| `AXI_DATA_W` | int | 256 | AXI 数据位宽 |
| `AXI_ID_W` | int | 4 | AXI ID 位宽 |
| `MAX_BURST_LEN` | int | 16 | 最大 burst beat 数（AXI len=15） |
| `OUTSTANDING_RD` | int | 8 | 最大读 outstanding 数 |
| `OUTSTANDING_WR` | int | 8 | 最大写 outstanding 数 |
| `ALIGN_BYTES` | int | AXI_DATA_W/8 | 总线对齐字节数（256-bit = 32） |

## 5. Functional Descriptions

### 5.1. Normal Function

1. `tile_scheduler` 下发读写请求（含 base/stride/rows/cols/type/last）
2. `dma_rd` 仲裁 A/B/C 请求，按 round-robin 送入 `rd_addr_gen`
3. `rd_addr_gen` 将 2D tile 映射为一串线性 burst 命令
4. `axi_rd_master` 按 AXI4 协议发起 AR 事务，接收 R 数据并回传
5. `dma_rd` 将 R data 按类型分发到对应 buffer loader（A→a_loader, B→b_loader, C→postproc）
6. `dma_wr` 接收 `d_storer` 数据，送入 `wr_addr_gen` 生成 burst 序列
7. `axi_wr_master` 按 AXI4 协议发起 AW/W 事务，等待 B 响应
8. 正常完成后上报 `rd_done/wr_done`

### 5.1.1. Configuration Methods(Optional)

可由 CSR 控制如下策略：
- `MAX_BURST_LEN`（如 16/32/64 beat）
- `OUTSTANDING_RD/WR`
- 读仲裁优先级（A-first/B-first/round-robin）
- 写回阈值（水位触发）

### 5.2. Diagnostic Function(Optional)

建议导出诊断状态：
- 当前命令队列深度
- outstanding 计数
- 最后一次错误地址/错误类型
- burst 拆分次数、短包次数

### 5.2.1. Configuration Methods(Optional)

通过 `DEBUG_DMA_CTRL` 可选使能：
- `dbg_snapshot_en`
- `dbg_hold_on_err`

## 6. Test/Debug Modes (Internal Documentation)

- `dma_loopback_mode`（可选）：地址生成保留，AXI 响应可由 TB stub 回环
- `axi_force_backpressure`（可选）：注入 ready 抖动验证稳健性

### 6.1.1. Configuration Methods

- `DEBUG_DMA_MODE[0]`：loopback
- `DEBUG_DMA_MODE[1]`：force_backpressure
- `DEBUG_DMA_MODE[2]`：force_error_rsp

## 7. Architecture Descriptions (Internal Documentation)

### 7.1. Architecture Overview

DMA/AXI 访问由“请求收敛层 + 地址生成层 + AXI协议层”组成：
- 请求收敛层：`dma_rd/dma_wr`
- 地址生成层：`rd_addr_gen/wr_addr_gen`
- 协议层：`axi_rd_master/axi_wr_master`

分层目的：便于将地址算法与总线协议解耦，提高可复用性。

### 7.2. Clocks and Resets

- 默认单时钟域：`clk`
- 异步低有效复位：`rst_n`
- 复位后：
  - 命令队列清空
  - outstanding 清零
  - `*_done/*_err` 复位

### 7.2.1. Clock and Reset Description / Logic Circuit (Optional)

- `cmd_valid` 与 `cmd_ready` 采用寄存化握手
- 复位撤销后等待 1 拍才允许发首个 AR/AW

### 7.2.2. CDC Synchronization Scheme (Optional)

若 buffer 或 scheduler 在其他频域：
- 命令路径：异步 FIFO（带 almost_full）
- 状态路径：双触发器同步 + 脉冲拉伸

### 7.2.3. RDC Synchronization Scheme (Optional)

- `done/err` 使用电平保持直到对端 ack
- 各域复位撤销后以“域内 ready”为准逐步开放流量

### 7.3. Top Main Interfaces (Optional)

- 上游控制：`tile_scheduler`
- 下游数据：`buffer_bank`/`d_storer`
- 外部内存：AXI4 Master

### 7.4. Architecture Scheme Comparison (Optional)

- 方案 A：单一共享读主机（A/B/C 同一 `axi_rd_master`）
  - 优点：面积小，易验证
  - 缺点：高并发下仲裁压力大
- 方案 B：A/B 与 C 分离读主机
  - 优点：可降低干扰，吞吐更稳
  - 缺点：面积与接口复杂度增加

建议初版采用方案 A，性能版本再评估方案 B。

### 7.5. Sub-Module `dma_rd_ctl`

#### 7.5.1. Overview

负责请求接入、仲裁、顺序管理、完成与错误聚合。

#### 7.5.2. Logic Design

**状态机：**

```
IDLE -> (rd_req_valid) -> ARB
ARB -> (selected && addr_gen_ready) -> ISSUE
ISSUE -> (cmd_sent && !last_burst) -> ISSUE
ISSUE -> (cmd_sent && last_burst) -> WAIT_DATA
WAIT_DATA -> (all_data_returned) -> DONE
DONE -> (1 cycle) -> IDLE
(any state + err) -> ERR
```

- `ARB` 状态按 round-robin 选择 A/B/C 请求
- 仅当 `cmd_fifo_not_full && credit_available` 时发命令
- R 通道按返回顺序写入目标 buffer lane
- 若 `RRESP!=OKAY`，锁存 `rd_err` 并进入 ERR

**Outstanding 管理：**
- 每发一个 AR 命令 `os_cnt++`
- 每收到一个 RLAST `os_cnt--`
- `os_cnt < OUTSTANDING_RD` 时才允许发下一个 AR

### 7.6. Sub-Module `rd_addr_gen`

#### 7.6.1. Overview

将 2D tile 地址映射为线性 burst 命令序列。

#### 7.6.2. Logic Design

**核心算法（逐行迭代）：**

```
for row = 0 to rows-1:
    row_base = base_addr + row * stride
    bytes_in_row = cols * elem_bytes
    col_offset = 0
    while bytes_in_row > 0:
        // 4KB 边界检查
        max_to_4k = 4096 - (row_base & 0xFFF)
        // burst 长度限制
        max_burst_bytes = MAX_BURST_LEN * (AXI_DATA_W/8)
        // 取最小值
        this_burst = min(bytes_in_row, max_burst_bytes, max_to_4k)
        // 对齐到 beat 边界
        beats = (this_burst + BEAT_BYTES - 1) / BEAT_BYTES
        if beats > MAX_BURST_LEN: beats = MAX_BURST_LEN
        // 输出命令
        emit cmd_addr=row_base, cmd_len=beats-1, cmd_bytes=this_burst
        row_base += this_burst
        bytes_in_row -= this_burst
        col_offset += this_burst
```

**状态机：**

```
IDLE -> (start) -> CALC
CALC -> (cmd_ready) -> EMIT
EMIT -> (bytes_rem > 0 && cmd_ready) -> CALC
EMIT -> (bytes_rem == 0 && row < rows-1) -> NEXT_ROW
EMIT -> (bytes_rem == 0 && row == rows-1) -> DONE
DONE -> (1 cycle) -> IDLE
```

**关键寄存器：**

| 寄存器 | 位宽 | 说明 |
|---|---|---|
| `row_cnt` | DIM_W | 当前行索引 |
| `col_rem` | DIM_W*elem_bytes | 当前行剩余字节 |
| `cur_addr` | ADDR_W | 当前 burst 起始地址 |
| `last_flag` | 1 | 当前 burst 是否为 tile 最后一 burst |

### 7.7. Sub-Module `axi_rd_master`

#### 7.7.1. Overview

AXI4 读主设备协议层，处理 AR/R 通道握手与 outstanding。

#### 7.7.2. Logic Design

**AR 通道状态机：**

```
AR_IDLE -> (cmd_valid && os_credit) -> AR_VALID
AR_VALID -> (m_axi_arready) -> AR_IDLE
```

- `m_axi_arvalid` 在 `AR_VALID` 状态置位
- 收到 `m_axi_arready` 后退回 `AR_IDLE`
- AR 命令存入 outstanding FIFO（深度 OUTSTANDING_RD）

**R 通道处理：**

```
R_IDLE -> (m_axi_rvalid) -> R_RECV
R_RECV -> (m_axi_rlast) -> R_IDLE
```

- 收到 `m_axi_rvalid` 输出 `data_valid`
- `m_axi_rlast` 时输出 `data_last`
- 若 `m_axi_rresp != 2'b00`（OKAY），置位 `resp_err`

**Outstanding 计数：**
- 发 AR 时 `os_cnt++`
- 收 RLAST 时 `os_cnt--`
- `os_cnt < OUTSTANDING_RD` 为允许发 AR 的条件之一

### 7.8. Sub-Module `dma_wr_ctl`

#### 7.8.1. Overview

写请求控制器，将 D tile 数据组织为 burst 写回。

#### 7.8.2. Logic Design

**状态机：**

```
IDLE -> (wr_req_valid) -> GET_ADDR
GET_ADDR -> (addr_gen_cmd_valid) -> WAIT_DATA
WAIT_DATA -> (wr_data_valid && wr_data_last) -> ISSUE_AW
ISSUE_AW -> (axi_aw_ready) -> WAIT_B
WAIT_B -> (axi_b_valid) -> DONE/ERR
DONE -> (1 cycle) -> IDLE
```

**WSTRB 生成：**
- 正常 beat：`WSTRB = {BEAT_BYTES{1'b1}}`
- 行尾短包：`WSTRB` 按 `cmd_bytes % BEAT_BYTES` 置位低位
- tile 最后一 burst 的最后一 beat 按实际有效字节数生成 strobe

### 7.9. Sub-Module `wr_addr_gen`

#### 7.9.1. Overview

写侧地址生成器，与 `rd_addr_gen` 同构。

#### 7.9.2. Logic Design

- 算法与 `rd_addr_gen` 完全一致（逐行迭代 + 4K 拆分 + burst 限制）
- 输出信号前缀为 `wr_cmd_*`

### 7.10. Sub-Module `axi_wr_master`

#### 7.10.1. Overview

AXI4 写主设备协议层，处理 AW/W/B 通道。

#### 7.10.2. Logic Design

**AW 通道状态机：**

```
AW_IDLE -> (cmd_valid && os_credit) -> AW_VALID
AW_VALID -> (m_axi_awready) -> AW_IDLE
```

**W 通道状态机：**

```
W_IDLE -> (data_valid) -> W_VALID
W_VALID -> (m_axi_wready) -> W_IDLE
W_VALID -> (data_last && m_axi_wready) -> W_IDLE
```

**B 通道处理：**

```
B_IDLE -> (m_axi_bvalid) -> B_RECV
B_RECV -> (resp sampled) -> B_IDLE
```

- 收到 `m_axi_bvalid` 采样 `BRESP`
- 若 `BRESP != OKAY`，置位 `resp_err`
- `m_axi_bready` 在 `B_IDLE` 时置位（始终准备接收）

**Outstanding 管理：**
- 发 AW 时 `os_cnt++`
- 收 B 时 `os_cnt--`

### 7.11. Data Path Design

#### 7.11.1. 读数据通路

```
tile_scheduler rd_req -> dma_rd arb -> rd_addr_gen -> axi_rd_master AR
                                                             |
                                                        DDR/HBM
                                                             |
dma_rd rd_data -> a_loader / b_loader / postproc (c_data) <- R
```

#### 7.11.2. 写数据通路

```
d_storer wr_data -> dma_wr -> wr_addr_gen -> axi_wr_master AW/W
                                                    |
                                               DDR/HBM
                                                    |
                                               <- B
```

### 7.12. Low Power Design (Optional)

- 空闲时关闭 burst-split 组合逻辑输入翻转（寄存保持）
- outstanding=0 且无请求时可门控协议层局部时钟（如实现）

### 7.13. Architecture Open Issues (Optional)

- 是否引入写合并缓存以提升小 tile 写效率
- C 读是否与 A/B 完全解耦独立通道
- 错误恢复策略：当前默认 stop-on-error

## 8. Integration Guide (Internal Documentation)

- 与 `tile_scheduler` 对接：
  - 统一请求描述符字段定义（base/rows/cols/stride/type/last）
  - 统一 `req_valid/req_ready/done/err` 时序约定
- 与 `buffer_bank` 对接：
  - 明确数据宽度转换责任边界
  - 明确 `data_last` 语义（burst-last vs tile-last）
- AXI 总线集成：
  - 检查互连对 outstanding 和 burst 长度限制
  - 配置 QoS/Region（若 SoC 互连支持）

## 9. Implementation Guide (Internal Documentation)

- MVP 阶段建议：
  1. 先完成 `rd_addr_gen/wr_addr_gen` 纯功能仿真
  2. 再接入 `axi_rd_master/axi_wr_master` 协议层
  3. 最后集成 `dma_rd/dma_wr` 仲裁与错误处理
- 编码建议：
  - 地址计算统一使用字节地址
  - 所有计数器显式位宽并处理溢出
  - 错误码分层（地址类/协议类/内部超时）

## 10. Verification Guide (Internal Documentation)

### 10.1. 最小用例

| 测试 | 描述 |
|---|---|
| T1 | 连续地址满对齐 tile（256-bit 对齐） |
| T2 | 非连续 stride tile |
| T3 | 边界短包（行尾不足一个 beat） |
| T4 | 4KB 边界前后拆包 |
| T5 | A/B/C 仲裁轮询 |

### 10.2. 异常用例

| 测试 | 描述 |
|---|---|
| T6 | 注入 `RRESP=SLVERR/DECERR` |
| T7 | 注入 `BRESP=SLVERR/DECERR` |
| T8 | 长时间 backpressure（ready 拉低） |
| T9 | reset 中断事务 |
| T10 | outstanding 满后反压上游 |

### 10.3. 覆盖建议

- burst len 覆盖（1, 2, 4, 8, 16 beat）
- outstanding 深度覆盖（0 到 max）
- A/B/C 仲裁路径覆盖
- 4KB 边界前/后/恰好对齐

## 11. Registers

建议 CSR（示例）：

| 名称 | 偏移 | 类型 | 说明 |
|---|---|---|---|
| `DMA_CTRL` | 0x000 | RW | bit0 `rd_en`, bit1 `wr_en`, bit4:2 `arb_mode` |
| `DMA_CFG0` | 0x004 | RW | `max_burst_len`, `outstanding_rd`, `outstanding_wr` |
| `DMA_STATUS` | 0x008 | RO | `rd_busy`, `wr_busy`, `rd_done`, `wr_done` |
| `DMA_ERR_CODE` | 0x00C | RO | bit0 `addr_align_err`, bit1 `cross_4k_err`, bit2 `axi_rresp_err`, bit3 `axi_bresp_err`, bit4 `timeout_err` |
| `DMA_ERR_ADDR` | 0x010 | RO | 最近错误地址 |
| `DMA_PERF_RD_BYTES` | 0x014 | RO | 读字节计数 |
| `DMA_PERF_WR_BYTES` | 0x018 | RO | 写字节计数 |
| `DMA_PERF_RD_STALL` | 0x01C | RO | 读 stall 周期 |
| `DMA_PERF_WR_STALL` | 0x020 | RO | 写 stall 周期 |

## 12. Reference (Internal Documentation)

- ARM AMBA AXI4 Protocol Specification（用于 AR/AW/W/R/B 行为约束）
- 本仓库文档：`ARCHITECTURE.md`
- 本仓库文档：`spec/modules.md`

## 13. Open Issues & Workaround (Internal Documentation)

1. **Open Issue**: 小矩阵/窄行场景写带宽利用率低。  
   **Workaround**: 提高 tile 聚合度或引入 write-combine FIFO。
2. **Open Issue**: 高 backpressure 时读写互扰导致延迟抖动。  
   **Workaround**: 分离读写限流阈值并启用 QoS。
3. **Open Issue**: 边界条件下短包数量增加影响效率。  
   **Workaround**: 调整 `Tm/Tn` 使 tile 更接近总线对齐边界。
