# On-chip Buffer & Data Reorder Module Spec (Internal)

## 1. Revision History (Internal Documentation)

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1 | 2026-04-30 | Codex | Initial draft for on-chip buffer and data-reorder modules. |
| v0.2 | 2026-05-02 | Digital Design | Complete port lists, address mapping, ping-pong FSM, bank arbitration, reorder logic, and integration with systolic_core/array_io_adapter. |
| v0.3 | 2026-05-04 | Digital Design | Update default parameters: BUF_BANKS=8, BUF_DEPTH=2048. Verified with Verilator. |

## 2. Terms/Abbreviations

- SRAM: Static Random Access Memory
- Bank: 独立可并行访问的存储体
- Ping-Pong: 双缓冲角色切换机制（A/B 各 2 套 buffer）
- Reorder: 数据重排/布局转换（DMA 顺序 → 阵列注入顺序）
- Tile: 分块矩阵片段
- Lane: 并行数据通道（对应 PE 行/列）
- Conflict: 多请求访问同一 bank 冲突
- Skid Buffer: 握手停顿保护缓存
- Beat: AXI 突发传输中的一拍数据
- Element: FP16 数据元素（16-bit）

## 3. Overview

本规格定义 GEMM 片上缓存与数据重排模块，覆盖：
- `buffer_bank`：统一 SRAM 存储，含 A_BUF[2] / B_BUF[2] / C_BUF
- `a_loader`：A tile 装载 + 行优先重排
- `b_loader`：B tile 装载 + 列优先重排
- `c_loader`（可选）：C tile 预取
- `d_storer`：D tile 收集 + 打包

目标：在 DMA 读/写与阵列计算之间建立高带宽、低冲突、可边界处理的数据中转层。

### 3.1. Block Diagram

```text
                     AXI RD (from dma_rd)
                         |
              +----------+----------+
              |                     |
              v                     v
        +-----------+         +-----------+
        | a_loader  |         | b_loader  |
        | reorder   |         | reorder   |
        +-----+-----+         +-----+-----+
              |                     |
              v                     v
        +-----------+         +-----------+
        | A_BUF[0]  |         | B_BUF[0]  |
        | A_BUF[1]  |         | B_BUF[1]  |
        +-----+-----+         +-----+-----+
              |                     |
              +----------+----------+
                         |
                         v
                +-------------------+
                | array_io_adapter  |
                | skew + valid gen  |
                +---------+---------+
                          |
                          v
                     systolic_core
                          |
                          v
                     postproc
                          |
                          v
                +-------------------+
                | d_storer          |
                | gather + pack     |
                +---------+---------+
                          |
                          v
                     AXI WR (to dma_wr)
```

### 3.2. Features

- A/B 双缓冲（Ping-Pong）：一侧计算、一侧 DMA 装载
- A 按行优先存储，B 按列优先存储，匹配阵列注入方向
- C_BUF 独立（可选），供 postproc `+C` 融合
- Bank 冲突仲裁 + skid buffer backpressure
- 边界 tile mask：不足行/列的 element 自动置零
- d_storer 收集 postproc 输出并打包为 AXI beat 格式

## 4. Port List and Parameters (Internal Documentation)

### 4.1 Global Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `P_M` | int | 4 | 阵列行数 |
| `P_N` | int | 4 | 阵列列数 |
| `ELEM_W` | int | 16 | FP16 元素位宽 |
| `ACC_W` | int | 32 | 累加器位宽 |
| `BUF_BANKS` | int | 8 | 每套 buffer 的 bank 数 |
| `BUF_DEPTH` | int | 2048 | 每个 bank 的 entry 数 |
| `AXI_DATA_W` | int | 256 | AXI 数据位宽 |
| `PP_ENABLE` | bit | 1'b1 | 使能 ping-pong |

### 4.2 `buffer_bank`

`buffer_bank` 是统一 SRAM 存储层，包含 A_BUF[0/1]、B_BUF[0/1]、C_BUF。
每套 buffer 内含 `BUF_BANKS` 个独立 bank，支持 1R1W（单口）或 1R+1W（伪双口）SRAM。

