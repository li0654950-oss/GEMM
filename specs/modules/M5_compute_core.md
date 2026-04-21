# M5 - Compute Core 模块规格

## 1. Features
- 参数化 PE 阵列 (`PE_M x PE_N`)
- 支持 FP16 乘加
- 支持 FP32 累加可选模式

## 2. Interface
- 输入：`a_vec`, `b_vec`, `c_vec`, `valid_in`
- 输出：`d_vec`, `valid_out`
- 控制：`mode_fp32_acc`, `tile_cfg`, `clear_acc`

## 3. Block Diagram
```text
A/B Loader -> PE Array(MAC) -> Accumulator -> Add C -> Output Pack
```

## 4. Architecture Diagram
```text
a,b -> mul -> adder tree -> acc_reg -> +c -> cast(fp16) -> d
```

## 5. Function
- 对 `Tk` 维循环执行累加
- 完成后融合 C 并输出 D
- 通过 `valid/ready` 处理上游回压
- 支持流水级数可配置以满足时序
