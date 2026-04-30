# On-chip Buffer & Data Reorder Module Spec (Internal)

## 1. Revision History (Internal Documentation)

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1 | 2026-04-30 | Codex | Initial draft for on-chip buffer and data-reorder modules (`buffer_bank/a_loader/b_loader/c_loader/d_storer`). |

## 2. Terms/Abbreviations

- SRAM: Static Random Access Memory
- Bank: 独立可并行访问的存储体
- Ping-Pong: 双缓冲角色切换机制
- Reorder: 数据重排/布局转换
- Tile: 分块矩阵片段
- Lane: 并行数据通道
- Conflict: 多请求访问同一 bank 冲突
- Skid Buffer: 握手停顿保护缓存

## 3. Overview

本规格定义 GEMM 片上缓存与数据重排模块，覆盖：
- `buffer_bank`
- `a_loader`
- `b_loader`
- `c_loader`（可选）
- `d_storer`

目标：在 DMA 与阵列计算之间建立高带宽、低冲突、可边界处理的数据中转层，并完成喂数方向所需布局重排。

### 3.1. Block Diagram

```text
                     AXI RD path
                         |
                         v
                +-------------------+
                | a/b/c_loader      |
                | unpack + reorder  |
                +---------+---------+
                          |
                          v
                +-------------------+
                | buffer_bank       |
                | A_BUF[2],B_BUF[2] |
                | C_BUF,(ACC_BUF)   |
                +-----+-------+-----+
                      |       |
            read vec  |       | write vec
                      v       ^
                +-------------------+
                | array_io_adapter  |
                +-------------------+
                          |
                          v
                     postproc out
                          |
                          v
                +-------------------+
                | d_storer          |
                | gather + pack     |
                +---------+---------+
                          |
                          v
                     AXI WR path
```

### 3.2. Features

- 支持 A/B 双缓冲（Ping-Pong）并行：一侧计算、一侧装载
- 支持 C tile 预取与可旁路
- 支持面向阵列输入方向的数据重排（A 左入/B 上入）
- 支持 bank 冲突仲裁和 backpressure 吸收
- 支持边界 tile mask（不足行/列有效位）
- 支持 D 输出收集与写回格式打包

## 4. Port List and Parameters (Internal Documentation)

### 4.1 `buffer_bank`

- Input
  - `clk`, `rst_n`
  - `wr_valid`, `wr_bank_sel`, `wr_addr`, `wr_data`, `wr_mask`
  - `rd_req_valid`, `rd_bank_sel`, `rd_addr`
  - `pp_switch_req`（ping-pong 切换）
- Output
  - `wr_ready`
  - `rd_req_ready`, `rd_data_valid`, `rd_data`
  - `pp_switch_ack`
  - `conflict_stall`

### 4.2 `a_loader` / `b_loader` / `c_loader`

- Input
  - `dma_data_valid`, `dma_data`, `dma_data_last`
  - `tile_cfg`（rows/cols/stride/elem_bytes）
  - `mask_cfg`（边界有效位）
- Output
  - `buf_wr_valid`, `buf_wr_addr`, `buf_wr_data`, `buf_wr_mask`
  - `load_done`, `load_err`

### 4.3 `d_storer`

- Input
  - `post_valid`, `post_data`, `post_last`
  - `store_cfg`（rows/cols/layout）
- Output
  - `dma_wr_valid`, `dma_wr_data`, `dma_wr_last`, `dma_wr_strb`
  - `store_done`, `store_err`

### 4.4 Key Parameters

- `BUF_BANKS` (default 8)
- `BUF_DEPTH` (default 2048 entries per bank)
- `VEC_W` (default 256)
- `ELEM_W` (default 16)
- `PE_M`, `PE_N`（阵列规模透传）
- `PP_ENABLE` (default 1)

## 5. Functional Descriptions

### 5.1. Normal Function

