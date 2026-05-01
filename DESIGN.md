# GEMM Accelerator 总设计文档 (Design Master Document)

**版本**: v0.2  
**日期**: 2026-05-01  
**项目**: 脉动阵列 FP16 GEMM (D = A×B + C)  
**目标**: 1 TOPS 峰值，AXI4 接口  

---

## 1. 项目概述

本文档是数字IC设计全流程的纲领性文件。除了已有的 `ARCHITECTURE.md` 和 `spec/` 目录下的模块规格，一个可流片的数字IC项目还需要**约束文件、流程定义、检查清单**三大支柱。

### 1.1 已有交付物

| 文档/代码 | 路径 | 状态 |
|-----------|------|------|
| 架构定义 | `ARCHITECTURE.md` | ✅ 完成 |
| 模块清单 | `spec/modules.md` | ✅ 完成 |
| 模块Spec (7份) | `spec/*.md` | ✅ 完成 |
| `pe_cell` RTL | `rtl/pe_cell.sv` | ✅ 完成 + Verilator验证 |
| `pe_cell` Testbench | `tb/tb_pe_cell.sv` | ✅ 完成 |

### 1.2 设计流程总览

```
┌─────────────────────────────────────────────────────────────┐
│  Phase 1: 系统架构 (System Architecture)                      │
│  ├── 已有: ARCHITECTURE.md, spec/                            │
│  └── 缺失: 性能建模 (Performance Model)                       │
├─────────────────────────────────────────────────────────────┤
│  Phase 2: 微架构/详细设计 (Micro-architecture)                │
│  ├── 已有: 模块划分、接口定义                                 │
│  └── 缺失: 时钟/复位规范、CDC方案、功耗预算                   │
├─────────────────────────────────────────────────────────────┤
│  Phase 3: RTL实现 (RTL Implementation)                      │
│  ├── 已有: pe_cell.sv                                        │
│  └── 缺失: Coding Style Guide, Lint规则, 可综合性检查         │
├─────────────────────────────────────────────────────────────┤
│  Phase 4: 验证 (Verification)                               │
│  └── 缺失: Verification Plan, 参考模型, 覆盖率目标             │
├─────────────────────────────────────────────────────────────┤
│  Phase 5: 逻辑综合 (Logic Synthesis)                          │
│  └── 缺失: SDC约束, DFT Spec, 综合脚本                        │
├─────────────────────────────────────────────────────────────┤
│  Phase 6: 物理实现 (Physical Implementation)                  │
│  └── 缺失: Floorplan, 功耗域(UPF), 布局布线脚本               │
├─────────────────────────────────────────────────────────────┤
│  Phase 7: 签核 (Sign-off)                                     │
│  └── 缺失: STA, DRC/LVS, 功耗分析, 签核Checklist              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. 缺失文档清单（按优先级排序）

### 2.1 🔴 高优先级（阻塞RTL推进）

#### A. RTL Coding Style Guide (`docs/coding_style.md`)
**为什么必须**: 25个模块需要多人协作，没有统一规范会产生不可综合代码和lint爆炸。

必须包含：
- **命名规范**: 模块名、信号名、常量名格式（如 `snake_case`，`i_`/`o_`/`w_` 前缀）
- **可综合子集**: 禁止 `always_comb` 中的 latch、`initial` 块（除仿真外）、阻塞赋值在时序逻辑中
- **参数化规范**: `localparam` vs `parameter`，默认值策略
- **注释规范**: 模块头模板、功能段落分隔
- **FPGA/ASIC 双目标**: 哪些构造在ASIC中可用但在FPGA中受限（如 `always_latch`）

#### B. Clock & Reset Specification (`docs/clock_reset.md`)
**为什么必须**: 涉及AXI4（通常异步时钟）、DMA与Core可能分频。

必须包含：
- 时钟树: `clk_core` (>=1GHz), `clk_axi` (通常 <= clk_core/2 或同步)
- 复位策略: 异步复位同步释放 (async assert, sync deassert)，`rst_n` 极性
- **CDC (Clock Domain Crossing)**: AXI4-Lite 配置寄存器到 `clk_core` 的握手方案（建议两级同步器 + 脉冲展宽）
- 门控时钟: 何时插入 `ICG` (Integrated Clock Gating) 以节省功耗

#### C. Verification Plan (`docs/verification_plan.md`)
**为什么必须**: `pe_cell` 只有一个单模块testbench，顶层需要系统级验证。

必须包含：
- **验证金字塔**: Unit (模块级) → Integration (子系统级) → System (端到端)
- **参考模型**: Python/C++ 的黄金参考模型，用于逐元素比对（允许 ULP 阈值）
- **测试用例矩阵**:
  - 维度: M/N/K = 1, 8, 65, 1024, 2048+1（边界）
  - 数据模式: 全0、全1、随机、结构化（如单位矩阵）
  - Stride: 连续 vs 非连续
  - 数值: 正常、subnormal、Inf、NaN
- **覆盖率目标**: 行覆盖率 >95%，FSM覆盖率100%，交叉覆盖率（维度×模式）
- **回归脚本**: `make regress` 一键运行全部test，生成报告

---

### 2.2 🟡 中优先级（阻塞综合/物理实现）

#### D. Timing Constraints (SDC) (`constraints/timing.sdc`)
**为什么必须**: 没有SDC，综合工具不知道哪些路径需要优化。

必须包含：
- `create_clock` 定义 `clk_core` 和 `clk_axi`
- `set_clock_groups` 处理异步时钟
- `set_false_path`: 配置寄存器到状态机的静态路径
- `set_multicycle_path`: 脉动阵列的 feed-through 路径（A/B 传播不是单周期约束）
- `set_max_delay`: AXI4 协议要求的握手信号延迟
- `set_input_delay` / `set_output_delay`: 芯片顶层IO约束

#### E. DFT Specification (`docs/dft_spec.md`)
**为什么必须**: 流片必须支持生产测试。

必须包含：
- **扫描链 (Scan)**: 全芯片扫描插入策略，扫描时钟共享方案
- **MBIST**: Buffer Bank (SRAM) 的存储器内建自测试
- **JTAG**: IEEE 1149.1 接口，用于边界扫描和调试
- **测试模式**: `test_mode` 信号定义，隔离功能逻辑与测试逻辑

#### F. Power Intent (UPF/CPF) (`constraints/power.upf`)
**为什么必须**: 功耗是加速器核心指标。

必须包含：
- 功耗域 (Power Domain) 划分: `PD_CORE`, `PD_AXI`, `PD_ALWAYS_ON`
- **Retention**: 当加速器空闲时，配置寄存器是否保留
- **Clock Gating**: 模块级门控策略（如 `tile_scheduler` 在DMA等待时休眠）
- **电压域**: 是否支持 DVFS（动态电压频率调整）

---

### 2.3 🟢 低优先级（工程化/流片前）

#### G. Floorplan & Physical Constraints (`docs/floorplan.md`)
- 目标工艺: 如 TSMC 7nm / SMIC 28nm / FPGA (Xilinx UltraScale+)
- 面积预算: 基于 `P_M×P_N` PE数量、Buffer大小估算
- 宏单元布局: Buffer Bank 应靠近阵列，DMA接口靠近芯片边缘
- IO Ring: AXI4 数据位宽（如 512-bit）对应的 pad 数量

#### H. Integration Specification (`docs/integration_spec.md`)
- 顶层连接检查清单: 所有模块端口是否连接、无悬空
- 总线协议合规: AXI4 的 AWID/ARID 宽度、burst 类型支持
- 参数一致性: `P_M`, `P_N` 在所有模块中的传递与检查

#### I. Sign-off Checklist (`docs/signoff_checklist.md`)
最终流片前必须逐项签字：
- [ ] **功能签核**: 全部回归测试通过，覆盖率达标
- [ ] **时序签核**: STA 无 setup/hold 违例（含OCV/SOCV分析）
- [ ] **功耗签核**: 峰值功耗、平均功耗、IR Drop 分析通过
- [ ] **物理签核**: DRC, LVS, ANT (天线效应), EM (电迁移)
- [ ] **DFT签核**: 扫描链可测性 >98%，MBIST 通过
- [ ] **文档签核**: 所有设计文档更新至最终版

---

## 3. 各阶段详细定义

### 3.1 Phase 3: RTL实现阶段（当前所在阶段）

**输入**: 模块Spec + Coding Style Guide  
**输出**: 可综合RTL + 模块级testbench  
**工具链**: Verilator（仿真）→ 后续迁移至 VCS/Xcelium（综合前仿真）

**当前状态**:
- `pe_cell` — 完成，5/5 单测通过（FP32 累加、传播、清零、冻结）
- `systolic_core` — 完成，31/31 集成测试通过
  - 包含 `core_err` 检测（protocol_mismatch, internal_overflow, illegal_mode）
  - 包含调试模式（single_pe, bypass_acc, force_mask）
  - 包含性能计数器（active/fill/drain/stall）
  - 包含错误码输出（err_code[2:0]）
- `array_io_adapter` — 完成，集成验证通过（skew 延迟、valid 传播）
- `acc_ctrl` — 独立模块 RTL 完成，功能等效集成于 `systolic_core` FSM
- `buffer_bank` — 完成，12/12 Verilator tests pass（ping-pong、bank 冲突、byte-masked write）
- `a_loader` — 完成，6/6 Verilator tests pass（row-major DMA→buffer reorder）
- `b_loader` — 完成，6/6 Verilator tests pass（column-major DMA→buffer reorder）
- `d_storer` — 完成，4/4 Verilator tests pass（postproc→buffer row-major writeback）
- **`postproc` + `fp_add_c` + `fp_round_sat`** — 完成，12/12 Verilator tests pass
  - `fp_round_sat`: FP32→FP16 转换，4 种 round mode，饱和/Inf/NaN/DENORM 处理
  - `fp_add_c`: FP32 acc + FP16 C 融合或旁路，简化行为级加法
  - `postproc`: 3-stage 流水线（align→add_c→round_sat），valid/ready 反压，sticky 异常计数器
- **M1 计算核心子系统 + On-chip Buffer 子系统 + Postprocess 子系统 全部完成**
- **全部 7 份 Spec 已完善至 v0.2/v0.3**（含完整端口定义、FSM、寄存器映射）
  - `postprocess_numeric_spec.md` — v0.3
  - `onchip_buffer_reorder_spec.md` — v0.2
  - `dma_axi_access_spec.md` — v0.2
  - `top_system_control_spec.md` — v0.2
  - `reliability_monitoring_verifassist_spec.md` — v0.2
  - `systolic_compute_core_spec.md` — v0.2
  - `modules.md` — v0.1
- 下一步按 `spec/modules.md` 推进 M2 模块 RTL（tile_scheduler, dma_rd/dma_wr, axi_*_master, gemm_top）

**必须遵守的约束**:
1. 所有模块必须使用 `pe_cell` 中验证过的 `fp16_to_fp32` / `fp32_to_fp16` 转换函数（或统一放入 `gemm_pkg.sv` 包中）
2. 不允许在RTL中使用 `real` 类型（`fp16_mac_soft` 是仿真专用，综合时必须替换为 hardened IP 或手写RTL）
3. 时序逻辑统一使用 `always_ff @(posedge clk or negedge rst_n)`
4. 组合逻辑统一使用 `always_comb`，禁止隐式 latch

### 3.2 Phase 4: 验证阶段

**分层验证策略**:

| 层级 | 对象 | 环境 | 通过标准 |
|------|------|------|----------|
| Unit | 单个模块 | Verilator/VCS + UVM agent | 功能覆盖100% |
| Integration | 子系统（如 DMA+Buffer+Scheduler） | UVM env + reference model | 协议检查通过 |
| System | `gemm_top` 端到端 | FPGA 原型 / Palladium | 与软件GEMM结果逐元素比对 |

**参考模型建议**:
```python
# golden_model.py（建议放在 tools/ 目录）
import numpy as np

