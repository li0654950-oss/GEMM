# 02 - 调度器与控制器

## 1. 模块职责
- 管理三层 tile 循环（m/n/k）
- 协调 DMA、Buffer 与 Compute Core
- 负责任务级状态转换与错误恢复

## 2. 状态机建议
- `IDLE`：等待 `start`
- `CFG_CHECK`：参数检查
- `PRELOAD`：首个 tile 装载
- `COMPUTE_LOOP`：计算/搬运并行
- `STORE`：结果写回
- `DONE`：任务完成
- `ERROR`：异常终止

## 3. Tile 循环伪代码
```text
for mo in range(0, M, Tm):
  for no in range(0, N, Tn):
    acc = 0
    for ko in range(0, K, Tk):
      load A_tile(mo, ko)
      load B_tile(ko, no)
      acc += A_tile * B_tile
    load C_tile(mo, no)
    D_tile = acc + C_tile
    store D_tile(mo, no)
```

## 4. 并行优化
- 双缓冲：`compute(buffer0)` 与 `load(buffer1)` 重叠
- 预取阈值：根据 DMA 延迟提前触发下一 tile
- 回压处理：当写回阻塞时暂停新任务发射

## 5. 可观测信号（建议）
- 当前 `mo/no/ko` 索引
- 状态机状态
- stall 原因（读阻塞/写阻塞/计算等待）
