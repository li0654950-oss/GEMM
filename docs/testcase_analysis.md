# GEMM Accelerator 验证 Testcase 详细分析

**版本**: v1.0
**日期**: 2026-05-05
**项目**: FP16 Systolic Array GEMM (D = A×B + C)
**仿真器**: Verilator 5.020

---

## 1. 文档定位

本文档是 `docs/verification_plan.md` 的细化执行层。对每个 testbench 中的 testcase 逐一拆解：
- **目的**：该 case 验证什么功能
- **输入条件**：测试向量、配置参数、激励序列
- **执行步骤**：操作顺序与时序
- **预期结果**：通过/失败判定标准
- **覆盖点**：该 case 覆盖的代码/功能/状态机路径

---

## 2. 单元测试 Testcase 分析

### 2.1 `tb_pe_cell` — PE 基础运算单元

**模块**: `pe_cell.sv`  
**testbench**: `tb/tb_pe_cell.sv`  
**总 tests**: 5

| # | Testcase | 目的 | 输入条件 | 执行步骤 | 预期结果 | 覆盖点 |
|---|---|---|---|---|---|---|
| T1 | Basic MAC | 验证 FP16 MAC 累加正确 | a=1.0, b=1.0, valid=1, 连续 4 cycle | 4 cycle 后检查 acc_out | acc_out ≈ 4.0 (FP32) | 乘法器、累加器更新路径 |
| T2 | Acc clear | 验证累加器清零 | acc_clear=1 一 cycle | 1 cycle 后读 acc_out | acc_out = 0 | clear 优先于 hold/valid 路径 |
| T3 | Acc hold | 验证累加器冻结 | acc_hold=1, valid=1, a=2.0, b=2.0 | 保持 2 cycle | acc_out 不变 | hold 路径阻塞更新 |
| T4 | Valid propagation | 验证 valid 链式传播 | valid_in=1 | 1 cycle 后 | valid_out=1 | valid 寄存器转发 |
| T5 | A/B propagation | 验证数据传播时序 | a_in=0x3C00, b_in=0x4000 | 1 cycle 后 | a_out=0x3C00, b_out=0x4000 | A/B 转发寄存器 |

**备注**: 当前使用 `fp16_mac_soft` 行为级模型，替换 hardened IP 后需重跑 T1。

---

### 2.2 `tb_systolic_core` — 脉动阵列核心

**模块**: `systolic_core.sv` + `array_io_adapter.sv` + `acc_ctrl.sv`  
**testbench**: `tb/tb_systolic_core.sv`  
**总 tests**: 11（含子场景共 31 项检查点）

| # | Testcase | 目的 | 输入条件 | 执行步骤 | 预期结果 | 覆盖点 |
|---|---|---|---|---|---|---|
| T1 | All-ones 2×2 multiply | 基础矩阵乘法验证 | A=[[1,1],[1,1]], B=[[1,1],[1,1]], K=2 | 启动 core_start，等待 core_done | D=[[2,2],[2,2]] | 阵列 fill/drain、MAC、acc 累加 |
| T2 | Diagonal matrix | 非对称乘法 | A=[[1,2],[3,4]], B=[[1,0],[0,1]], K=2 | 同上 | D=[[1,2],[3,4]] | 不同 A/B 注入时序 |
| T3 | Boundary tile mask | 验证 mask 禁用越界 PE | tile_mask=4'b1101（禁用 PE[1][1]） | 启动计算 | PE[1][1] 输出为 0 | mask 传播到 PE 控制 |
| T4 | Reset during compute | 复位恢复 | 计算中途 rst_n=0，释放后继续 | 复位 → 重新配置 → 启动 | 结果正确，无残留 | 复位清除所有寄存器 |
| T5 | Protocol error | start 时 busy 冲突 | core_start=1 同时 core_busy=1 | 直接启动 | core_err=1 | 状态机保护逻辑 |
| T6 | Single-PE debug | 单 PE 模式 | debug_cfg=3'b001 | 启动 | 仅 PE[0][0] 工作 | debug 多路选择 |
| T7 | Bypass-acc debug | 旁路累加器 | debug_cfg=3'b010 | 启动 | 输出为 a×b（不累积） | acc bypass 路径 |
| T8 | Force-mask debug | 强制 mask | debug_cfg=3'b100 | 启动 | 全部 PE 被 mask | mask override 逻辑 |
| T9 | FP16 accumulate mode | FP16 累加模式 | core_mode=1 (FP16 acc) | 启动 | 累加器为 FP16 精度 | acc_mode 选择 |
| T10 | Performance counters | 性能计数器 | 启动并记录周期数 | 完成 | perf_active/fill/drain/stall 非零 | 计数器触发逻辑 |
| T11 | Continuous tile launch | 连续 tile | 完成后立即启动下一个 tile | 连续 3 次 | 每次结果正确 | 状态机 IDLE→COMPUTE 转换 |

