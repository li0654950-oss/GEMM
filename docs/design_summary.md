# GEMM Accelerator 设计小结与待改进

**版本**: v1.0
**日期**: 2026-05-05
**项目**: FP16 Systolic Array GEMM (D = A×B + C)

---

## 1. 设计状态总结

### 1.1 已实现交付物

| 类别 | 交付物 | 状态 | 说明 |
|---|---|---|---|
| RTL 源码 | 25 个 SystemVerilog 模块 | ✅ 完成 | 控制/DMA/Buffer/计算/后处理/监控 |
| 单元测试 | 11 个 testbench | ✅ 85/85 PASS | Verilator 5.020 |
| 顶层冒烟 | `tb_gemm_top.sv` | ✅ PASS | AXI-Lite → DMA → 计算 → DMA → IRQ |
| 架构文档 | `ARCHITECTURE.md` | ✅ 完成 | 架构框图、数据流、Tile 策略 |
| 实现规格 | `IMPLEMENTATION.md` | ✅ 完成 | 端口定义、状态机、寄存器映射 |
| 模块规格 | 7 份 `spec/*.md` | ✅ 完成 | 各子系统详细设计 |
| 编码规范 | `docs/coding_style.md` | ✅ 完成 | 命名、可综合子集、Verilator 兼容 |
| 时钟复位 | `docs/clock_reset.md` | ✅ 完成 | 时钟域、复位策略、CDC |
| 集成规格 | `docs/integration_spec.md` | ✅ 完成 | 顶层连接、参数一致性 |
| 验证计划 | `docs/verification_plan.md` | ✅ v0.2 | 金字塔、测试矩阵、回归 |
| 资源分析 | `docs/resource_analysis.md` | ✅ 完成 | 面积/门数/功耗估算 |
| 参考模型 | `tools/gemm_ref.py` | ✅ 完成 | Python 黄金模型 + ULP 对比 |
| 回归脚本 | `regress.sh` | ✅ 完成 | unit/system/all 阶段 |

### 1.2 设计核心特征

- **架构**：Output-Stationary 脉动阵列，A 左入 B 上入
- **精度**：FP16 乘法 + FP32 累加 + FP16 输出（RNE 舍入）
- **接口**：AXI4-Lite CSR 配置 + AXI4 数据通路
- **调度**：tile_scheduler 三重循环 + 边界 mask + ping-pong buffer
- **参数化**：`P_M`, `P_N`, `ELEM_W`, `ACC_W`, `AXI_DATA_W` 全局可调

### 1.3 验证成熟度

| 层级 | 测试数 | 通过 | 覆盖率 | 状态 |
|---|---|---|---|---|
| Unit | 85 | 85 | 行覆盖未收集 | ✅ 功能通过 |
| System Smoke | 1 | 1 | 仅 IRQ 通路 | ⚠️ 需增强 |
| Integration | 0 | 0 | — | ❌ 未开始 |
| Reference Compare | 0 | 0 | — | ❌ 未开始 |

---

## 2. 已知问题（Known Issues）

### 2.1 RTL 问题

| # | 问题 | 影响 | 严重程度 | 模块 | 状态 |
|---|---|---|---|---|---|
| 1 | `fp16_mac_soft` 为纯行为级模型，不可综合 | 需替换为 hardened IP | 🔴 高 | `pe_cell` | 🔄 待替换 |
| 2 | `gemm_top` 内部部分子模块为实例化占位，连线简化 | 功能正确但非最优 | 🟡 中 | `gemm_top` | ✅ MVP 可接受 |
| 3 | AXI4 outstanding 未充分测试（>1 场景） | 可能协议违规 | 🟡 中 | `axi_rd_master` | 🔄 待测试 |
| 4 | 双缓冲切换在边界 tile 场景未验证 | 可能数据竞争 | 🟡 中 | `buffer_bank` | 🔄 待测试 |
| 5 | CDC 未实现（`clk` 与 `clk_axi` 同源同频假设） | 未来多频场景需补 | 🟢 低 | 全局 | 🔄 未来增强 |

### 2.2 验证问题

