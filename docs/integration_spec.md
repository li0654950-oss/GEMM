# Integration Specification

**Version**: v0.1
**Date**: 2026-05-04
**Project**: FP16 Systolic Array GEMM

---

## 1. 顶层连接检查清单

### 1.1 必连信号

| 源模块 | 信号 | 宿模块 | 位宽 |
|--------|------|--------|------|
| csr_if | cfg_* | tile_scheduler | 多 |
| csr_if | cfg_start | tile_scheduler | 1 |
| tile_scheduler | rd_req_* | dma_rd | 多 |
| tile_scheduler | wr_req_* | dma_wr | 多 |
| tile_scheduler | core_start | systolic_core | 1 |
| tile_scheduler | pp_start | postproc | 1 |
| dma_rd | axi_* | axi_rd_master | AXI4 |
| dma_wr | axi_* | axi_wr_master | AXI4 |
| axi_rd_master | m_axi_* | 外部 DDR/HBM | AXI4 |
| axi_wr_master | m_axi_* | 外部 DDR/HBM | AXI4 |
| a_loader | buf_wr_* | buffer_bank | 多 |
| b_loader | buf_wr_* | buffer_bank | 多 |
| buffer_bank | buf_rd_* | array_io_adapter | 多 |
| array_io_adapter | a_vec_* / b_vec_* | systolic_core | 多 |
| systolic_core | acc_out_* | postproc | 多 |
| postproc | d_* | d_storer | 多 |
| d_storer | dma_wr_* | dma_wr | 多 |
| err_checker | err_* | csr_if | 多 |
| perf_counter | perf_* | csr_if | 64 |

### 1.2 悬空检查

- 所有输出端口必须连接或显式 tie-off
- 未用输入端口必须接地或接默认值
- `gemm_top` 内部无组合逻辑环路

## 2. 总线协议合规

- AXI4-Lite: 32-bit 数据，16-bit 地址
- AXI4: 256-bit 数据，64-bit 地址，ID 宽度 4-bit
- Burst 类型: INCR only
- Burst 长度: 1~16 beats (ARLEN/AWLEN = 0~15)

## 3. 参数一致性

| 参数 | 默认值 | 一致模块 |
|------|--------|----------|
| P_M | 4 | gemm_top, systolic_core, tile_scheduler |
| P_N | 4 | gemm_top, systolic_core, tile_scheduler |
| AXI_DATA_W | 256 | gemm_top, axi_rd_master, axi_wr_master |
| ADDR_W | 64 | gemm_top, csr_if, tile_scheduler, dma_rd, dma_wr |
| BUF_BANKS | 8 | gemm_top, buffer_bank |
| BUF_DEPTH | 2048 | gemm_top, buffer_bank |