1. `a_loader/b_loader/c_loader` 接收 DMA 流并解包
2. 根据 tile 配置做地址映射和重排后写入 `buffer_bank`
3. `array_io_adapter` 按拍读取向量喂给阵列
4. `d_storer` 收集后处理输出并重新打包为写回流
5. `store_done/load_done` 上报给调度器

### 5.1.1. Configuration Methods(Optional)

推荐配置项：
- bank 交织方式（row-major / col-major / interleave）
- ping-pong 切换策略（按 k0 或按 tile）
- 边界 mask 使能

### 5.2. Diagnostic Function(Optional)

建议状态可观测：
- bank 占用率
- 冲突 stall 计数
- loader reorder 旁路/重排比例
- d_storer 短包统计

### 5.2.1. Configuration Methods(Optional)

- `DEBUG_BUF_CTRL`：
  - `occ_snapshot_en`
  - `freeze_switch`

## 6. Test/Debug Modes (Internal Documentation)

- `force_bank_conflict_mode`：强制冲突场景
- `reorder_bypass_mode`：绕过重排验证基线功能

### 6.1.1. Configuration Methods

- `DEBUG_BUF_MODE[0]`：force_bank_conflict
- `DEBUG_BUF_MODE[1]`：reorder_bypass
- `DEBUG_BUF_MODE[2]`：force_mask_drop

## 7. Architecture Descriptions (Internal Documentation)

### 7.1. Architecture Overview

架构分三层：
- 存储层：`buffer_bank`
- 变换层：`a_loader/b_loader/c_loader/d_storer`
- 控制层：切换控制、冲突仲裁、完成上报

### 7.2. Clocks and Resets

- 默认单时钟域 `clk`
- 异步低有效复位 `rst_n`
- 复位后 bank 指针归零、切换状态回 ping=load/pong=compute 初值

### 7.2.1. Clock and Reset Description / Logic Circuit (Optional)

- 写入路径使用 `valid/ready` 寄存切分
- 读口可选 1-cycle SRAM 读延迟补偿寄存

### 7.2.2. CDC Synchronization Scheme (Optional)

若 DMA 与 core 分频域：
- loader->buffer 写命令通过 async FIFO
- buffer->adapter 读命令通过 credit + 同步器

### 7.2.3. RDC Synchronization Scheme (Optional)

- ping-pong 切换标志跨域需握手确认
- done 信号保持到对端 ack

### 7.3. Top Main Interfaces (Optional)

- 上游：`dma_rd`、`postproc`
- 下游：`array_io_adapter`、`dma_wr`
- 控制：`tile_scheduler`

### 7.4. Architecture Scheme Comparison (Optional)

- 方案 A：统一 `buffer_bank` + 仲裁
  - 优点：资源共享，面积更优
  - 缺点：仲裁复杂度较高
- 方案 B：A/B/C 独立 buffer
  - 优点：冲突更少，时序简单
  - 缺点：存储利用率可能下降

推荐：MVP 采用方案 A；性能瓶颈出现后评估方案 B。

### 7.5. Sub-Module XXX_CTL (Optional)

`XXX_CTL` 对应 buffer 控制与切换控制。

### 7.5.1. Overview

- 负责 bank 访问仲裁、ping-pong 切换、load/store 生命周期管理

### 7.5.2. Sub-Module XXX_RDCTL

#### 7.5.2.1. Overview

- 负责阵列读口调度与冲突规避

#### 7.5.2.2. Logic Design

- 同拍多请求按优先级/轮询分配 bank 端口
- 冲突请求进入 skid buffer 等待下拍重试
- 边界 mask 对应 lane 置零输出

### 7.5.3.  Sub-Module XXX_WRCTL

#### 7.5.3.1. Overview

- 负责 loader/store 写入口和写掩码合成

#### 7.5.3.2. Logic Design

