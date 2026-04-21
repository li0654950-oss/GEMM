# 03 - DMA 与 AXI 子系统

## 1. 模块职责
- 生成 AXI 读写请求
- 执行 A/B/C 读入与 D 写回
- 屏蔽外部内存访问细节给上层调度

## 2. AXI 读路径（A/B/C）
- 支持 INCR burst
- 可配置最大 burst 长度
- 自动按 stride 进行二维地址步进

地址生成：
- `addr_A(i,k) = base_A + i*stride_A + k*sizeof(fp16)`
- `addr_B(k,j) = base_B + k*stride_B + j*sizeof(fp16)`
- `addr_C(i,j) = base_C + i*stride_C + j*sizeof(fp16)`

## 3. AXI 写路径（D）
- 支持按行 burst 写回
- 边界 tile 支持部分有效字节写（byte strobe）

地址生成：
- `addr_D(i,j) = base_D + i*stride_D + j*sizeof(fp16)`

## 4. 带宽优化建议
- 尽量对齐到 AXI 数据位宽边界
- 合并小传输为长 burst
- 避免跨 4KB 边界（按平台规范）

## 5. 错误与超时
- `resp!=OKAY` 计入 DMA 错误
- 可选总线超时计数器
- 异常后上报 `err_code` 并进入 `ERROR`
