# S5 - 性能与功耗规格（Performance/Power Spec）

## 1. 性能指标
- 理论峰值：
  - `TOPS = 2 * PE_M * PE_N * Freq`
- 实测指标：
  - 吞吐（GFLOPS/TOPS）
  - 时延（cycle / task）
  - PE 利用率（%）

## 2. 带宽指标
- AXI 有效带宽（GB/s）
- 平均 burst 长度
- 读写通道利用率

## 3. 功耗指标
- 动态功耗 / 静态功耗
- 能效：TOPS/W
- 不同 tile 和频率点下功耗曲线

## 4. 评测方法
- 固定输入规模 + 随机输入规模
- 记录最优/均值/最差
- 输出对比表与趋势图（可选）

## 5. 优化闭环
- 瓶颈定位（算力受限 or 带宽受限）
- 逐项优化（tile/burst/pipeline）
- 重新测量并回填报告