**覆盖点补充**:  
- FSM: IDLE→COMPUTE→COMMIT→DONE 全部状态访问  
- fill/drain 计数器边界: 0 和 P_M+P_N-2  
- mask: 全 1、全 0、部分置位  
- debug_cfg: 3-bit 全部 8 种组合中的 4 种有效模式  

---

### 2.3 `tb_buffer_bank` — 片上缓存

**模块**: `buffer_bank.sv`  
**testbench**: `tb/tb_buffer_bank.sv`  
**总 tests**: 7

| # | Testcase | 目的 | 输入条件 | 执行步骤 | 预期结果 | 覆盖点 |
|---|---|---|---|---|---|---|
| T1 | Basic write/read | 单 bank 读写 | bank=0, addr=0, data=0xABCD | 写 → 读 | rd_data=0xABCD | bank 0 读写路径 |
| T2 | Multi-bank write/read | 跨 bank 访问 | bank=1/2/3, 不同数据 | 依次写 → 依次读 | 各 bank 数据正确 | bank 选择译码 |
| T3 | Masked write | 字节掩码写入 | wr_mask=部分字节使能 | 掩码写 → 读 | 仅使能字节被改 | 掩码应用逻辑 |
| T4 | Ping-pong switch | 双缓冲切换 | pp_switch_req=1 | 切换请求 → 等待 ack | pp_switch_ack=1, sel 翻转 | ping-pong 控制 |
| T5 | Conflict detection | 银行冲突 | 同时读写同一 bank | 并行请求 | conflict_stall=1, 读优先 | 仲裁逻辑 |
| T6 | Cross-buffer-set | 跨 buffer set 访问 | A_BUF[0], A_BUF[1], B_BUF[0] | 分别写入不同 set | 各 set 数据隔离 | sel 译码 + bank 选择 |
| T7 | Reset after ping-pong | 复位恢复 | pp_switch 后 rst_n=0 | 复位 → 读 | 切换状态被清除 | 复位域交叉 |

**覆盖点补充**:  
- bank_occ 状态机: idle→busy→idle  
- wr_ready/rd_req_ready 握手: valid 先、ready 先、同时有效  

---

### 2.4 `tb_a_loader` — A 矩阵装载

**模块**: `a_loader.sv` + `buffer_bank`  
**testbench**: `tb/tb_a_loader.sv`  
**总 tests**: 3

| # | Testcase | 目的 | 输入条件 | 执行步骤 | 预期结果 | 覆盖点 |
|---|---|---|---|---|---|---|
| T1 | Basic 2×16 tile row-major | 基础行主序装载 | tile_rows=2, tile_cols=16, row-major 数据 | DMA 发 2 beat → 读回 | row0/row1 数据顺序正确 | 行主序 → buffer 映射 |
| T2 | Boundary tile 1×2 | 边界 tile | tile_rows=1, tile_cols=2 | 发 1 beat → 读回 | 仅前 2 元素有效，其余 masked | 边界 mask 生成 |
| T3 | Multi-beat row 1×32 | 多 beat 行 | tile_cols=32 (=2 beats) | 发 2 beats → 拼接读回 | beat0+beat1 拼接正确 | 跨 beat 地址递增 |

---

### 2.5 `tb_b_loader` — B 矩阵装载

**模块**: `b_loader.sv` + `buffer_bank`  
**testbench**: `tb/tb_b_loader.sv`  
**总 tests**: 3