def gemm_ref(A, B, C, dtype=np.float16):
    A_f = A.astype(np.float32)
    B_f = B.astype(np.float32)
    C_f = C.astype(np.float32)
    D_f = A_f @ B_f + C_f
    return D_f.astype(dtype)  # 最后转回FP16
```

### 3.3 Phase 5: 逻辑综合阶段

**综合策略**:
- **自顶向下 (Top-Down)**: 先综合 `gemm_top` 评估整体面积/时序
- **自底向上 (Bottom-Up)**: `pe_cell` 先单独综合，确认时序闭合并固化
- **编译策略**: `compile_ultra` (Design Compiler) 或 `syn_opt` (Genus)

**关键约束**:
- PE 阵列内部的数据流路径（A/B 传播）是 **feed-through**，需设为 `set_false_path` 或 `set_multicycle_path`
- 累加器路径 `acc_reg <= mac_result` 是关键路径，需重点优化

### 3.4 Phase 6: 物理实现阶段

**布局建议**:
```
┌────────────────────────────────────────┐
│  IO Ring (AXI4 data/addr/ctrl)        │
├────────────────────────────────────────┤
│  DMA + AXI Master    │  CSR + IRQ      │
├──────────────────────┼─────────────────┤
│  A_BUF[0]  A_BUF[1] │ B_BUF[0] B_BUF[1]│
├──────────────────────┴─────────────────┤
│          Systolic Array PE[M][N]       │
│          (占面积最大，居中放置)           │
├────────────────────────────────────────┤
│  PostProc + D_Storer + Write DMA       │
└────────────────────────────────────────┘
```

**布线注意**:
- 阵列内部的 A/B 传播是局部连接（PE(i,j) -> PE(i,j+1) / PE(i+1,j)），布线相对规则
- 全局控制信号（`acc_clear`, `acc_hold`）需做时钟树平衡（CTS）

---

## 4. 工具链推荐

| 阶段 | 开源/低成本方案 | 商业方案 | 备注 |
|------|----------------|----------|------|
| 仿真 | Verilator | VCS, Xcelium | Verilator适合模块级，顶层需商用工具 |
| 验证 | cocotb / SV-UVM | UVM + Verification IP | 建议顶层用UVM |
| 综合 | Yosys (FPGA) | Design Compiler, Genus | ASIC必须用DC/Genus |
| 形式验证 | Yosys-smtbmc | JasperGold, Conformal | 协议检查推荐 |
| 物理实现 | OpenROAD | ICC2, Innovus | 先进工艺用商业工具 |
| DFT | N/A | Tessent, DFTAdvisor | 必须商业工具 |

---

## 5. 项目计划建议（更新版）

在 `spec/modules.md` 的 M1-M4 基础上，增加验证与物理实现里程碑：

| 里程碑 | 交付物 | 周期估算 | 阻塞项 |
|--------|--------|----------|--------|
| **M1** | `pe_cell` + `systolic_core` + `buffer_bank` + `gemm_top` MVP | 2周 | Coding Style Guide |
| **M1.5** | Unit Test 全部通过（含 coverage 报告） | 1周 | Verification Plan |
| **M2** | `dma_rd/wr` + `tile_scheduler` + `postproc` + 边界mask | 2周 | SDC草稿 |
| **M2.5** | Integration Test + 参考模型比对 | 1周 | 参考模型代码 |
| **M3** | 双缓冲 + 性能优化 + `perf_counter` | 1周 | Floorplan草稿 |
| **M3.5** | FPGA原型验证 / Emulation | 2周 | FPGA板卡 |
| **M4** | 综合 + DFT + 物理实现 + 签核 | 3周 | DFT Spec, UPF |
| **M5** | 流片 / FPGA bitstream 生产 | 2周 | 工艺PDK |

---

## 6. 立即行动项（Action Items）

1. **本周**: 写 `docs/coding_style.md` 和 `docs/verification_plan.md`
2. **下周**: 推进 `systolic_core` RTL（实例化 `pe_cell` 阵列）
3. **同步**: 建立 `tools/golden_model.py` 参考模型
4. **准备**: 起草 `constraints/timing.sdc` 初稿（可先写 `clk_core` 周期约束）

---

**文档维护**: 本文件由项目技术负责人维护。每次重大架构变更或新增约束时更新版本号。

**相关文档索引**:
- 架构定义 → `ARCHITECTURE.md`
- 模块清单 → `spec/modules.md`
- 详细Spec → `spec/*.md`
- 编码规范 → `docs/coding_style.md` (待创建)
- 验证计划 → `docs/verification_plan.md` (待创建)
