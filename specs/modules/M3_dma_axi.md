# M3 - DMA/AXI 模块规格

## 1. Features
- 支持 A/B/C 读搬运与 D 写回
- 支持 stride 与边界 tile
- 支持 burst 访问与响应错误上报

## 2. Interface
- 输入：`req_valid`, `base_addr`, `stride`, `shape`, `tile_index`
- 输出：`req_ready`, `done`, `err`, `buf_wr_data/buf_wr_en`（读路径）
- AXI：`AR* / R* / AW* / W* / B*`

## 3. Block Diagram
```text
Request Queue -> Address Generator -> AXI Engine -> Response Checker
                                 \-> Buffer Bridge
```

## 4. Architecture Diagram
```text
Scheduler Req -> DMA_RD/WR -> AXI Interconnect -> DDR/HBM
                         \-> Error Monitor -> STATUS
```

## 5. Function
- 按 tile 与 stride 生成行地址
- 优先生成长 burst，减少碎片访问
- `resp!=OKAY` 则置 `err` 并上报
- 支持边界 tile 字节 strobe 写回