| # | Testcase | 目的 | 输入条件 | 执行步骤 | 预期结果 | 覆盖点 |
|---|---|---|---|---|---|---|
| T1 | Basic 2×16 column-major | 列主序装载 | tile_rows=2, tile_cols=16, col-major | DMA 发 16 beats → 读 col0/col8 | 列数据顺序正确 | 列主序 → buffer 映射 |
| T2 | Boundary tile 2×1 | 边界 tile | tile_rows=2, tile_cols=1 | 发 1 beat | 仅首元素有效 | 边界 mask |
| T3 | Multi-beat column 32×1 | 多 beat 列 | tile_rows=32 (=2 beats) | 发 2 beats → 读回 | beat0+beat1 正确 | 跨 beat 列拼接 |

**备注**: a_loader 与 b_loader 同构，T1-T3 覆盖对称路径。

---

### 2.6 `tb_d_storer` — D 结果收集

**模块**: `d_storer.sv` + `buffer_bank`  
**testbench**: `tb/tb_d_storer.sv`  
**总 tests**: 4

| # | Testcase | 目的 | 输入条件 | 执行步骤 | 预期结果 | 覆盖点 |
|---|---|---|---|---|---|---|
| T1 | Basic 2×16 row-major | 基础收集 | tile_rows=2, tile_cols=16, 8 postproc beats | 发 8 beats → 读回 | 行数据顺序正确 | postproc → buffer 行主序 |
| T2 | Boundary 1×2 store | 边界收集 | tile_rows=1, tile_cols=2 | 发 1 beat → 读回 | 仅前 2 元素有效 | 边界 store mask |
| T3 | Multi-beat row 1×32 | 多 beat 收集 | tile_cols=32 | 发 2 beats → 拼接 | 拼接顺序正确 | 跨 beat 存储地址 |
| T4 | Store done timing | 完成信号 | post_last=1 在最后一 beat | 发完全部 beats | store_done=1 在正确 cycle | done 生成逻辑 |

---

### 2.7 `tb_postproc` — 后处理

**模块**: `postproc.sv` + `fp_add_c.sv` + `fp_round_sat.sv`  
**testbench**: `tb/tb_postproc.sv`  
**总 tests**: 12

| # | Testcase | 目的 | 输入条件 | 执行步骤 | 预期结果 | 覆盖点 |
|---|---|---|---|---|---|---|
| T1 | Bypass mode | 无 C 融合 | add_c_en=0 | 发 acc 数据 → 收 d | d = round(acc) | bypass 路径 |
| T2 | Add-C mode | C 融合 | add_c_en=1, C=已知值 | 发 acc + C → 收 d | d = round(acc + C) | fp_add_c 路径 |
| T3 | Round modes RNE/RTZ/RUP/RDN | 舍入模式 | round_mode=0/1/2/3, tie-case | 发 tie 边界值 | 各模式结果符合 IEEE 754 | 4 种舍入逻辑 |
| T4 | NaN propagation | NaN 处理 | acc 或 C 含 NaN | 发 NaN 输入 | d=NaN, nan_cnt++ | NaN 检测 + 传播 |
| T5 | Inf handling | 无穷大 | acc 或 C 含 Inf | 发 Inf 输入 | d=Inf, inf_cnt++ | Inf 检测 |
| T6 | Overflow saturation | 溢出饱和 | sat_en=1, 超大值 | 发溢出值 | d=FP16_MAX, ovf_cnt++ | 饱和逻辑 |
| T7 | Overflow to Inf | 溢出转 Inf | sat_en=0, 超大值 | 同上 | d=Inf | 非饱和路径 |
| T8 | Underflow flush | 下溢归零 | 极小值 | 发 subnormal | d=0, udf_cnt++ | 下溢逻辑 |
| T9 | Lane mask | 部分 lane 禁用 | tile_mask=部分位 0 | 发数据 | 被 mask lane d=0 | mask 应用到输出 |
| T10 | Backpressure | 反压 | d_ready=0 若干 cycle | 发数据时拉低 ready | pipeline 不丢数据 | ready/valid 握手 |
| T11 | Reset clears pipeline | 复位清流水 | 计算中途 rst_n=0 | 复位后检查 | 输出全 0，计数器清 0 | 复位路径 |
| T12 | Denorm flush | 非规格化数 | 发 denormal FP16 | 处理 | d=0, denorm_cnt++ | denorm 检测 |