| # | 问题 | 影响 | 严重程度 | 状态 |
|---|---|---|---|---|
| 6 | `tb_gemm_top` 仅验证 CSR → IRQ 通路，未比对计算结果 | 无法确认数值正确性 | 🔴 高 | 🔄 待增强 |
| 7 | 无覆盖率数据（line/fsm/branch） | 无法评估验证充分性 | 🔴 高 | 🔄 待收集 |
| 8 | 无集成测试（compute_subsys / DMA_subsys） | 子系统间交互未验证 | 🟡 中 | 🔄 待创建 |
| 9 | 无随机测试生成器 | 边界场景覆盖不足 | 🟡 中 | 🔄 待实现 |
| 10 | 无 AXI4 协议断言（SVA） | 协议违规难以发现 | 🟡 中 | 🔄 待添加 |

### 2.3 文档/流程问题

| # | 问题 | 影响 | 严重程度 | 状态 |
|---|---|---|---|---|
| 11 | 无 SDC 时序约束 | 综合无法进行时序优化 | 🔴 高 | ❌ 未开始 |
| 12 | 无 DFT 规格 | 流片测试不可行 | 🔴 高 | ❌ 未开始 |
| 13 | 无功耗域定义（UPF） | 功耗优化受限 | 🟡 中 | ❌ 未开始 |
| 14 | `README.md` 中部分状态标记仍为 🔄 | 对外展示不准确 | 🟢 低 | 🔄 待更新 |

---

## 3. 待改进项（Improvement Backlog）

### 3.1 高优先级（阻塞后续阶段）

#### 3.1.1 替换 FP16 MAC 软核
**问题**：`fp16_mac_soft` 使用 $bitstoreal 进行浮点转换，纯仿真模型。
**改进**：
- 选项 A：手写可综合 FP16 乘法器 + FP32 加法器（~3000 NAND2）
- 选项 B：调用工艺库 hardened FP16 MAC IP（推荐，面积/功耗优 30-50%）
- 选项 C：FPGA 目标时使用 Xilinx DSP58 原语
**验收标准**：替换后 unit test 仍全绿，时序报告无违规。

#### 3.1.2 增强 gemm_top 系统测试
**问题**：当前仅验证 CSR 配置 → IRQ 断言通路。
**改进**：
1. 在 testbench 中注入已知 FP16 矩阵数据（如单位矩阵 + 全 1）
2. 通过 AXI4 内存模型回读 D 结果
3. 与 Python 参考模型比对（ULP 阈值内）
**验收标准**：至少 3 组已知结果测试通过，ULP 误差 ≤ 1。

#### 3.1.3 SDC 时序约束
**问题**：无约束文件，综合工具无法优化关键路径。
**改进**：
- `create_clock` 定义 `clk` (1 GHz) 和 `clk_axi` (500 MHz)
- `set_multicycle_path` 处理 PE 阵列 feed-through（A/B 传播非单周期关键路径）
- `set_false_path`：CSR 配置寄存器到状态机静态路径
- `set_max_delay`：AXI4 握手信号延迟
**验收标准**：综合后无 setup/hold 违例。

### 3.2 中优先级（功能完善）

#### 3.2.1 覆盖率收集与闭合
**改进**：
- 启用 Verilator `--coverage` 或迁移至 VCS 收集 line/fsm/branch/toggle
- 目标：line > 95%，fsm state/transition = 100%，branch > 90%
- 对未覆盖代码分析是 dead code 还是测试缺口

#### 3.2.2 集成测试环境
**改进**：
- `tb_compute_subsys`：array_io_adapter → systolic_core → acc_ctrl → postproc
- `tb_dma_rd_subsys`：rd_addr_gen → axi_rd_master → AXI stub memory
- `tb_dma_wr_subsys`：wr_addr_gen → axi_wr_master → AXI stub slave
- `tb_buffer_loader`：dma_rd → a_loader/b_loader → buffer_bank

#### 3.2.3 AXI4 协议断言
**改进**：
- 添加 SVA 检查：AW/W/B 通道时序、AR/R 通道时序
- 检查 outstanding 计数器不溢出
- 检查 burst 地址不跨 4KB 边界

