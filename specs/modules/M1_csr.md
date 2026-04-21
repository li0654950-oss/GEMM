# M1 - CSR 模块规格

## 1. Features
- 提供任务配置寄存器
- 提供状态与错误码寄存器
- 提供中断使能与完成中断

## 2. Interface
- 输入：`csr_wr_en`, `csr_wr_addr`, `csr_wr_data`, `csr_rd_en`, `csr_rd_addr`
- 输出：`csr_rd_data`, `start_pulse`, `cfg_bus`, `irq`
- 反馈输入：`busy`, `done`, `err_code`

## 3. Block Diagram
```text
CSR Bus -> Addr Decode -> Reg File -> Control/Status Pack -> Outputs
```

## 4. Architecture Diagram
```text
Host SW <-> CSR Register Bank <-> Scheduler/DMA/Compute
                  ^
               STATUS/ERR
```

## 5. Function
- 写 `CTRL.start=1` 触发 `start_pulse`
- `busy` 期间限制关键配置寄存器修改
- `done` 采用 W1C 清除策略
- 异常码锁存到 `STATUS.err_code`