**覆盖点补充**:  
- `fp_add_c`: C 有效/无效、边界 mask、旁路  
- `fp_round_sat`: 4 种舍入、饱和开关、特殊值处理  
- Pipeline: 空、满、半满、反压、复位  
- 计数器: 6 种异常事件全部触发  

---

### 2.8 `tb_csr_if` — 寄存器接口

**模块**: `csr_if.sv`  
**testbench**: `tb/tb_csr_if.sv`  
**总 tests**: 1（含 write + read 子检查）

| # | Testcase | 目的 | 输入条件 | 执行步骤 | 预期结果 | 覆盖点 |
|---|---|---|---|---|---|---|
| T1 | AXI-Lite write/read DIM_M | CSR 读写回环 | awaddr=0x100, wdata=8 | AXI-Lite 写 → 读 | rdata=8, bresp=OKAY | AXI-Lite FSM: AW→W→B→AR→R |

**覆盖点补充**:  
- AXI-Lite 写 FSM: IDLE→SETUP→AW→W→WAIT_B→DONE  
- AXI-Lite 读 FSM: IDLE→SETUP→AR→R→ACK→CHECK  
- WVALID 保持到 BVALID（Verilator 时序教训）  

---

### 2.9 `tb_tile_scheduler` — Tile 调度器

**模块**: `tile_scheduler.sv`  
**testbench**: `tb/tb_tile_scheduler.sv`  
**总 tests**: 3

| # | Testcase | 目的 | 输入条件 | 执行步骤 | 预期结果 | 覆盖点 |
|---|---|---|---|---|---|---|
| T1 | FSM sequence | 状态机正常流转 | cfg_start=1, 模拟 rd/core/wr 完成 | 启动 → 等待 irq | sch_done=1, 状态经过 LOAD→COMPUTE→STORE | FSM 全状态转换 |
| T2 | Tile loop 2×2 | 多重 tile 循环 | M=8,N=8,K=4,Tm=4,Tn=4,Tk=4 | 启动 → 等待 | tile_m_idx/n_idx 遍历 0,1 | 三重循环计数器 |
| T3 | Zero dimension error | 零维度错误 | cfg_m=0 | 启动 | sch_err=1, err_code=ILLEGAL_DIM | 预检查逻辑 |

**覆盖点补充**:  
- FSM: IDLE→PRECHECK→LOAD_AB→WAIT_BUF→COMPUTE→STORE→NEXT_TILE→DONE  
- 边界 mask: 整 tile (mask=全1) vs 非整 tile (mask=部分0)  
- ping-pong: switch 信号产生与 ack  

---

### 2.10 `tb_rd_addr_gen` — 读地址生成

**模块**: `rd_addr_gen.sv`  
**testbench**: `tb/tb_rd_addr_gen.sv`  
**总 tests**: 1

| # | Testcase | 目的 | 输入条件 | 执行步骤 | 预期结果 | 覆盖点 |
|---|---|---|---|---|---|---|
| T1 | Burst generation 8×8 | 地址序列生成 | rows=8, cols=8, stride=32 | 启动 → 收集全部 cmd | 地址递增，len=15(burst-1), last 正确 | 地址累加 + burst 拆分 |

**覆盖点补充**:  
- burst 拆分: 连续地址 vs 跨行 stride  
- 边界: 最后一 burst 长度裁剪  
- elem_bytes=2 (FP16) 地址对齐  

---

### 2.11 `tb_err_checker` — 错误检查

**模块**: `err_checker.sv`  
**testbench**: `tb/tb_err_checker.sv`  
**总 tests**: 4

