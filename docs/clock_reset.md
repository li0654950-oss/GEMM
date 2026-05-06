# Clock & Reset Specification

**Version**: v0.1
**Date**: 2026-05-04
**Project**: FP16 Systolic Array GEMM

---

## 1. 时钟域定义

| 时钟名 | 频率 | 用途 | 建议来源 |
|--------|------|------|----------|
| `clk` | 1 GHz（目标） | 阵列、buffer、scheduler、CSR | PLL |
| `clk_axi` | 500 MHz / 同源 | AXI4 Master/Slave 接口 | SoC 互联或 clk 分频 |

**MVP 阶段**: `clk` 与 `clk_axi` 同源同频，避免 CDC 复杂度。

## 2. 复位策略

- `rst_n`: 异步低有效复位
- 策略: **异步断言，同步释放**
- 所有时序逻辑: `always_ff @(posedge clk or negedge rst_n)`
- 复位释放后等待 2~3 拍再允许 `start`

## 3. CDC 方案

若未来 `clk_axi` 与 `clk` 不同频:
- 控制信号: 两级触发器同步
- 请求/响应: valid-ready 握手 + 异步 FIFO
- CSR 配置: AXI4-Lite 写完成后自动同步到 `clk` 域

## 4. 时钟门控

- `tile_scheduler` 在 `busy=0` 时可门控部分计数器时钟
- `perf_counter` 支持 freeze（`DEBUG_CTRL.bit1`）
- 空闲阶段关闭可选 debug 路径

## 5. 复位域交叉 (RDC)

- 跨复位域信号要求 reset-safe
- `done`/`irq` 采用源域锁存 + 目标域同步
