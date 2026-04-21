# M4 - Buffer 模块规格

## 1. Features
- A/B 双缓冲，降低计算等待
- 支持 bank 化并行读写
- 支持 ACC 部分和缓存

## 2. Interface
- DMA 写入口：`dma_wr_data`, `dma_wr_en`, `dma_wr_addr`
- 计算读入口：`comp_rd_addr_a/b/c`, `comp_rd_data_a/b/c`
- 计算写入口：`acc_wr_data`, `acc_wr_en`
- 控制：`buf_sel_pingpong`, `flush`, `clear`

## 3. Block Diagram
```text
DMA In -> Ping/Pong SRAM Banks <-> Compute Ports
                       |
                    ACC Buffer
```

## 4. Architecture Diagram
```text
Cycle t:   DMA -> PING   , Compute <- PONG
Cycle t+1: DMA -> PONG   , Compute <- PING
```

## 5. Function
- 提供无冲突访问策略（bank interleave）
- tile 切换时进行 ping/pong 翻转
- 写回未完成前保护输出缓存不被覆盖
