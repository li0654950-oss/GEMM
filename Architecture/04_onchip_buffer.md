# 04 - 片上缓存（On-chip Buffer）

## 1. 模块职责
- 承接 DMA 与计算核心速率差
- 为 PE 阵列提供高带宽本地数据
- 支持双缓冲与 bank 并行访问

## 2. Buffer 组织
- `A_BUF[2]`：Ping/Pong
- `B_BUF[2]`：Ping/Pong
- `C_BUF[2]`：可选
- `ACC_BUF`：部分和

## 3. 容量估算（示意）
- `A_BUF_size = Tm * Tk * 2B`
- `B_BUF_size = Tk * Tn * 2B`
- `C_BUF_size = Tm * Tn * 2B`
- `ACC_BUF_size = Tm * Tn * acc_width`

## 4. Bank 化建议
- 按 PE 并行读端口数配置 bank 数
- 地址低位做 bank 交织
- 减少多 PE 同时访问冲突

## 5. 数据一致性
- 每次 tile 切换前完成 buffer 角色切换
- 未完成写回前禁止覆盖对应输出缓存
