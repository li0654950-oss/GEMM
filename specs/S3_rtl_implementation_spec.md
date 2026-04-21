# S3 - RTL 实现规格（RTL Implementation Spec）

## 1. RTL 结构建议
- 顶层：`gemm_top`
- 子模块：`csr`, `scheduler`, `dma_rd`, `dma_wr`, `buffer`, `pe_array`

## 2. 端口约定
- 时钟复位：`clk`, `rst_n`
- 配置接口：AXI4-Lite 或同等 CSR 总线
- 数据接口：AXI4 Full（读/写）

## 3. 编码规范
- 所有时序逻辑使用非阻塞赋值
- 同步复位/异步复位风格全局一致
- 参数化通过 `parameter` 统一配置
- 关键状态机采用 `enum`（若语言支持）

## 4. 时序与面积约束
- 路径分级流水，避免长组合链
- PE 与 Buffer 之间接口寄存化
- 对跨模块握手加超时/断言

## 5. 可测试性
- 暴露必要 debug 计数器
- 提供仿真可观测 hook（ifdef）
