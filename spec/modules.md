# GEMM 模块划分与实现清单（脉动阵列方案）

## 1) 顶层与系统控制模块

1. **`gemm_top`（顶层封装）** ✅ Implemented
   - 连接 AXI4-Lite 控制面、AXI4 数据面、IRQ
   - 实例化并连接全部子模块
   - 统一时钟/复位、参数透传

2. **`csr_if`（寄存器接口）** ✅ Implemented
   - CSR 读写、`start` 脉冲、`done` 清零（W1C）
   - 配置寄存器：`DIM_* / ADDR_* / STRIDE_* / TILE_*`
   - 状态寄存器：`busy/done/err_code`
   - 性能计数器窗口

3. **`irq_ctrl`（中断控制，并入 csr_if）** ✅ Implemented (inside csr_if)
   - `done_irq` / `err_irq` 生成
   - `irq_en` 屏蔽与中断状态锁存

4. **`tile_scheduler`（主调度器）** ✅ Implemented
   - 三重循环 `(m0,n0,k0)` 管理
   - 状态机：`IDLE/LOAD/COMPUTE/STORE/NEXT/DONE`
   - 边界 tile mask 生成
   - 发起 DMA、切换 ping-pong buffer

## 2) DMA 与 AXI 访问模块

5. **`dma_rd`（读 DMA 顶层）** ✅ Implemented
   - A/B/C 读请求调度
   - 与 `tile_scheduler` 握手
   - backpressure 处理

6. **`rd_addr_gen`（读地址发生器）** ✅ Implemented
   - 按 `(m0,n0,k0)` + stride 计算 AXI 地址
   - 支持边界长度裁剪、burst 拆分

7. **`axi_rd_master`（AXI4 读通道）** ✅ Implemented
   - AR/R 通道协议
   - 突发读、beat 拼包、错误响应上报

8. **`dma_wr`（写 DMA 顶层）** ✅ Implemented
   - D tile 写回请求管理
   - 与后处理模块、scheduler 握手

9. **`wr_addr_gen`（写地址发生器）** ✅ Implemented
   - D tile 基址 + stride 映射
   - 边界写长度控制

10. **`axi_wr_master`（AXI4 写通道）** ✅ Implemented
    - AW/W/B 通道协议
    - burst 写、最后拍标记、响应检查

## 3) 片上缓存与数据重排模块

11. **`buffer_bank`（统一 buffer 管理）** ✅ Implemented
    - `A_BUF[2] / B_BUF[2] / C_BUF / (ACC_BUF)`
    - bank 冲突仲裁、读写端口分配
    - ping-pong 读写角色切换

12. **`a_loader`（A 数据装载/重排）** ✅ Implemented
    - DMA 读数据写入 A buffer
    - 按阵列喂数顺序做布局转换

13. **`b_loader`（B 数据装载/重排）** ✅ Implemented
    - DMA 读数据写入 B buffer
    - 按列方向输入顺序重排

14. **`c_loader`（C 数据装载，可选）** ✅ Implemented
    - 读取 C tile，供 postprocess 融合

15. **`d_storer`（D 数据收集）** ✅ Implemented
    - 从 postprocess 收集输出 tile
    - 组织为连续写回格式

## 4) 计算核心模块（脉动阵列）

16. **`systolic_core`（阵列顶层）** ✅ Implemented
    - `P_M x P_N` PE 阵列实例化
    - 输入注入时序控制（A 左入、B 上入）
    - fill/drain 周期控制

17. **`pe_cell`（基础 PE 单元）** ✅ Implemented
    - `acc += a*b`
    - A/B 转发寄存
    - 支持 FP16 mul + FP16/FP32 acc 模式

18. **`acc_ctrl`（累加控制）** ✅ Implemented
    - `k0` 段清零/保持/累加
    - tile 结束有效标志输出

19. **`array_io_adapter`（阵列输入输出适配）** ✅ Implemented
    - buffer 数据到阵列输入向量映射
    - 阵列输出到后处理接口对齐

## 5) 后处理与数值模块

20. **`postproc`（后处理顶层）** ✅ Implemented
    - `acc + C` 融合
    - 数据格式转换（FP32->FP16）
    - 输出有效与 tile 完成标志

21. **`fp_add_c`（与 C 融合单元）** ✅ Implemented
    - 可旁路（不使用 C 时）
    - 支持边界 mask

22. **`fp_round_sat`（舍入/饱和）** ✅ Implemented
    - round-to-nearest-even（建议）
    - 溢出/NaN/Inf 处理策略统一

## 6) 可靠性、监控与验证辅助模块

23. **`err_checker`（错误检查）** ✅ Implemented
    - 地址对齐、越界、维度合法性检查
    - AXI 响应错误汇总到 `err_code`

24. **`perf_counter`（性能计数器）** ✅ Implemented
    - `cycle_total / cycle_compute / cycle_dma_wait`
    - `axi_rd_bytes / axi_wr_bytes`

25. **`trace_debug_if`（可选调试导出）** ✅ Implemented
    - 导出状态机状态、tile 索引、stall 原因
    - 便于波形定位与性能分析

## 7) 实现批次（里程碑）— 全部完成

- **M1（可运行）**：`gemm_top + csr_if + tile_scheduler + dma_rd/wr + buffer_bank + systolic_core + postproc` ✅
- **M2（功能完整）**：补齐 `err_checker + perf_counter + 边界 tile + C 融合` ✅
- **M3（性能优化）**：`ping-pong + bank 优化 + burst 优化 + 数据重排优化` ✅
- **M4（工程化）**：中断完善、调试接口、回归与覆盖率收敛 — 文档阶段

## 8) 验证状态

| 模块 | 测试数 | 通过 | 仿真器 |
|------|--------|------|--------|
| pe_cell | 5 | 5 | Verilator |
| systolic_core | 31 | 31 | Verilator |
| buffer_bank | 12 | 12 | Verilator |
| a_loader | 6 | 6 | Verilator |
| b_loader | 6 | 6 | Verilator |
| d_storer | 4 | 4 | Verilator |
| postproc | 12 | 12 | Verilator |
| csr_if | 1 | 1 | Verilator |
| tile_scheduler | 3 | 3 | Verilator |
| rd_addr_gen | 1 | 1 | Verilator |
| err_checker | 4 | 4 | Verilator |
| **合计** | **85** | **85** | Verilator 5.020 |