#### 4.2.1 Port List — Write Interface (from loaders)

| Signal | Direction | Width | Description |
|---|---|---|---|
| `clk` | Input | 1 | 主时钟 |
| `rst_n` | Input | 1 | 异步低有效复位 |
| `wr_valid` | Input | 1 | 写请求有效 |
| `wr_ready` | Output | 1 | 写端口可接收 |
| `wr_sel` | Input | 2 | 目标 buffer 选择：`0=A_BUF[0], 1=A_BUF[1], 2=B_BUF[0], 3=B_BUF[1], 4=C_BUF` |
| `wr_bank` | Input | $clog2(BUF_BANKS) | 目标 bank 号 |
| `wr_addr` | Input | $clog2(BUF_DEPTH) | bank 内地址 |
| `wr_data` | Input | AXI_DATA_W | 写入数据（256-bit beat，含多个 FP16） |
| `wr_mask` | Input | AXI_DATA_W/8 | 字节写掩码（边界 tile 部分 beat 使用） |

#### 4.2.2 Port List — Read Interface (to array_io_adapter)

| Signal | Direction | Width | Description |
|---|---|---|---|
| `rd_req_valid` | Input | 1 | 读请求有效 |
| `rd_req_ready` | Output | 1 | 读端口可接受请求 |
| `rd_sel` | Input | 2 | 源 buffer 选择（编码同 wr_sel） |
| `rd_bank` | Input | $clog2(BUF_BANKS) | 源 bank 号 |
| `rd_addr` | Input | $clog2(BUF_DEPTH) | bank 内地址 |
| `rd_data_valid` | Output | 1 | 读数据有效（1-cycle SRAM latency） |
| `rd_data` | Output | AXI_DATA_W | 读出数据 |

#### 4.2.3 Port List — Ping-Pong Control

| Signal | Direction | Width | Description |
|---|---|---|---|
| `pp_switch_req` | Input | 1 | 切换请求（来自 tile_scheduler） |
| `pp_switch_ack` | Output | 1 | 切换完成应答 |
| `pp_a_compute_sel` | Output | 1 | 当前 A 计算侧选择（0=A_BUF[0], 1=A_BUF[1]） |
| `pp_b_compute_sel` | Output | 1 | 当前 B 计算侧选择（0=B_BUF[0], 1=B_BUF[1]） |
| `pp_a_load_sel` | Output | 1 | 当前 A DMA 装载侧选择 |
| `pp_b_load_sel` | Output | 1 | 当前 B DMA 装载侧选择 |

#### 4.2.4 Port List — Status

| Signal | Direction | Width | Description |
|---|---|---|---|
| `conflict_stall` | Output | 1 | 当前拍发生 bank 冲突导致的 stall |
| `bank_occ` | Output | BUF_BANKS | 各 bank 占用标志（有未完成读写） |

### 4.3 `a_loader`

`a_loader` 接收 DMA 读数据流，将 A tile 按行优先顺序重排后写入 buffer。

#### 4.3.1 Port List

| Signal | Direction | Width | Description |
|---|---|---|---|
| `clk` | Input | 1 | 主时钟 |
| `rst_n` | Input | 1 | 异步低有效复位 |
| `dma_valid` | Input | 1 | DMA beat 有效 |
| `dma_ready` | Output | 1 | loader 可接收 |
| `dma_data` | Input | AXI_DATA_W | DMA beat 数据 |
| `dma_last` | Input | 1 | DMA burst 最后一拍 |
| `tile_rows` | Input | 16 | A tile 行数 |
| `tile_cols` | Input | 16 | A tile 列数（=Tk） |
| `tile_stride` | Input | 32 | A 矩阵行 stride（bytes） |
| `base_addr` | Input | 32 | A tile 在 buffer 内的起始地址（bytes） |
| `pp_sel` | Input | 1 | 写入目标 ping-pong 侧 |
| `buf_wr_valid` | Output | 1 | buffer 写请求 |
| `buf_wr_ready` | Input | 1 | buffer 写就绪 |
| `buf_wr_sel` | Output | 2 | buffer 选择（编码同 buffer_bank） |
| `buf_wr_bank` | Output | $clog2(BUF_BANKS) | bank 号 |
| `buf_wr_addr` | Output | $clog2(BUF_DEPTH) | bank 内地址 |
| `buf_wr_data` | Output | AXI_DATA_W | 写入数据 |
| `buf_wr_mask` | Output | AXI_DATA_W/8 | 写掩码 |
| `load_done` | Output | 1 | tile 装载完成脉冲 |
| `load_err` | Output | 1 | 装载错误（越界/溢出） |

