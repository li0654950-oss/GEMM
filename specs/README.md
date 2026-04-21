# GEMM 分阶段规格（Specs）目录

本目录用于定义 GEMM 硬件项目各阶段（从需求到集成）的可执行规格，作为实现、验证与评审的统一依据。

## 阶段清单
- `S0_product_spec.md`：产品与需求规格（目标、边界、验收）
- `S1_architecture_spec.md`：系统架构规格（模块划分、接口、数据流）
- `S2_microarchitecture_spec.md`：微架构规格（tile、buffer、流水、时序）
- `S3_rtl_implementation_spec.md`：RTL 实现规格（编码约束、模块端口、参数）
- `S4_verification_spec.md`：验证规格（策略、用例、覆盖率、签核）
- `S5_performance_power_spec.md`：性能与功耗规格（指标、测量、优化）
- `S6_integration_delivery_spec.md`：集成与交付规格（寄存器、软件、文档、发布）

## 推荐使用方式
1. 方案评审先看 `S0` 和 `S1`
2. 设计开发执行 `S2` 和 `S3`
3. 验证签核遵循 `S4`
4. 性能/功耗收敛参考 `S5`
5. 对外交付按 `S6` 检查