#### 3.2.4 随机测试生成器
**改进**：
- Python 脚本生成随机 FP16 矩阵 + 随机维度（1 ~ 1024）
- 自动生成 testbench 输入向量文件
- 自动比对 RTL 波形输出与参考模型

### 3.3 低优先级（工程化/优化）

#### 3.3.1 DFT 规格
- 扫描链插入策略
- MBIST for buffer_bank SRAM
- JTAG 调试接口

#### 3.3.2 功耗域定义（UPF）
- `PD_CORE` / `PD_AXI` / `PD_ALWAYS_ON` 划分
- 时钟门控策略细化

#### 3.3.3 性能优化
- Burst 长度优化：当前 MAX_BURST_LEN=16，评估 32/64 的收益
- Bank 冲突仲裁增强：当前轮询，评估优先级或 age-based
- 累加器模式切换：FP16 acc 模式可减少 30% MAC 功耗

#### 3.3.4 调试增强
- `trace_debug_if` 增加 tile 坐标输出（`tile_m`, `tile_n`, `tile_k`）
- 增加 stall 原因编码（DMA wait / bank conflict / AXI backpressure）

---

## 4. 设计权衡记录（Design Decisions）

| 决策 | 选择 | 放弃方案 | 理由 |
|---|---|---|---|
| Output-Stationary vs Weight-Stationary | OS | WS | C 融合更自然，累加器本地 |
| FP32 vs FP16 累加 | FP32 | FP16 | 精度更好，面积增加 ~30% |
| 双缓冲 vs 单缓冲 | 双缓冲 | 单缓冲 | 重叠 load/compute，带宽友好 |
| AXI4 vs 自定义总线 | AXI4 | 自定义 | SoC 集成友好，IP 复用 |
| Verilator vs VCS (验证) | Verilator 优先 | VCS | 开源、快速迭代 |
| 同源同频 vs 异步时钟 | 同源同频 | 异步 | MVP 简化，CDC 未来补 |
| 参数化阵列 vs 固定阵列 | 参数化 | 固定 | 支持 4×4 验证 → 16×16 综合 |

---

## 5. 风险与缓解

| 风险 | 可能性 | 影响 | 缓解措施 |
|---|---|---|---|
| FP16 MAC IP 时序不达 1 GHz | 中 | 高 | 预留 pipeline 级数参数；评估 800 MHz 仍可达标 |
| 外部 DDR 带宽不足 | 高 | 高 | 增大 tile size 减少访存次数；评估 HBM2/3 |
| SRAM 面积超出预算 | 中 | 中 | 评估压缩/稀疏方案；减少 ping-pong 套数 |
| Verilator 覆盖率收集能力弱 | 中 | 低 | 验证阶段后迁移至 VCS/Questa |
| 多项目并行导致 RTL 失同步 | 低 | 中 | 回归脚本每日运行；git hook 拦截未通过提交 |

---

## 6. 下一步行动计划

| 顺序 | 任务 | 预估工时 | 阻塞项 | 优先级 |
|---|---|---|---|---|
| 1 | 增强 `tb_gemm_top`：注入数据 + 结果比对 | 1 天 | 无 | 🔴 高 |
| 2 | 收集覆盖率数据（Verilator/VCS） | 0.5 天 | 无 | 🔴 高 |
| 3 | 编写验证 testcase 详细分析文档 | 1 天 | 无 | 🔴 高 |
| 4 | 创建 SDC 约束初稿 | 1 天 | 无 | 🔴 高 |
| 5 | 搭建集成测试环境（compute + DMA） | 2 天 | testcase 文档 | 🟡 中 |
| 6 | 替换 `fp16_mac_soft` 为可综合模型 | 2 天 | MAC IP 选型 | 🟡 中 |
| 7 | 添加 AXI4 SVA 断言 | 1 天 | 无 | 🟡 中 |
| 8 | 编写 DFT 规格 | 1 天 | SDC 完成 | 🟢 低 |
| 9 | 编写 UPF 功耗域定义 | 0.5 天 | 面积数据确认 | 🟢 低 |

---

**文档维护**: 每次重大变更或问题关闭时更新。
**下次评审**: 集成测试通过后、综合前。
