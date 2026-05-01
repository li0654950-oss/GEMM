# DMA & AXI Access Module Spec (Internal)

## 1. Revision History (Internal Documentation)

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1 | 2026-04-30 | Codex | Initial draft for DMA and AXI access modules (`dma_rd/rd_addr_gen/axi_rd_master/dma_wr/wr_addr_gen/axi_wr_master`). |

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

## 4. Port List and Parameters (Internal Documentation)

> 端口命名按建议风格给出，具体 RTL 可按工程命名规范落地。

### 4.1 `dma_rd`

- Input
  - `clk`, `rst_n`
  - `rd_req_valid`, `rd_req_type[1:0]`（A/B/C）
  - `rd_req_base_addr[ADDR_W-1:0]`
  - `rd_req_rows`, `rd_req_cols`, `rd_req_stride`
  - `rd_req_ready_from_buffer`
  - `axi_rd_cmd_ready`
- Output
  - `rd_req_ready`
  - `axi_rd_cmd_valid`
  - `axi_rd_cmd_addr`, `axi_rd_cmd_len`, `axi_rd_cmd_size`
  - `rd_data_valid`, `rd_data_last`, `rd_data_payload`
  - `rd_done`, `rd_err`, `rd_err_code`

### 4.2 `rd_addr_gen`

- Input: tile descriptors (`m0/n0/k0`, rows/cols/stride/base)
- Output: linearized burst command stream (`addr/bytes/last`)

### 4.3 `axi_rd_master`

- AXI AR channel: `m_axi_ar*`
- AXI R channel: `m_axi_r*`
- Internal command/data interface:
  - `cmd_valid/ready`, `cmd_addr/len/size`
  - `data_valid/ready`, `data_last`, `data`
  - `resp_err`

### 4.4 `dma_wr`

- Input
  - `wr_req_valid`
  - `wr_req_base_addr`, `wr_req_rows`, `wr_req_cols`, `wr_req_stride`
  - `wr_data_valid`, `wr_data_last`, `wr_data_payload`
  - `axi_wr_cmd_ready`, `axi_wr_data_ready`
- Output
  - `wr_req_ready`
  - `axi_wr_cmd_valid`
  - `axi_wr_cmd_addr`, `axi_wr_cmd_len`, `axi_wr_cmd_size`
  - `axi_wr_data_valid`, `axi_wr_data_last`, `axi_wr_data_payload`, `axi_wr_strb`
  - `wr_done`, `wr_err`, `wr_err_code`

### 4.5 `wr_addr_gen`

- Input: D tile geometry + stride/base
- Output: AW burst sequence + line end metadata

### 4.6 `axi_wr_master`

- AXI AW/W/B channels: `m_axi_aw*`, `m_axi_w*`, `m_axi_b*`
- Internal command/data interface同上

### 4.7 Key Parameters

- `ADDR_W` (default 64)
- `AXI_DATA_W` (default 256)
- `AXI_ID_W` (default 4)
- `MAX_BURST_LEN` (default 16 beats, AXI len=15)
- `OUTSTANDING_RD` (default 8)
- `OUTSTANDING_WR` (default 8)
- `ALIGN_BYTES` (`AXI_DATA_W/8`)

## 5. Functional Descriptions

### 5.1. Normal Function

1. `tile_scheduler` 下发读写请求（含 base/stride/rows/cols）
2. `*_addr_gen` 将 2D tile 映射为一串线性 burst
3. `axi_*_master` 发起 AXI 事务并处理响应
4. `dma_rd` 将 R data 写入后级 buffer path
5. `dma_wr` 从后级接收 D data，组织并写回内存
6. 正常完成后上报 `rd_done/wr_done`

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

### 7.5. Sub-Module XXX_CTL (Optional)

此处 `XXX_CTL` 对应 `dma_rd/dma_wr` 控制逻辑。

### 7.5.1. Overview

- 负责请求接入、顺序管理、完成与错误聚合

### 7.5.2. Sub-Module XXX_RDCTL