#### 4.3.2 Address Mapping

A tile 存储采用 **行优先（Row-Major）** 以匹配 systolic_core 的行注入方向：

```
linear_byte = row * tile_stride + col * (ELEM_W/8)
bank      = (linear_byte / (AXI_DATA_W/8)) % BUF_BANKS
addr      = (linear_byte / (AXI_DATA_W/8)) / BUF_BANKS
offset    = linear_byte % (AXI_DATA_W/8)   // beat 内 byte offset
```

其中 `row = 0..tile_rows-1`, `col = 0..tile_cols-1`。

当 `tile_rows < P_M` 或 `tile_cols` 非整 beat 时，`wr_mask` 屏蔽无效 byte。

### 4.4 `b_loader`

`b_loader` 接收 DMA 读数据流，将 B tile 按**列优先（Column-Major）**顺序重排后写入 buffer，以匹配 systolic_core 的列注入方向。

#### 4.4.1 Port List

与 `a_loader` 同构，差异：
- `tile_rows` = Tk，`tile_cols` = Tn
- `tile_stride` = B 矩阵列 stride（通常 `Tn * ELEM_W/8`，但实际 DMA 按原始矩阵 stride 传输）

#### 4.4.2 Address Mapping

B tile 存储采用 **列优先（Column-Major）**：

```
linear_byte = col * tile_stride + row * (ELEM_W/8)
bank      = (linear_byte / (AXI_DATA_W/8)) % BUF_BANKS
addr      = (linear_byte / (AXI_DATA_W/8)) / BUF_BANKS
```

其中 `row = 0..tile_rows-1`（=Tk），`col = 0..tile_cols-1`（=Tn）。

### 4.5 `c_loader`（可选）

`c_loader` 预取 C tile 供 postproc `+C` 融合。C tile 采用行优先存储，与 A tile 同构。

端口与 `a_loader` 同构，差异：
- 目标 buffer = C_BUF（单缓冲，无 ping-pong）
- `tile_rows` = Tm，`tile_cols` = Tn

### 4.6 `d_storer`

`d_storer` 收集 postproc 输出的 FP16 结果，打包为 AXI beat 格式，通过 `dma_wr` 写回 DDR。

#### 4.6.1 Port List

| Signal | Direction | Width | Description |
|---|---|---|---|
| `clk` | Input | 1 | 主时钟 |
| `rst_n` | Input | 1 | 异步低有效复位 |
| `post_valid` | Input | 1 | postproc 输出有效 |
| `post_ready` | Output | 1 | storer 可接收 |
| `post_data` | Input | P_M*P_N*ELEM_W | postproc 输出的 tile 数据（扁平化） |
| `post_last` | Input | 1 | tile 最后输出 |
| `tile_rows` | Input | 16 | D tile 行数 |
| `tile_cols` | Input | 16 | D tile 列数 |
| `tile_stride` | Input | 32 | D 矩阵行 stride（bytes） |
| `base_addr` | Input | 32 | D tile 在 buffer 内的起始地址 |
| `dma_wr_valid` | Output | 1 | DMA 写请求 |
| `dma_wr_ready` | Input | 1 | DMA 写就绪 |
| `dma_wr_data` | Output | AXI_DATA_W | 打包后的 AXI beat |
| `dma_wr_strb` | Output | AXI_DATA_W/8 | 字节 strobe（边界 tile 部分 beat） |
| `dma_wr_last` | Output | 1 | burst 最后一拍 |
| `store_done` | Output | 1 | tile 写回完成脉冲 |
| `store_err` | Output | 1 | 写回错误 |

