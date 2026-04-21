# GEMM 架构文档目录

本目录将 GEMM 整体架构拆分为可独立评审的子模块文档，便于并行开发与验证。

## 文档清单
- `00_system_overview.md`：系统级架构、数据流、时序与模块关系
- `01_csr_and_register_map.md`：配置/状态寄存器（CSR）与软件接口
- `02_scheduler_and_control.md`：调度器、状态机、tile 循环控制
- `03_dma_and_axi.md`：AXI 读写 DMA 子系统与带宽策略
- `04_onchip_buffer.md`：片上缓存组织、bank 规划与双缓冲
- `05_compute_core_pe_array.md`：计算核心（PE 阵列）与数值路径
- `06_verification_and_performance.md`：验证方案与性能度量方法

## 推荐阅读顺序
1. `00_system_overview.md`
2. `01_csr_and_register_map.md`
3. `02_scheduler_and_control.md`
4. `03_dma_and_axi.md`
5. `04_onchip_buffer.md`
6. `05_compute_core_pe_array.md`
7. `06_verification_and_performance.md`