#### 7.5.2.1. Overview

- 仲裁 A/B/C 读请求，维持 request tag

#### 7.5.2.2. Logic Design

- 策略：Round-robin（默认）
- 仅当 `cmd_fifo_not_full && credit_available` 时发命令
- R 通道按返回顺序写入目标 buffer lane
- 若 `RRESP!=OKAY`，锁存 `rd_err` 并中止当前任务

### 7.5.3.  Sub-Module XXX_WRCTL

#### 7.5.3.1. Overview

- 将 D 数据流按 burst 聚合后写回

#### 7.5.3.2. Logic Design

- 数据对齐到 `AXI_DATA_W`，按 lane 生成 `WSTRB`
- 行尾不足一个 beat 时生成短写 strobe
- 等待对应 B 响应后才回收 outstanding credit

### 7.5.4.  Logic Design

建议状态机：
- RD: `IDLE -> ISSUE_AR -> RECV_R -> DONE/ERR`
- WR: `IDLE -> ISSUE_AW -> SEND_W -> WAIT_B -> DONE/ERR`

### 7.6. Sub-Module XXX_DP (Optional)

`XXX_DP` 对应地址/计数 datapath：
- 行列计数器
- 当前地址寄存器
- burst remnant bytes 计数
- last/short-burst 标志生成

### 7.7. Sub-Module XXX_MEM(Optional)

- `cmd_fifo`
- `resp_fifo`（可选）
- debug shadow registers（可选）

### 7.8. Logic Design (Optional)

地址生成核心（读/写同构）：
1. `row_base = base + row_idx * stride`
2. `bytes_in_row = col_elems * elem_bytes`
3. 对 `bytes_in_row` 按 `MAX_BURST_BYTES` 迭代拆分
4. 每包约束：
   - 不跨 4KB 边界
   - `ARLEN/AWLEN <= MAX_BURST_LEN-1`
   - `addr` 满足总线最小对齐要求

### 7.9. Low Power Design (Optional)

- 空闲时关闭 burst-split 组合逻辑输入翻转（寄存保持）
- outstanding=0 且无请求时可门控协议层局部时钟（如实现）

### 7.10. Architecture Open Issues (Optional)

- 是否引入写合并缓存以提升小 tile 写效率
- C 读是否与 A/B 完全解耦独立通道
- 错误恢复策略：当前默认 stop-on-error

## 8. Integration Guide (Internal Documentation)

- 与 `tile_scheduler` 对接：
  - 统一请求描述符字段定义（base/rows/cols/stride/type）
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

- 最小用例：
  - 连续地址满对齐 tile
  - 非连续 stride tile
  - 边界短包（行尾不足一个 beat）
  - 4KB 边界前后拆包
- 异常用例：
  - 注入 `RRESP/BRESP=SLVERR/DECERR`
  - 长时间 backpressure
  - reset 中断事务
- 覆盖建议：
  - burst len 覆盖（1, 2, 4, 8, 16...）
  - outstanding 深度覆盖（0 到 max）
  - A/B/C 仲裁路径覆盖

## 11. Registers

建议 CSR（示例）：
- `DMA_CTRL`
  - bit0 `rd_en`
  - bit1 `wr_en`
  - bit4:2 `arb_mode`
- `DMA_CFG0`
  - `max_burst_len`
  - `outstanding_rd`
  - `outstanding_wr`
- `DMA_STATUS`
  - `rd_busy`, `wr_busy`, `rd_done`, `wr_done`
- `DMA_ERR_CODE`
  - bit0 `addr_align_err`
  - bit1 `cross_4k_err`
  - bit2 `axi_rresp_err`
  - bit3 `axi_bresp_err`
  - bit4 `timeout_err`
- `DMA_ERR_ADDR`
  - 最近错误地址
- `DMA_PERF_RD_BYTES`, `DMA_PERF_WR_BYTES`
- `DMA_PERF_RD_STALL`, `DMA_PERF_WR_STALL`

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
