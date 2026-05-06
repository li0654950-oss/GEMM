# GEMM 矩阵乘法硬件单元设计规格

## 1. 项目目标
设计并实现一个高性能 GEMM（General Matrix Multiply）硬件单元，完成以下计算：

\[
D = A \times B + C
\]

目标算力：**1 TOPS @ FP16**（理论峰值）。

---

## 2. 功能规格

### 2.1 数据类型
- 矩阵 `A`、`B`、`C`、`D` 均采用 **FP16** 数据类型。

### 2.2 矩阵维度定义
- `A` 的维度：`(m, k)`
- `B` 的维度：`(k, n)`
- `C` 的维度：`(m, n)`
- `D` 的维度：`(m, n)`

### 2.3 计算行为
- 核心计算公式为：`D = A × B + C`
- 输出矩阵 `D` 的每个元素满足标准矩阵乘加定义。

---

## 3. 接口规格

### 3.1 输入接口
- 使用 **AXI4.0 Slave** 接口接收输入矩阵数据：
  - `A` 矩阵
  - `B` 矩阵
  - （可扩展）`C` 矩阵与配置参数

### 3.2 输出接口
- 使用 **AXI4.0 Master** 接口输出结果矩阵 `D`。

### 3.3 建议的可配置参数（推荐）
为便于验证与系统集成，建议在寄存器中支持：
- `m / n / k` 尺寸配置
- 输入/输出矩阵首地址
- 启动、状态、中断控制
- 错误状态上报（越界、对齐、非法配置等）

---

## 4. 性能与优化要求

### 4.1 基础要求
- 在 FP16 数据路径下达到目标算力指标（1 TOPS，按设定工作频率评估）。

### 4.2 加分项
1. **带宽优化**
   - 对输入/输出链路进行带宽利用率优化；
   - 需给出定量数据（如吞吐、总线利用率、突发效率）。

2. **单位算力功耗优化**
   - 优化每 TOPS 功耗表现（如 TOPS/W）；
   - 需提供相对完整的测试数据与对比方法。

---

## 5. 交付物清单与当前状态

### 5.1 项目状态总览

**RTL 实现**：25 个 SystemVerilog 模块全部编码完成，涵盖控制平面、DMA/AXI 访问、片上缓存、脉动阵列计算核心、后处理、可靠性监控六大子系统。

**仿真验证**：
- 85 项单元测试全部通过（Verilator 5.020）
- 顶层集成冒烟测试通过（`tb_gemm_top`：AXI4-Lite CSR 配置 → DMA 读 → 脉动阵列计算 → DMA 写 → IRQ 断言，185 cycles 完成单 tile 4×4×4 FP16 GEMM）

### 5.2 快速开始

```bash
# 编译顶层冒烟测试
cd tb
make SIM=verilator TARGET=gemm_top compile

# 运行仿真
./build/obj_dir/Vtb_gemm_top

# 运行全部单元测试回归
make SIM=verilator regress

# 生成 VCD 波形（可选，加 --trace 参数）
./build/obj_dir/Vtb_gemm_top --trace
```

### 5.3 代码与验证环境

| 交付物 | 路径 | 状态 |
|--------|------|------|
| RTL 源码（25 模块） | `rtl/*.sv` | ✅ 完成 |
| Testbench（12 模块） | `tb/tb_*.sv` | ✅ 完成 |
| 仿真 Makefile | `tb/Makefile` | ✅ 完成 |
| 黄金参考模型 | `tools/gemm_ref.py` | 🔄 待创建 |
| 回归脚本 | `make regress` | 🔄 待完善 |

### 5.4 设计文档

| 文档 | 路径 | 状态 |
|------|------|------|
| 架构设计 | `ARCHITECTURE.md` | ✅ 完成 |
| 模块清单 | `spec/modules.md` | ✅ 完成 |
| 模块 Spec（7 份） | `spec/*.md` | ✅ 完成 |
| 实现规格 | `IMPLEMENTATION.md` | ✅ 完成 |
| 编码规范 | `docs/coding_style.md` | ✅ 完成 |
| 验证计划 | `docs/verification_plan.md` | ✅ 初稿 |
| 时钟/复位规范 | `docs/clock_reset.md` | 🔄 待创建 |
| SDC 约束 | `constraints/timing.sdc` | 🔄 待创建 |
| DFT Spec | `docs/dft_spec.md` | 🔄 待创建 |
| Floorplan | `docs/floorplan.md` | 🔄 待创建 |
| 签核清单 | `docs/signoff_checklist.md` | 🔄 待创建 |

### 5.5 仿真验证结果

| 层级 | 模块数 | 测试数 | 通过 | 仿真器 |
|------|--------|--------|------|--------|
| Unit | 11 | 85 | 85 | Verilator 5.020 |
| Integration | 1 | 1 | 1 | Verilator 5.020 |
| System | 0 | 0 | 0 | — |

全部 11 个模块单元测试 + 1 项顶层冒烟测试通过，无失败。

---

## 6. 验收建议

建议在最终验收中提供：
- 典型矩阵规模下的性能数据（吞吐、时延）
- 精度一致性检查（与软件参考模型对比）
- 不同带宽条件下的性能退化曲线
- 功耗与温升测试摘要
