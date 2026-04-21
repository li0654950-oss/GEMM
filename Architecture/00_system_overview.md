# 00 - 系统总览（System Overview）

## 1. 目标
实现 FP16 GEMM：
\[
D = A \times B + C
\]

矩阵定义：
- `A(m, k)`
- `B(k, n)`
- `C(m, n)`
- `D(m, n)`

## 2. 顶层模块
- CSR/寄存器模块
- Scheduler/控制器
- DMA 读（A/B/C）
- On-chip Buffer
- Compute Core（PE Array）
- DMA 写（D）

## 3. 顶层数据流
1. CPU 配置 CSR（维度、地址、stride、tile、启动位）
2. 调度器触发 DMA 将 A/B/C tile 搬入片上缓存
3. 计算核心进行 k 维累加并与 C 融合
4. DMA 写回 D tile
5. 全部 tile 完成后置位 `done`

## 4. 流水与并行策略
- Tile 级流水：`load(next)` 与 `compute(curr)` 重叠
- 推荐双缓冲：Ping/Pong Buffer
- 目标：提升总线与计算单元利用率

## 5. 设计原则
- 参数化：PE、tile、AXI 数据宽度、buffer 深度
- 可验证：关键计数器与状态可观测
- 可扩展：支持后续量化、混合精度或稀疏优化