| # | Testcase | 目的 | 输入条件 | 执行步骤 | 预期结果 | 覆盖点 |
|---|---|---|---|---|---|---|
| T1 | No error | 无错状态 | 全部输入合法 | 检查 err_valid | err_valid=0 | 默认路径 |
| T2 | Dimension error | 维度非法 | cfg_m=0 | chk_valid=1 | err_valid=1, code=ILLEGAL_DIM | 维度检查逻辑 |
| T3 | AXI read error | AXI 错误 | axi_rresp=SLVERR, valid=1 | 发错误 | err_valid=1, src=DMA_RD | AXI 响应聚合 |
| T4 | Clear error | 错误清除 | soft_reset=1 | 复位后检查 | err_valid=0 | 清除/锁存逻辑 |

**覆盖点补充**:  
- 错误码聚合: 多源错误同时发生  
- fatal/warn 分级: 致命 vs 可恢复  
- sticky bit: 错误保持到软件清除  

---

## 3. 集成测试 Testcase 规划

**状态**: 🔄 待创建（testbench 未编写）

### 3.1 `tb_compute_subsys` — 计算子系统

| # | Testcase | 目的 | 输入条件 | 预期结果 | 覆盖点 |
|---|---|---|---|---|---|
| IT1 | Full tile compute | 端到端 tile 计算 | A/B buffer 预填 → core_start | acc_out 与参考模型一致 | adapter→core→postproc 通路 |
| IT2 | Fill/drain timing | 灌排空时序 | K=2, P_M=P_N=2 | fill=2 cycle, compute=2, drain=2 | fill/drain 计数器 |
| IT3 | Masked boundary | 边界 tile | tile_rows=3, tile_cols=3 | 越界 PE 输出为 0 | mask 传播全链路 |
| IT4 | Backpressure chain | 全链路反压 | postproc d_ready=0 | core 不丢数据，adapter 停发 | ready/valid 全链路 |

### 3.2 `tb_dma_rd_subsys` — 读 DMA 子系统

| # | Testcase | 目的 | 输入条件 | 预期结果 | 覆盖点 |
|---|---|---|---|---|---|
| IT5 | Burst read A tile | AXI 突发读 | addr=0x1000, len=16 | 16 beats 数据正确写入 buffer | rd_addr_gen→axi_rd_master→buffer |
| IT6 | Stride read | 非连续地址 | stride=65×2B | 每行地址正确递增 stride | 地址生成 stride 逻辑 |
| IT7 | Outstanding >1 | 多 outstanding | 连续发 2 个 AR | 2 个 burst 并行传输 | outstanding 计数器 |
| IT8 | AXI SLVERR | 从机错误 | 发 AR 到越界地址 | rd_err=1, err_code=RD_RRESP | 错误上报通路 |

### 3.3 `tb_dma_wr_subsys` — 写 DMA 子系统

| # | Testcase | 目的 | 输入条件 | 预期结果 | 覆盖点 |
|---|---|---|---|---|---|
| IT9 | Burst write D tile | AXI 突发写 | d_storer 发 8 beats | 8 beats 写完，BRESP=OKAY | wr_addr_gen→axi_wr_master |
| IT10 | WSTRB generation | 字节使能 | tile_cols=奇数 | 最后 beat WSTRB 部分有效 | strobe 生成逻辑 |
| IT11 | BRESP error | 写响应错误 | slave 回 SLVERR | wr_err=1 | 写错误聚合 |

---

## 4. 系统测试 Testcase 规划

**状态**: 🔄 待增强（当前仅 smoke test）

### 4.1 `tb_gemm_top` 增强计划

| # | Testcase | 目的 | 输入条件 | 预期结果 | 覆盖点 |
|---|---|---|---|---|---|
| ST1 | Identity matrix | 已知结果验证 | A=I, B=I, C=0 | D=I | 端到端数据通路 |
| ST2 | All-ones 4×4×4 | 简单累加 | A=B=全1, C=0 | D=[[4,4],[4,4]] | 数值正确性 |
| ST3 | Random FP16 compare | 随机比对 | Python 生成随机 A/B/C | RTL D 与 ref D ULP≤1 | 随机覆盖 |
| ST4 | Non-square tile | 边界 tile | M=5,N=5,K=5 | mask 正确，结果 ULP≤1 | 非整 tile 边界 |
| ST5 | Multi-tile pipeline | 多 tile 连续 | M=8,N=8,K=8 (2×2 tiles) | 2 tiles 结果均正确 | ping-pong + 调度 |
| ST6 | IRQ timing | 中断时序 | cfg_irq_en=1 | irq_o 在 done 后正确断言 | CSR→irq 通路 |
| ST7 | Error to IRQ | 错误中断 | cfg_m=0 | irq_o 断言，err_code 可读 | 错误→中断通路 |
| ST8 | Stride GEMM | 非连续 stride | stride_a=65, stride_b=65 | 结果正确 | stride 地址通路 |