#### 4.6.2 Data Packing

`d_storer` 内部维护一个行缓冲（row buffer），收集 `P_N` 列元素：

```
// 每拍从 postproc 接收 P_M*P_N 个 FP16
// 按行优先顺序填入 row buffer
// 当 row buffer 填满一个 AXI beat（AXI_DATA_W/ELEM_W 个元素）时发起 dma_wr_valid
```

边界 tile 时，`tile_rows < P_M` 或 `tile_cols < P_N`，不足部分不参与打包，`dma_wr_strb` 屏蔽对应 byte。

## 5. Functional Descriptions

### 5.1. Normal Function

1. **LOAD 阶段**：`tile_scheduler` 发起 `pp_switch_req`（或首 tile 直接开始），`a_loader`/`b_loader` 从 `dma_rd` 接收 A/B tile 数据，按行列优先重排后写入 `buffer_bank` 的 ping 侧
2. **COMPUTE 阶段**：`array_io_adapter` 从 `buffer_bank` 的 pong 侧（上一 tile 已装载）按拍读取向量，施加 skew 后送入 `systolic_core`
3. **STORE 阶段**：`systolic_core` 输出经 `postproc` 后由 `d_storer` 收集打包，通过 `dma_wr` 写回 DDR
4. **SWITCH 阶段**：当前 tile 的 k0 全部完成后，`tile_scheduler` 请求 ping-pong 切换，下一 tile 的 A/B 从 DMA 写入另一侧，计算侧读取本侧

### 5.1.1. Ping-Pong Switch Timing

切换发生在 **k0-loop 边界**（即单个 tile 的全部 Tk 累加完成后），而非 tile 边界：

```
for m0 in [0, M) step Tm:
  for n0 in [0, N) step Tn:
    acc_tile = 0
    for k0 in [0, K) step Tk:
      // 每轮 k0 都需要 load A_tile(Tm,Tk) 和 B_tile(Tk,Tn)
      // ping-pong 在 k0 轮次间切换
      // 即：k0=0 用 ping 侧 load，k0=1 用 pong 侧 load，同时 ping 侧 compute
      load_A_B_to_ping  // DMA 写入
      compute_from_pong // 阵列读取上一 k0 的数据
      pp_switch_req     // 切换
    store_D_tile
```

切换条件（`pp_switch_req` 被接受）：
- 当前计算侧 `core_done` 已 asserted
- 当前装载侧 `load_done` 已 asserted
- 无未完成的 bank 读写（`bank_occ == 0`）

切换完成后 `pp_switch_ack` 脉冲 1 拍。

### 5.1.2. Bank Conflict Arbitration

当同一拍存在多个读/写请求命中同一 bank 时：

**优先级**（固定优先级，可配置）：
1. `array_io_adapter` 读请求（计算不能 stall）
2. `d_storer` 回写读请求（C_BUF 读取，若存在）
3. `a_loader` / `b_loader` 写请求（DMA 可 backpressure）

**冲突处理**：
- 高优先级请求获得 bank 端口
- 低优先级请求进入 skid buffer（深度 2），下拍重试
- 若 skid buffer 满，拉低 `wr_ready` / `rd_req_ready` 施加 backpressure
- `conflict_stall` 脉冲标志冲突发生（用于性能计数）

### 5.1.3. Boundary Tile Mask

当 `tile_rows < P_M` 或 `tile_cols < P_N` 时：

**Loader 侧**：
- `a_loader` 对不足行（`row >= tile_rows`）的全部元素，`wr_mask` 屏蔽对应 byte
- `b_loader` 对不足列（`col >= tile_cols`）的全部元素，`wr_mask` 屏蔽
- buffer 中未写入位置保持上值（SRAM 初始值不确定，但 masked 位置不会被读取）

**Adapter 侧**：
- `array_io_adapter` 从 buffer 读取时，`a_vec_mask` 和 `b_vec_mask` 由 `tile_scheduler` 通过 `mask_cfg` 传入
- `systolic_core` 内部 `tile_mask_cfg` 进一步按 PE 坐标屏蔽

