# S1 - 系统架构规格（Architecture Spec）

## 1. 模块划分
- CSR/寄存器模块
- Scheduler/控制器
- DMA 读子系统（A/B/C）
- On-chip Buffer
- Compute Core（PE Array）
- DMA 写子系统（D）

## 2. 顶层时序
1. CPU 配置寄存器
2. `start` 触发后进行参数检查
3. 进入 tile 流水：读入 -> 计算 -> 写回
4. 全部完成后置 `done`，可中断

## 3. 架构约束
- 支持 tile 计算
- 支持双缓冲（ping/pong）
- 数据与控制路径解耦（减少全局阻塞）

## 4. 错误处理策略
- 配置阶段错误：直接拒绝启动
- 运行阶段错误：终止任务并上报 `err_code`
- 所有错误状态可通过 STATUS 寄存器读取