- 将 DMA beat 解包为 `ELEM_W` 元素并映射 bank/addr
- 行尾不足向量宽度时生成部分 `wr_mask`
- 写入越界检测触发 `store_err/load_err`

### 7.5.4.  Logic Design

建议控制状态机：
`IDLE -> LOAD -> READY_FOR_COMPUTE -> STREAM -> DRAIN -> SWITCH -> IDLE`

### 7.6. Sub-Module XXX_DP (Optional)

- tile 行列计数器
- bank index 生成器
- ping/pong 角色寄存
- mask 展开 datapath

### 7.7. Sub-Module XXX_MEM(Optional)

- A_BUF ping/pong SRAM arrays
- B_BUF ping/pong SRAM arrays
- C_BUF SRAM (optional)
- ACC_BUF (optional)

### 7.8. Logic Design (Optional)

地址映射建议：
1. `linear_idx = row * ld + col`
2. `bank = linear_idx % BUF_BANKS`
3. `addr = linear_idx / BUF_BANKS`
4. A/B 可采用不同线性化方向以匹配阵列注入方向

### 7.9. Low Power Design (Optional)

- 空闲 bank 自动 clock gate
- 无效 lane 不翻转（data gating）
- 在 bypass 模式关闭重排逻辑路径

### 7.10. Architecture Open Issues (Optional)

- C_BUF 是否独立 bank 还是与 A/B 复用
- ACC_BUF 是否必须落地（取决于累计策略）
- 极小 tile 下 ping-pong 收益是否抵消切换开销

## 8. Integration Guide (Internal Documentation)

- 与 DMA 集成：统一 beat 到 element 的端序定义
- 与阵列集成：明确每拍输入向量 lane 到 PE 坐标映射
- 与调度器集成：切换必须在 tile 边界进行并有 ack

## 9. Implementation Guide (Internal Documentation)

- 建议实现顺序：
  1. `buffer_bank` 单口/双口读写正确性
  2. `a_loader/b_loader` 基础重排
  3. ping-pong 切换与冲突仲裁
  4. `d_storer` 打包与短包 strobe
- 代码建议：
  - 控制/数据路径分离
  - 所有 `last` 语义统一（tile-last 与 beat-last 显式区分）

## 10. Verification Guide (Internal Documentation)

- 功能用例：
  - 对齐 tile、非对齐 tile、边界 mask
  - A/B 重排后与软件参考序列比对
  - ping-pong 切换时无数据污染
- 压力用例：
  - 人工冲突高压
  - backpressure 注入
  - reset during stream
- 覆盖建议：
  - bank 冲突覆盖
  - mask 模式覆盖
  - d_storer 短包覆盖

## 11. Registers

建议寄存器：
- `BUF_CTRL`
  - bit0 `pp_enable`
  - bit1 `reorder_enable`
  - bit2 `c_loader_enable`
- `BUF_CFG0`
  - `buf_banks`
  - `vec_width`
- `BUF_STATUS`
  - `load_busy`, `store_busy`, `switch_busy`
- `BUF_ERR_CODE`
  - bit0 `bank_oob`
  - bit1 `addr_oob`
  - bit2 `mask_illegal`
  - bit3 `switch_conflict`
- `BUF_PERF_CONFLICT`
- `BUF_PERF_OCC_MAX`

## 12. Reference (Internal Documentation)

- `ARCHITECTURE.md`
- `spec/modules.md`
- `spec/dma_axi_access_spec.md`

## 13. Open Issues & Workaround (Internal Documentation)

1. **Open Issue**: 高并发读导致 bank 冲突增多。  
   **Workaround**: 调整 bank 交织策略或增加 banks 数。
2. **Open Issue**: 边界 tile 的 mask 展开路径较长。  
   **Workaround**: 在 loader 前级预计算 mask 表。
3. **Open Issue**: 小 tile 频繁切换 ping-pong 降低效率。  
   **Workaround**: 设最小切换粒度，低于阈值时禁用 ping-pong。