**Storer 侧**：
- `d_storer` 对不足行/列，`dma_wr_strb` 屏蔽无效 byte
- 避免向 DDR 写入未定义数据

### 5.2. Diagnostic Function

可观测项：
- `bank_occ`：各 bank 实时占用
- `conflict_stall`：冲突 stall 脉冲
- `load_done` / `store_done`：生命周期完成标志
- ping-pong 当前角色（`pp_a_compute_sel` 等）

### 5.2.1. Configuration Methods

- `DEBUG_BUF_CTRL`：
  - `occ_snapshot_en`：锁存当前 bank 占用状态到可读寄存器
  - `freeze_switch`：冻结 ping-pong 切换（调试用）

## 6. Test/Debug Modes (Internal Documentation)

- `force_bank_conflict_mode`：强制多请求命中同一 bank，验证仲裁逻辑
- `reorder_bypass_mode`：绕过重排，DMA 数据直接按接收顺序写入 buffer，用于验证基础通路
- `force_mask_drop_mode`：强制 mask 全 0，验证边界处理

### 6.1.1. Configuration Methods

- `DEBUG_BUF_MODE[0]`：`force_bank_conflict`
- `DEBUG_BUF_MODE[1]`：`reorder_bypass`
- `DEBUG_BUF_MODE[2]`：`force_mask_drop`

## 7. Architecture Descriptions (Internal Documentation)

### 7.1. Architecture Overview

三层架构：
- **存储层**：`buffer_bank`（SRAM arrays + bank arbiter）
- **变换层**：`a_loader`/`b_loader`（重排） + `d_storer`（打包）
- **控制层**：`buf_ctrl`（ping-pong 切换 + 冲突仲裁 + 完成上报）

### 7.2. Clocks and Resets

- 默认单时钟域 `clk`
- 异步低有效复位 `rst_n`
- 复位后：
  - 所有 bank 指针归零
  - ping-pong 初始状态：`A_BUF[0]=load`, `A_BUF[1]=compute`; `B_BUF[0]=load`, `B_BUF[1]=compute`
  - `pp_switch_ack=0`, `conflict_stall=0`

### 7.2.1. Clock and Reset Description / Logic Circuit

- 写入路径：`valid/ready` 寄存切分，1-cycle SRAM 写延迟
- 读路径：SRAM 1-cycle 读延迟 + 输出寄存（可选）
- ping-pong 选择信号：`pp_*_compute_sel` 用寄存器存储，切换时由 `buf_ctrl` 更新

### 7.2.2. CDC Synchronization Scheme (Optional)

若 DMA 与 core 分频域：
- loader→buffer 写命令通过 async FIFO（深度 4）
- buffer→adapter 读命令通过 credit + 双触发同步
- `pp_switch_req` / `pp_switch_ack` 采用 handshake 同步（req 展宽 + 双触发 ack）

### 7.3. Top Main Interfaces

| 上游 | 下游 | 控制 |
|---|---|---|
| `dma_rd`（A/B/C 数据流） | `array_io_adapter`（读向量） | `tile_scheduler`（切换/配置） |
| `postproc`（D 数据流） | `dma_wr`（D 写回流） | `csr_if`（DEBUG_BUF_MODE） |

### 7.4. Architecture Scheme Comparison

- **方案 A（采用）**：统一 `buffer_bank` + 仲裁
  - A/B/C 共享 bank 资源，通过选择信号区分
  - 优点：面积更优，控制集中
  - 缺点：仲裁逻辑稍复杂
- **方案 B**：A/B/C 独立 buffer
  - 优点：无跨 buffer 冲突，时序简单
  - 缺点：面积较大，存储利用率可能不均衡

### 7.5. Sub-Module `buf_ctrl`

#### 7.5.1. Overview

负责 ping-pong 切换控制、bank 冲突仲裁、load/store 生命周期管理。

#### 7.5.2. Sub-Module `buf_arbiter`

##### 7.5.2.1. Overview

同拍多请求 bank 冲突仲裁。

##### 7.5.2.2. Logic Design

