# M0 - Top Level 模块规格

## 1. Features
- 支持 GEMM：`D = A × B + C`
- 支持 tile 流水与双缓冲
- 支持任务级启动/完成/异常上报

## 2. Interface
### 2.1 外部接口
- `clk`, `rst_n`
- CSR 配置总线（AXI4-Lite 或等效）
- AXI4 读通道（A/B/C）
- AXI4 写通道（D）
- `irq`（可选）

### 2.2 内部接口
- `csr_if`：配置与状态
- `sched_if`：命令与阶段握手
- `dma_rd_if` / `dma_wr_if`：读写请求与响应
- `buf_if`：buffer 读写端口
- `compute_if`：计算输入输出

## 3. Block Diagram
```text
+---------------------------------------------------------------+
|                           gemm_top                            |
|                                                               |
|  +------+   +-----------+   +---------+   +---------------+   |
|  | CSR  |-->| Scheduler |-->| Buffer  |<->| Compute Core  |   |
|  +------+   +-----------+   +---------+   +---------------+   |
|       \            |             ^               |            |
|        \           v             |               v            |
|         \------>  DMA_RD  ------/            DMA_WR          |
+---------------------------------------------------------------+
```

## 4. Architecture Diagram
```text
CPU -> CSR -> Scheduler -> {DMA_RD -> Buffer -> PE Array -> DMA_WR}
                       \-> Error/Status/IRQ
```

## 5. Function
1. 软件配置参数并置 `start`
2. 调度器发起 tile 级任务
3. DMA_RD 搬运 A/B/C 到 Buffer
4. Compute Core 执行 MAC 与加 C
5. DMA_WR 回写 D
6. 完成后置 `done`，异常置 `err_code`