---

## 5. 覆盖率映射

### 5.1 代码覆盖率 → Testcase

| 覆盖类型 | 目标 | 当前 testcase 覆盖 | 缺口 |
|---|---|---|---|
| Line coverage | >95% | 85/85 单元测试通过 | 需收集实际数据 |
| FSM state | 100% | tile_scheduler(8 states), systolic_core(4), axi_master(5) 均已访问 | 需确认 transition 100% |
| FSM transition | 100% | 大部分已覆盖 | ERR→IDLE (soft_reset) 需确认 |
| Branch coverage | >90% | if/else 主要路径已覆盖 | 异常分支（如 axi timeout） |
| Toggle coverage | — | 数据线 toggled | 配置寄存器部分 bit 可能未 toggle |

### 5.2 功能覆盖率 → Testcase

| 功能点 | 覆盖 testcase | 状态 |
|---|---|---|
| FP16 MAC | T1 (pe_cell) | ✅ |
| FP32 accumulate | T1, T9 (systolic_core) | ✅ |
| C fusion | T2 (postproc) | ✅ |
| 4 种舍入 | T3 (postproc) | ✅ |
| NaN/Inf/Sat | T4-T7 (postproc) | ✅ |
| Boundary mask | T3 (systolic_core), T2 (loader) | ✅ |
| Ping-pong buffer | T4 (buffer_bank) | ✅ |
| AXI4 burst | T1 (rd_addr_gen), IT5-IT6 | 🔄 需集成验证 |
| AXI4 error | T3 (err_checker) | ✅ |
| Tile loop | T2 (tile_scheduler) | ✅ |
| IRQ | T1 (csr_if), ST6 | 🔄 系统级需增强 |
| Performance counter | T10 (systolic_core) | ✅ |

---

## 6. 回归执行矩阵

| Testbench | Tests | 仿真时间 | 依赖 | 执行命令 |
|---|---|---|---|---|
| `tb_pe_cell` | 5 | ~1s | 无 | `make SIM=verilator TARGET=pe_cell run` |
| `tb_systolic_core` | 11 | ~2s | pe_cell | `make SIM=verilator TARGET=systolic_core run` |
| `tb_buffer_bank` | 7 | ~2s | 无 | `make SIM=verilator TARGET=buffer_bank run` |
| `tb_a_loader` | 3 | ~2s | buffer_bank | `make SIM=verilator TARGET=a_loader run` |
| `tb_b_loader` | 3 | ~2s | buffer_bank | `make SIM=verilator TARGET=b_loader run` |
| `tb_d_storer` | 4 | ~2s | buffer_bank | `make SIM=verilator TARGET=d_storer run` |
| `tb_postproc` | 12 | ~2s | fp_add_c, fp_round_sat | `make SIM=verilator TARGET=postproc run` |
| `tb_csr_if` | 1 | ~1s | 无 | `make SIM=verilator TARGET=csr_if run` |
| `tb_tile_scheduler` | 3 | ~2s | 无 | `make SIM=verilator TARGET=tile_scheduler run` |
| `tb_rd_addr_gen` | 1 | ~1s | 无 | `make SIM=verilator TARGET=rd_addr_gen run` |
| `tb_err_checker` | 4 | ~1s | 无 | `make SIM=verilator TARGET=err_checker run` |
| `tb_gemm_top` | 1 (smoke) | ~3s | 全部 | `make SIM=verilator TARGET=gemm_top run` |
| **合计** | **55+** | **~20s** | | `./regress.sh all` |

---

**文档维护**: 每新增/修改 testcase 时更新对应章节。
**下次更新**: 集成测试 testbench 完成后，补充 IT1-IT11 的详细步骤。