```systemverilog
// Per-bank request collection
for each bank b:
  req[b] = {adapter_rd_req[b], d_storer_rd_req[b], a_loader_wr_req[b], b_loader_wr_req[b]}

// Fixed priority: adapter > d_storer > a_loader > b_loader
grant[b] = priority_encode(req[b])

// Ungranted requests -> skid buffer
skid_push = req[b] & ~grant[b]
// Next cycle: skid requests re-arbitrate with new requests
```

#### 7.5.3. Sub-Module `buf_pp_ctl`

##### 7.5.3.1. Overview

Ping-pong 切换状态机。

##### 7.5.3.2. Logic Design

状态机：`IDLE -> LOAD -> COMPUTE -> SWITCH -> IDLE`

| State | Description | Entry Condition | Exit Condition |
|---|---|---|---|
| `IDLE` | 等待 tile 启动 | `tile_start` | 自动进入 LOAD |
| `LOAD` | DMA 装载当前 k0 | `load_done` | 若有前一轮数据，进入 COMPUTE |
| `COMPUTE` | 阵列计算 | `core_done` | 进入 SWITCH |
| `SWITCH` | 切换 ping-pong | `bank_occ==0` | `pp_switch_ack` 脉冲，回 IDLE（下一轮 k0）|

注：首 tile 首 k0 无前一轮数据，LOAD 后直接继续 LOAD（下一 k0 侧），直到首 k0 数据就绪后进入 COMPUTE。

### 7.6. Sub-Module `buf_dp`

- `row_cnt` / `col_cnt`：tile 行列计数器
- `bank_idx_gen`：`(linear_addr / beat_size) % BUF_BANKS`
- `pp_role_reg`：ping/pong 角色寄存器（load/compute）
- `mask_expand`：将 `tile_rows/tile_cols` 展开为 byte-level `wr_mask`

### 7.7. Sub-Module `buf_mem`

每套 buffer 内部结构：

```
A_BUF[0]: BUF_BANKS x BUF_DEPTH x AXI_DATA_W SRAM
A_BUF[1]: BUF_BANKS x BUF_DEPTH x AXI_DATA_W SRAM
B_BUF[0]: BUF_BANKS x BUF_DEPTH x AXI_DATA_W SRAM
B_BUF[1]: BUF_BANKS x BUF_DEPTH x AXI_DATA_W SRAM
C_BUF   : BUF_BANKS x BUF_DEPTH x AXI_DATA_W SRAM (optional)
```

SRAM 类型：单口（1R1W），读/写不同时钟拍进行。若需同拍读写同一 bank，需用 1R+1W 伪双口或增加 bank 数避免冲突。

### 7.8. Logic Design

#### 7.8.1. Address Mapping Detail

**A tile（行优先）**：
```
// 物理地址生成（以 byte 为单位）
elem_byte_addr = base_addr + row * stride_A + col * (ELEM_W/8)

// 映射到 bank/addr/offset
beat_idx       = elem_byte_addr / (AXI_DATA_W/8)
bank           = beat_idx % BUF_BANKS
addr           = beat_idx / BUF_BANKS
beat_offset    = elem_byte_addr % (AXI_DATA_W/8)   // 0, 2, 4, ...

// wr_mask: 每个 element 占 ELEM_W/8 = 2 bytes
// 有效 element: mask bit = 1
// 边界不足: 对应 byte mask = 0
```

**B tile（列优先）**：
```
elem_byte_addr = base_addr + col * stride_B + row * (ELEM_W/8)
```

**D tile（行优先，storer 输出）**：
```
// d_storer 内部按行收集 P_N 个 element
// 当收集满 AXI_DATA_W/ELEM_W 个 element 时发起 dma_wr_valid
elem_byte_addr = base_addr + row * stride_D + col * (ELEM_W/8)
// 边界不足时 strb=0
```

#### 7.8.2. Array_IO_Adapter 读接口时序

`array_io_adapter` 每拍向 `buffer_bank` 发起读请求：

