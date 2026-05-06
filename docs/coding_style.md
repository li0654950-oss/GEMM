# GEMM RTL Coding Style Guide

**Version**: v1.0
**Date**: 2026-05-04
**Project**: FP16 Systolic Array GEMM

---

## 1. 命名规范

| 对象 | 风格 | 示例 |
|------|------|------|
| 模块名 | `snake_case` | `systolic_core`, `axi_rd_master` |
| 信号名 | `snake_case` | `core_start`, `acc_out_valid` |
| 输入前缀 | `i_` 或直接 | `i_a_vec_data` / `a_vec_data` |
| 输出前缀 | `o_` 或直接 | `o_core_done` / `core_done` |
| 参数 | `UPPER_CASE` | `P_M`, `AXI_DATA_W` |
| localparam | `UPPER_CASE` | `FILL_DRAIN_CYCLES`, `ACC_W` |
| 时钟/复位 | `clk`, `rst_n`（低有效） | |
| valid/ready | `_valid`, `_ready` | `wr_valid`, `wr_ready` |
| last | `_last` | `rd_data_last`, `d_last` |
| 状态机类型 | `*_state_t` | `core_state_t`, `sched_state_t` |

## 2. 可综合子集

- **禁止** `always_comb` 中的 latch（确保所有分支赋值）
- **禁止** `initial` 块（仅限 testbench）
- **禁止** 时序逻辑中的阻塞赋值（`=`）
- **禁止** `real` / `shortreal` 类型（仿真专用 `fp16_mac_soft` 除外）
- **禁止** 递归函数、动态数组、队列
- **推荐** `always_ff @(posedge clk or negedge rst_n)` 用于时序逻辑
- **推荐** `always_comb` 用于组合逻辑
- **推荐** `typedef enum logic [N:0]` 定义状态机

## 3. 参数化规范

- `parameter`：模块级可配置参数，必须有默认值
- `localparam`：模块内派生常量，不可外部覆盖
- 全局参数统一放入 `gemm_pkg.sv`，通过 `import gemm_pkg::*` 引用

## 4. 注释规范

```systemverilog
//------------------------------------------------------------------------------
// module_name.sv
// 模块一句话描述
//
// Description:
//   多行详细描述...
//------------------------------------------------------------------------------
```

## 5. FPGA/ASIC 双目标

- ASIC 可用 `always_latch`（显式），FPGA 受限
- ASIC 可用门控时钟（`ICG`），FPGA 建议始终使能
- `fp16_mac_soft` 仅用于仿真，综合前替换为 hardened IP

## 6. Verilator 兼容性

- **禁用** `while (!signal) @(posedge clk)` 模式（initial 块内会导致死锁）
- 改用 always 块 FSM + 计数器 timeout
- 保持 AXI 握手信号在握手完成前稳定
- 使用 `--timing` 标志编译 Verilator 5.x

## 7. 文件头模板

```systemverilog
`ifndef MODULE_NAME_SV
`define MODULE_NAME_SV

module module_name #(
    parameter int PARAM_A = 4,
    parameter int PARAM_B = 16
)(
    input  wire        clk,
    input  wire        rst_n,
    // 端口定义...
);

    // localparam
    // 信号声明
    // 逻辑实现

endmodule : module_name
`endif // MODULE_NAME_SV
```
