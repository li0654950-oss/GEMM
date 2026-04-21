# S2 - 微架构规格（Microarchitecture Spec）

## 1. Tile 策略
- 输出按 `Tm x Tn` 分块
- K 维按 `Tk` 分块累加
- 边界 tile 允许不足整块，使用 mask/strobe 处理

## 2. Buffer 规划
- `A_BUF[2]` / `B_BUF[2]` 双缓冲
- `C_BUF` 可选缓存
- `ACC_BUF` 保存部分和

## 3. 计算流水
- 阶段：Load A/B -> MAC -> Add C -> Store D
- 要求支持 `load(next)` 与 `compute(curr)` 并行
- backpressure 下保证数据一致性

## 4. 精度模式
- Mode0：FP16 乘 + FP16 累加
- Mode1：FP16 乘 + FP32 累加 + FP16 输出

## 5. 可配置参数
- `PE_M`, `PE_N`
- `TILE_M`, `TILE_N`, `TILE_K`
- `AXI_DATA_WIDTH`
- `USE_FP32_ACC`