```
Cycle 0: rd_req_valid=1, rd_sel=pp_a_compute_sel/pp_b_compute_sel, rd_bank=bank_gen(), rd_addr=addr_gen()
Cycle 1: rd_data_valid=1, rd_data=SRAM_out  (1-cycle latency)
Cycle 2: array_io_adapter 将 rd_data 按 lane 拆分 + skew 送入 systolic_core
```

**关键约束**：`rd_req_valid` 必须在 `core_busy` 期间持续有效，否则阵列 stall。因此 bank 冲突仲裁必须保证 adapter 读请求永不阻塞（最高优先级）。

#### 7.8.3. Loader 写接口时序

```
Cycle 0: dma_valid=1, dma_data=beat[N]
Cycle 1: a_loader 计算 bank/addr/mask，buf_wr_valid=1
Cycle 2: buffer_bank SRAM 写入（若 wr_ready=1）
Cycle 3: 下一 beat 继续
```

若 `wr_ready=0`（bank 冲突或 skid buffer 满），DMA R 通道 stall（`r_ready=0`），形成 backpressure。

### 7.9. Low Power Design (Optional)

- 空闲 bank 自动 clock gate（当 `bank_occ[b]==0` 持续 4 拍以上）
- 无效 lane 不翻转：`wr_mask=0` 的 byte 不驱动 SRAM DIN（data gating）
- bypass 模式关闭重排逻辑路径（reorder bypass 时 loader 变成直通）

### 7.10. Architecture Open Issues

1. **C_BUF 是否独立 bank**：当前 spec 将 C_BUF 并入统一 bank 结构，若 postproc 需要与 systolic_core 同时读取 C 和 acc，可能产生 bank 冲突。解决方案：增加 C_BUF 专用 bank 或采用双口 SRAM。
2. **极小 tile ping-pong 收益**：当 Tk 极小（如 Tk=2）时，切换开销可能抵消 ping-pong 收益。解决方案：`tile_scheduler` 在 `Tk < PP_MIN_TK` 时禁用 ping-pong，复用同一侧 buffer。
3. **ACC_BUF 必要性**：若 postproc 在 systolic_core 输出后即刻融合 `+C`，则无需独立 ACC_BUF。若需延迟融合（如等 C tile 到达），则需 ACC_BUF 暂存。

## 8. Integration Guide (Internal Documentation)

### 8.1 与 DMA 集成

- 统一 beat 到 element 的端序：小端（LSB = element[0]）
- `a_loader`/`b_loader` 的 `dma_ready` 直接连接到 `dma_rd` 的 `r_ready`
- `d_storer` 的 `dma_wr_valid`/`dma_wr_ready` 直接连接到 `dma_wr` 的 `w_valid`/`w_ready`

### 8.2 与阵列集成

- `array_io_adapter` 的读请求连接到 `buffer_bank` 的 `rd_req_*`
- 读出的 `rd_data` 经 `array_io_adapter` 按 lane 拆分：`a_vec_data[row] = rd_data[row*ELEM_W +: ELEM_W]`
- `a_vec_mask` / `b_vec_mask` 由 `tile_scheduler` 根据 `tile_rows/tile_cols` 生成

### 8.3 与调度器集成

- `tile_scheduler` 通过 `pp_switch_req` 控制 ping-pong 切换
- `buf_ctrl` 返回 `pp_switch_ack` 后，scheduler 才能发起下一轮 k0 的 DMA 请求
- `load_done` / `store_done` 上报给 scheduler 作为状态机推进条件

## 9. Implementation Guide (Internal Documentation)

### 9.1 建议实现顺序

1. `buffer_bank` 单 bank 读写正确性（先用 1 个 bank 验证地址映射）
2. `a_loader` 基础重排（行优先，无 ping-pong）
3. `b_loader` 基础重排（列优先，无 ping-pong）
4. `buf_ctrl` ping-pong 切换 + 冲突仲裁
5. `d_storer` 打包与短包 strobe
6. 与 `array_io_adapter` + `systolic_core` 子系统集成验证

### 9.2 代码建议

