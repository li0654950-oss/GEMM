# M2 - Scheduler 模块规格

## 1. Features
- 管理 `m/n/k` 三维 tile 循环
- 协调 DMA、Buffer、Compute 并行执行
- 提供异常中止与恢复到 IDLE

## 2. Interface
- 输入：`start`, `cfg(m,n,k,tm,tn,tk)`, `dma_done`, `compute_done`, `wr_done`, `err_in`
- 输出：`dma_launch`, `compute_launch`, `wr_launch`, `tile_index`, `busy`, `done`, `err_out`

## 3. Block Diagram
```text
Config -> Loop Generator -> FSM -> Task Dispatch -> Handshake Arbiter
```

## 4. Architecture Diagram
```text
IDLE -> PRELOAD -> COMPUTE_LOOP -> STORE -> DONE
   \-----------------ERROR--------------------/
```

## 5. Function
- 生成 `(mo,no,ko)` 索引
- 保证 `load(next)` 与 `compute(curr)` 重叠
- 写回阻塞时暂停新任务发射
- 任一子模块报错即转入 `ERROR`