- 控制/数据路径分离：`buf_ctrl` 纯控制，`buf_dp` 纯 datapath
- 所有 `last` 语义统一：`dma_last` = AXI burst last beat，`load_done` = tile 装载完成，`post_last` = tile 计算完成
- `wr_mask` / `dma_wr_strb` 在边界 tile 时必须精确到 byte 级

## 10. Verification Guide (Internal Documentation)

### 10.1 功能用例

| 用例 | 描述 | 通过标准 |
|---|---|---|
| 对齐 tile | Tm=P_M, Tn=P_N, Tk 整 beat | 重排后数据与软件参考序列逐 element 比对 |
| 非对齐 tile | Tm<P_M 或 Tn<P_N | mask 精确，无效 byte 不写入/读出 |
| 边界 mask | tile_rows=1, tile_cols=1 | 仅 PE[0][0] 有效，其余 mask 屏蔽 |
| ping-pong 切换 | 连续 2 个 k0 | 无数据污染，切换 ack 正确 |

### 10.2 压力用例

| 用例 | 描述 |
|---|---|
| 人工冲突高压 | 强制 adapter + loader 同拍访问同一 bank |
| backpressure 注入 | 随机拉低 `wr_ready` / `rd_req_ready` |
| reset during stream | 数据流中途 reset，验证恢复 |

### 10.3 覆盖建议

- bank 冲突所有组合覆盖（2-request, 3-request, 4-request）
- mask 模式覆盖：全有效、行尾部分、列尾部分、右下角单 element
- d_storer 短包覆盖：1 element、半 beat、整 beat、跨 beat

## 11. Registers

| Offset | Name | Bits | R/W | Description |
|---|---|---|---|---|
| 0x000 | BUF_CTRL | 3 | R/W | bit0=pp_enable, bit1=reorder_enable, bit2=c_loader_enable |
| 0x004 | BUF_CFG0 | 16 | R/W | buf_banks[3:0], vec_width[11:4] |
| 0x008 | BUF_STATUS | 4 | RO | load_busy, store_busy, switch_busy, conflict_active |
| 0x00C | BUF_ERR_CODE | 4 | R/W1C | bit0=bank_oob, bit1=addr_oob, bit2=mask_illegal, bit3=switch_conflict |
| 0x010 | BUF_PERF_CONFLICT | 32 | RO | 累计冲突 stall 拍数 |
| 0x014 | BUF_PERF_OCC_MAX | BUF_BANKS | RO | 各 bank 历史最大并发占用 |
| 0x018 | BUF_DEBUG_MODE | 3 | R/W | bit0=force_bank_conflict, bit1=reorder_bypass, bit2=force_mask_drop |
| 0x01C | BUF_OCC_SNAPSHOT | BUF_BANKS | RO | 当前 bank 占用快照 |

## 12. Reference (Internal Documentation)

- `ARCHITECTURE.md` — 顶层架构与数据通路
- `spec/modules.md` — 模块划分与 M1~M4 里程碑
- `spec/dma_axi_access_spec.md` — DMA 与 AXI 接口定义
- `spec/systolic_compute_core_spec.md` — 阵列输入时序与 mask 定义
- `rtl/array_io_adapter.sv` — 已验证的阵列适配器 RTL
- `rtl/systolic_core.sv` — 已验证的阵列核心 RTL

## 13. Open Issues & Workaround (Internal Documentation)

1. **Open Issue**: 高并发读导致 bank 冲突增多。  
   **Workaround**: 调整 bank 交织策略或增加 banks 数；adapter 读请求永最高优先级。
2. **Open Issue**: 边界 tile 的 mask 展开路径较长（组合逻辑 depth）。  
   **Workaround**: 在 loader 前级预计算 mask 表（LUT 或小型 ROM），或 pipeline mask 生成。
3. **Open Issue**: 小 tile 频繁切换 ping-pong 降低效率。  
   **Workaround**: 设 `PP_MIN_TK` 阈值（如 8），低于阈值时 `tile_scheduler` 禁用 ping-pong，复用同一侧。
4. **Open Issue**: C tile 与 acc 同时读取可能 bank 冲突。  
   **Workaround**: C_BUF 独立 bank 组，或 postproc 延后一拍的流水线设计。
