//------------------------------------------------------------------------------
// gemm_top.sv
// GEMM Accelerator Top Level
//
// Description:
//   Instantiates all sub-modules per spec/modules.md integration order.
//   Connects AXI4-Lite CSR, AXI4 Master, IRQ, and all internal datapath.
//------------------------------------------------------------------------------
`ifndef GEMM_TOP_SV
`define GEMM_TOP_SV

module gemm_top #(
    parameter int P_M          = 4,
    parameter int P_N          = 4,
    parameter int ELEM_W       = 16,
    parameter int ACC_W        = 32,
    parameter int ADDR_W       = 64,
    parameter int AXIL_ADDR_W    = 16,
    parameter int AXI_DATA_W     = 256,
    parameter int AXI_ID_W       = 4,
    parameter int DIM_W          = 16,
    parameter int STRIDE_W       = 32,
    parameter int TILE_W         = 16,
    parameter int MAX_BURST_LEN   = 16,
    parameter int OUTSTANDING_RD  = 8,
    parameter int OUTSTANDING_WR  = 8,
    parameter int BUF_BANKS      = 8,
    parameter int BUF_DEPTH      = 2048,
    parameter int PERF_CNT_W     = 64,
    parameter int ERR_CODE_W     = 16
)(
    input  wire              clk,
    input  wire              rst_n,

    // AXI4-Lite Slave (CSR) -------------------------------------------------
    input  wire [AXIL_ADDR_W-1:0] s_axil_awaddr,
    input  wire              s_axil_awvalid,
    output wire              s_axil_awready,
    input  wire [31:0]       s_axil_wdata,
    input  wire [3:0]        s_axil_wstrb,
    input  wire              s_axil_wvalid,
    output wire              s_axil_wready,
    output wire [1:0]        s_axil_bresp,
    output wire              s_axil_bvalid,
    input  wire              s_axil_bready,
    input  wire [AXIL_ADDR_W-1:0] s_axil_araddr,
    input  wire              s_axil_arvalid,
    output wire              s_axil_arready,
    output wire [31:0]       s_axil_rdata,
    output wire [1:0]        s_axil_rresp,
    output wire              s_axil_rvalid,
    input  wire              s_axil_rready,

    // AXI4 Master Read ------------------------------------------------------
    output wire [AXI_ID_W-1:0] m_axi_arid,
    output wire [ADDR_W-1:0] m_axi_araddr,
    output wire [7:0]        m_axi_arlen,
    output wire [2:0]        m_axi_arsize,
    output wire [1:0]        m_axi_arburst,
    output wire              m_axi_arvalid,
    input  wire              m_axi_arready,
    input  wire [AXI_ID_W-1:0] m_axi_rid,
    input  wire [AXI_DATA_W-1:0] m_axi_rdata,
    input  wire [1:0]        m_axi_rresp,
    input  wire              m_axi_rlast,
    input  wire              m_axi_rvalid,
    output wire              m_axi_rready,

    // AXI4 Master Write -----------------------------------------------------
    output wire [AXI_ID_W-1:0] m_axi_awid,
    output wire [ADDR_W-1:0] m_axi_awaddr,
    output wire [7:0]        m_axi_awlen,
    output wire [2:0]        m_axi_awsize,
    output wire [1:0]        m_axi_awburst,
    output wire              m_axi_awvalid,
    input  wire              m_axi_awready,
    output wire [AXI_DATA_W-1:0] m_axi_wdata,
    output wire [AXI_DATA_W/8-1:0] m_axi_wstrb,
    output wire              m_axi_wlast,
    output wire              m_axi_wvalid,
    input  wire              m_axi_wready,
    input  wire [AXI_ID_W-1:0] m_axi_bid,
    input  wire [1:0]        m_axi_bresp,
    input  wire              m_axi_bvalid,
    output wire              m_axi_bready,

    // Interrupt -------------------------------------------------------------
    output wire              irq_o
);

    import gemm_pkg::*;

    // AXI cache/prot constants (internal wires to avoid PORTSHORT)
    wire [3:0] m_axi_arcache;
    wire [2:0] m_axi_arprot;
    wire [3:0] m_axi_awcache;
    wire [2:0] m_axi_awprot;
    assign m_axi_arcache = 4'b0011;
    assign m_axi_arprot  = 3'b000;
    assign m_axi_awcache = 4'b0011;
    assign m_axi_awprot  = 3'b000;

    //------------------------------------------------------------------------
    // Internal wires
    //------------------------------------------------------------------------
    wire [DIM_W-1:0]  cfg_m, cfg_n, cfg_k;
    wire [TILE_W-1:0] cfg_tile_m, cfg_tile_n, cfg_tile_k;
    wire [ADDR_W-1:0] cfg_addr_a, cfg_addr_b, cfg_addr_c, cfg_addr_d;
    wire [STRIDE_W-1:0] cfg_stride_a, cfg_stride_b, cfg_stride_c, cfg_stride_d;
    wire              cfg_add_c_en;
    wire [1:0]        cfg_round_mode;
    wire              cfg_sat_en;
    wire              cfg_start;
    wire              cfg_soft_reset;
    wire              irq_en;

    wire              sch_busy, sch_done, sch_err;
    wire [ERR_CODE_W-1:0] sch_err_code;
    wire [TILE_W-1:0] sch_tile_m_idx, sch_tile_n_idx, sch_tile_k_idx;
    wire [LANES-1:0]  tile_mask;

    wire              rd_req_valid, rd_req_ready;
    wire [1:0]        rd_req_type;
    wire [ADDR_W-1:0] rd_req_base_addr;
    wire [TILE_W-1:0] rd_req_rows, rd_req_cols;
    wire [STRIDE_W-1:0] rd_req_stride;
    wire              rd_req_last;
    wire              rd_done, rd_err;

    wire              wr_req_valid, wr_req_ready;
    wire [ADDR_W-1:0] wr_req_base_addr;
    wire [TILE_W-1:0] wr_req_rows, wr_req_cols;
    wire [STRIDE_W-1:0] wr_req_stride;
    wire              wr_req_last;
    wire              wr_done, wr_err;

    wire              core_start, core_done, core_busy, core_err;
    wire              pp_start, pp_done, pp_busy;
    wire              pp_switch_req, pp_switch_ack;

    wire [PERF_CNT_W-1:0] perf_cycle_total, perf_cycle_compute, perf_cycle_dma_wait;
    wire [PERF_CNT_W-1:0] perf_axi_rd_bytes, perf_axi_wr_bytes;

    // CSR Interface
    csr_if #(
        .AXIL_ADDR_W(AXIL_ADDR_W),
        .DIM_W(DIM_W), .ADDR_W(ADDR_W), .STRIDE_W(STRIDE_W),
        .TILE_W(TILE_W), .PERF_CNT_W(PERF_CNT_W), .ERR_CODE_W(ERR_CODE_W)
    ) u_csr (
        .clk(clk), .rst_n(rst_n),
        .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb), .s_axil_wvalid(s_axil_wvalid), .s_axil_wready(s_axil_wready),
        .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid), .s_axil_bready(s_axil_bready),
        .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready),
        .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp), .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),
        .cfg_m(cfg_m), .cfg_n(cfg_n), .cfg_k(cfg_k),
        .cfg_tile_m(cfg_tile_m), .cfg_tile_n(cfg_tile_n), .cfg_tile_k(cfg_tile_k),
        .cfg_addr_a(cfg_addr_a), .cfg_addr_b(cfg_addr_b), .cfg_addr_c(cfg_addr_c), .cfg_addr_d(cfg_addr_d),
        .cfg_stride_a(cfg_stride_a), .cfg_stride_b(cfg_stride_b), .cfg_stride_c(cfg_stride_c), .cfg_stride_d(cfg_stride_d),
        .cfg_add_c_en(cfg_add_c_en), .cfg_round_mode(cfg_round_mode), .cfg_sat_en(cfg_sat_en),
        .cfg_start(cfg_start), .cfg_soft_reset(cfg_soft_reset), .irq_en(irq_en),
        .sch_busy(sch_busy), .sch_done(sch_done), .sch_err(sch_err), .sch_err_code(sch_err_code),
        .sch_tile_m_idx(sch_tile_m_idx), .sch_tile_n_idx(sch_tile_n_idx), .sch_tile_k_idx(sch_tile_k_idx),
        .perf_cycle_total(perf_cycle_total), .perf_cycle_compute(perf_cycle_compute),
        .perf_cycle_dma_wait(perf_cycle_dma_wait),
        .perf_axi_rd_bytes(perf_axi_rd_bytes), .perf_axi_wr_bytes(perf_axi_wr_bytes),
        .irq_o(irq_o)
    );

    // Tile Scheduler
    tile_scheduler #(
        .P_M(P_M), .P_N(P_N), .DIM_W(DIM_W), .ADDR_W(ADDR_W),
        .STRIDE_W(STRIDE_W), .TILE_W(TILE_W), .ELEM_W(ELEM_W), .ERR_CODE_W(ERR_CODE_W)
    ) u_scheduler (
        .clk(clk), .rst_n(rst_n),
        .cfg_m(cfg_m), .cfg_n(cfg_n), .cfg_k(cfg_k),
        .cfg_tile_m(cfg_tile_m), .cfg_tile_n(cfg_tile_n), .cfg_tile_k(cfg_tile_k),
        .cfg_addr_a(cfg_addr_a), .cfg_addr_b(cfg_addr_b), .cfg_addr_c(cfg_addr_c), .cfg_addr_d(cfg_addr_d),
        .cfg_stride_a(cfg_stride_a), .cfg_stride_b(cfg_stride_b), .cfg_stride_c(cfg_stride_c), .cfg_stride_d(cfg_stride_d),
        .cfg_add_c_en(cfg_add_c_en), .cfg_start(cfg_start),
        .sch_busy(sch_busy), .sch_done(sch_done), .sch_err(sch_err), .sch_err_code(sch_err_code),
        .sch_tile_m_idx(sch_tile_m_idx), .sch_tile_n_idx(sch_tile_n_idx), .sch_tile_k_idx(sch_tile_k_idx),
        .tile_mask(tile_mask),
        .rd_req_valid(rd_req_valid), .rd_req_ready(rd_req_ready), .rd_req_type(rd_req_type),
        .rd_req_base_addr(rd_req_base_addr), .rd_req_rows(rd_req_rows), .rd_req_cols(rd_req_cols),
        .rd_req_stride(rd_req_stride), .rd_req_last(rd_req_last),
        .rd_done(rd_done), .rd_err(rd_err),
        .wr_req_valid(wr_req_valid), .wr_req_ready(wr_req_ready),
        .wr_req_base_addr(wr_req_base_addr), .wr_req_rows(wr_req_rows), .wr_req_cols(wr_req_cols),
        .wr_req_stride(wr_req_stride), .wr_req_last(wr_req_last),
        .wr_done(wr_done), .wr_err(wr_err),
        .core_start(core_start), .core_done(core_done), .core_busy(core_busy), .core_err(core_err),
        .pp_start(pp_start), .pp_done(pp_done), .pp_busy(pp_busy),
        .pp_switch_req(pp_switch_req), .pp_switch_ack(1'b1),
        .cnt_start(cnt_start), .cnt_stop(cnt_stop),
        .act_rows_o(act_rows), .act_cols_o(act_cols), .act_k_o(act_k)
    );

    //------------------------------------------------------------------------
    // Internal: buffer access arbitration + DMA demux wires
    //------------------------------------------------------------------------
    localparam int NUM_STALL_REASONS = 8;
    localparam int BUF_BANK_W = $clog2(BUF_BANKS);
    localparam int BUF_DEPTH_W = $clog2(BUF_DEPTH);

    // Buffer write mux inputs
    wire       a_loader_buf_wr_valid;
    wire [2:0] a_loader_buf_wr_sel;
    wire [BUF_BANK_W-1:0] a_loader_buf_wr_bank;
    wire [BUF_DEPTH_W-1:0] a_loader_buf_wr_addr;
    wire [AXI_DATA_W-1:0] a_loader_buf_wr_data;
    wire [AXI_DATA_W/8-1:0] a_loader_buf_wr_mask;
    wire       a_loader_buf_wr_ready;

    wire       b_loader_buf_wr_valid;
    wire [2:0] b_loader_buf_wr_sel;
    wire [BUF_BANK_W-1:0] b_loader_buf_wr_bank;
    wire [BUF_DEPTH_W-1:0] b_loader_buf_wr_addr;
    wire [AXI_DATA_W-1:0] b_loader_buf_wr_data;
    wire [AXI_DATA_W/8-1:0] b_loader_buf_wr_mask;
    wire       b_loader_buf_wr_ready;

    wire       c_loader_buf_wr_valid;
    wire [BUF_BANK_W-1:0] c_loader_buf_wr_bank;
    wire [BUF_DEPTH_W-1:0] c_loader_buf_wr_addr;
    wire [AXI_DATA_W-1:0] c_loader_buf_wr_data;
    wire [AXI_DATA_W/8-1:0] c_loader_buf_wr_mask;
    wire       c_loader_buf_wr_ready;

    wire       d_storer_buf_wr_valid;
    wire [2:0] d_storer_buf_wr_sel;
    wire [BUF_BANK_W-1:0] d_storer_buf_wr_bank;
    wire [BUF_DEPTH_W-1:0] d_storer_buf_wr_addr;
    wire [AXI_DATA_W-1:0] d_storer_buf_wr_data;
    wire [AXI_DATA_W/8-1:0] d_storer_buf_wr_mask;
    wire       d_storer_buf_wr_ready;

    // Buffer read mux
    wire       array_io_adapter_rd_req_valid;
    wire [2:0] array_io_adapter_rd_sel;
    wire [BUF_BANK_W-1:0] array_io_adapter_rd_bank;
    wire [BUF_DEPTH_W-1:0] array_io_adapter_rd_addr;
    wire       array_io_adapter_rd_req_ready;
    wire [AXI_DATA_W-1:0] array_io_adapter_rd_data;
    wire       array_io_adapter_rd_data_valid;

    // Tie buffer read to always-on for MVP
    assign array_io_adapter_rd_req_valid = 1'b1;
    assign array_io_adapter_rd_sel       = 3'd0;
    assign array_io_adapter_rd_bank      = '0;
    assign array_io_adapter_rd_addr      = '0;

    // DMA read data distribution
    wire       rd_data_ready;
    wire [AXI_DATA_W-1:0] rd_data_payload;
    wire       rd_data_valid;
    wire       rd_data_last;
    wire [1:0] rd_data_type;
    wire       a_loader_dma_ready, b_loader_dma_ready, c_loader_dma_ready;

    // d_storer → dma_wr
    wire       wr_data_valid_s2d;
    wire       wr_data_ready_s2d;
    wire [AXI_DATA_W-1:0] wr_data_payload_s2d;
    wire       wr_data_last_s2d;

    // Core ↔ array_io_adapter
    wire [P_M*ELEM_W-1:0] buf_a_data;
    wire [P_N*ELEM_W-1:0] buf_b_data;
    assign buf_a_data = array_io_adapter_rd_data[P_M*ELEM_W-1:0];
    assign buf_b_data = array_io_adapter_rd_data[P_N*ELEM_W*2-1 : P_M*ELEM_W];
    wire       issue_valid;
    wire       issue_ready;

    // Core ↔ postproc
    wire       acc_out_valid;
    wire [LANES*ACC_W-1:0] acc_out_data;
    wire       acc_out_last;

    // Postproc status
    wire       pp_err;
    wire [LANES*ELEM_W-1:0] postproc_d_data;
    wire       postproc_d_last;
    wire [LANES-1:0] postproc_d_mask;

    // Performance counter control
    wire [NUM_STALL_REASONS-1:0] stall_reason_vec;
    wire       cnt_start, cnt_stop, cnt_clear, cnt_freeze, snap_req;

    // Trace debug
    wire [7:0] fsm_state_for_trace;
    wire [7:0] stall_code_for_trace;
    wire [63:0] timestamp_cnt;

    // Buffer read mux returns
    wire       buf_rd_req_ready_mux;
    wire [AXI_DATA_W-1:0] buf_rd_data_mux;
    wire       buf_rd_data_valid_mux;

    // Core debug / perf tie-off wires
    wire [2:0] core_debug_cfg;
    wire [31:0] core_perf_active, core_perf_fill, core_perf_drain, core_perf_stall;
    wire [2:0] core_err_code;

    // DMA demux data wires
    wire [AXI_DATA_W-1:0] a_dma_data, b_dma_data, c_dma_data;

    // Tile scheduler active dimensions (for loaders)
    wire [TILE_W-1:0] act_rows, act_cols, act_k;

    // AXI Read Master <-> dma_rd bridge
    wire        axi_rd_cmd_valid;
    wire        axi_rd_cmd_ready;
    wire [ADDR_W-1:0] axi_rd_cmd_addr;
    wire [7:0]  axi_rd_cmd_len;
    wire [2:0]  axi_rd_cmd_size;
    wire        axi_rd_data_valid;
    wire        axi_rd_data_ready;
    wire [AXI_DATA_W-1:0] axi_rd_data_payload;
    wire        axi_rd_data_last;
    wire        axi_rd_resp_err;

    // AXI Write Master <-> dma_wr bridge
    wire        axi_wr_cmd_valid;
    wire        axi_wr_cmd_ready;
    wire [ADDR_W-1:0] axi_wr_cmd_addr;
    wire [7:0]  axi_wr_cmd_len;
    wire [2:0]  axi_wr_cmd_size;
    wire        axi_wr_data_valid;
    wire        axi_wr_data_ready;
    wire [AXI_DATA_W-1:0] axi_wr_data_payload;
    wire        axi_wr_data_last;
    wire [AXI_DATA_W/8-1:0] axi_wr_data_strb;
    wire        axi_wr_resp_err;

    // dma_wr data input from d_storer
    wire        dma_wr_data_valid;
    wire        dma_wr_data_ready;
    wire [AXI_DATA_W-1:0] dma_wr_data_payload;
    wire        dma_wr_data_last;

    // array_io_adapter <-> systolic_core skewed vectors
    wire        core_a_vec_valid;
    wire [P_M*ELEM_W-1:0] core_a_vec_data;
    wire [P_M-1:0] core_a_vec_mask;
    wire        core_b_vec_valid;
    wire [P_N*ELEM_W-1:0] core_b_vec_data;
    wire [P_N-1:0] core_b_vec_mask;

    // postproc <-> d_storer / dma_wr
    wire        pp_d_valid;
    wire        pp_d_ready;
    wire [LANES*ELEM_W-1:0] pp_d_data;
    wire        pp_d_last;
    wire [LANES-1:0] pp_d_mask;

    // dma_wr data input from postproc (MVP bypass)
    assign dma_wr_data_valid   = pp_d_valid;
    assign dma_wr_data_payload = pp_d_data;
    assign dma_wr_data_last    = pp_d_last;

    // postproc C input (from core acc_out, for add-c path)
    wire        pp_c_valid;
    wire        pp_c_ready;
    wire [LANES*ELEM_W-1:0] pp_c_data;
    wire        pp_c_last;

    //------------------------------------------------------------------------
    // Buffer write mux
    //------------------------------------------------------------------------
    reg        buf_wr_valid_mux;
    reg [2:0]  buf_wr_sel_mux;
    reg [BUF_BANK_W-1:0] buf_wr_bank_mux;
    reg [BUF_DEPTH_W-1:0] buf_wr_addr_mux;
    reg [AXI_DATA_W-1:0] buf_wr_data_mux;
    reg [AXI_DATA_W/8-1:0] buf_wr_mask_mux;
    wire       buf_wr_ready_mux;

    always_comb begin
        buf_wr_valid_mux = 1'b0;
        buf_wr_sel_mux   = 3'd0;
        buf_wr_bank_mux  = '0;
        buf_wr_addr_mux  = '0;
        buf_wr_data_mux  = '0;
        buf_wr_mask_mux  = '0;
        if (a_loader_buf_wr_valid) begin
            buf_wr_valid_mux = 1'b1;
            buf_wr_sel_mux   = a_loader_buf_wr_sel;
            buf_wr_bank_mux  = a_loader_buf_wr_bank;
            buf_wr_addr_mux  = a_loader_buf_wr_addr;
            buf_wr_data_mux  = a_loader_buf_wr_data;
            buf_wr_mask_mux  = a_loader_buf_wr_mask;
        end else if (b_loader_buf_wr_valid) begin
            buf_wr_valid_mux = 1'b1;
            buf_wr_sel_mux   = b_loader_buf_wr_sel;
            buf_wr_bank_mux  = b_loader_buf_wr_bank;
            buf_wr_addr_mux  = b_loader_buf_wr_addr;
            buf_wr_data_mux  = b_loader_buf_wr_data;
            buf_wr_mask_mux  = b_loader_buf_wr_mask;
        end else if (c_loader_buf_wr_valid) begin
            buf_wr_valid_mux = 1'b1;
            buf_wr_sel_mux   = 3'd4; // C_BUF
            buf_wr_bank_mux  = c_loader_buf_wr_bank;
            buf_wr_addr_mux  = c_loader_buf_wr_addr;
            buf_wr_data_mux  = c_loader_buf_wr_data;
            buf_wr_mask_mux  = c_loader_buf_wr_mask;
        end else if (d_storer_buf_wr_valid) begin
            buf_wr_valid_mux = 1'b1;
            buf_wr_sel_mux   = d_storer_buf_wr_sel;
            buf_wr_bank_mux  = d_storer_buf_wr_bank;
            buf_wr_addr_mux  = d_storer_buf_wr_addr;
            buf_wr_data_mux  = d_storer_buf_wr_data;
            buf_wr_mask_mux  = d_storer_buf_wr_mask;
        end
    end

    assign a_loader_buf_wr_ready = buf_wr_ready_mux;
    assign b_loader_buf_wr_ready = buf_wr_ready_mux;
    assign c_loader_buf_wr_ready = buf_wr_ready_mux;
    assign d_storer_buf_wr_ready = buf_wr_ready_mux;

    //------------------------------------------------------------------------
    // Buffer read: array_io_adapter only
    //------------------------------------------------------------------------
    assign array_io_adapter_rd_req_ready = buf_rd_req_ready_mux;
    assign array_io_adapter_rd_data      = buf_rd_data_mux;
    assign array_io_adapter_rd_data_valid= buf_rd_data_valid_mux;

    //------------------------------------------------------------------------
    // DMA read data demux to loaders
    //------------------------------------------------------------------------
    wire a_dma_valid = rd_data_valid && (rd_data_type == 2'b00);
    wire b_dma_valid = rd_data_valid && (rd_data_type == 2'b01);
    wire c_dma_valid = rd_data_valid && (rd_data_type == 2'b10);
    wire a_dma_last  = rd_data_last  && (rd_data_type == 2'b00);
    wire b_dma_last  = rd_data_last  && (rd_data_type == 2'b01);
    wire c_dma_last  = rd_data_last  && (rd_data_type == 2'b10);
    assign rd_data_ready = (a_dma_valid ? a_loader_dma_ready : 1'b0)
                         | (b_dma_valid ? b_loader_dma_ready : 1'b0)
                         | (c_dma_valid ? c_loader_dma_ready : 1'b0);

    //------------------------------------------------------------------------
    // Tie-offs for MVP
    //------------------------------------------------------------------------
    assign core_debug_cfg    = 3'b000;
    assign stall_reason_vec  = '0;
    assign cnt_clear         = cfg_soft_reset;
    assign cnt_freeze        = 1'b0;
    assign snap_req          = sch_done;
    assign fsm_state_for_trace = {sch_busy, sch_done, sch_err, 5'b0};
    assign stall_code_for_trace = '0;
    assign timestamp_cnt     = '0;

    // Unused sink
    wire _unused_ok = &{core_perf_active, core_perf_fill, core_perf_drain,
                        core_perf_stall, core_err_code};

    //======================================================================
    // Sub-module instantiations
    //======================================================================

    // Error Checker
    err_checker #(
        .ADDR_W(ADDR_W), .DIM_W(DIM_W), .STRIDE_W(STRIDE_W),
        .TILE_W(TILE_W), .ERR_CODE_W(ERR_CODE_W)
    ) u_err_checker (
        .clk(clk), .rst_n(rst_n),
        .chk_valid(cfg_start),
        .cfg_m(cfg_m), .cfg_n(cfg_n), .cfg_k(cfg_k),
        .cfg_tile_m(cfg_tile_m), .cfg_tile_n(cfg_tile_n), .cfg_tile_k(cfg_tile_k),
        .cfg_addr_a(cfg_addr_a), .cfg_addr_b(cfg_addr_b),
        .cfg_addr_c(cfg_addr_c), .cfg_addr_d(cfg_addr_d),
        .cfg_stride_a(cfg_stride_a), .cfg_stride_b(cfg_stride_b),
        .cfg_stride_c(cfg_stride_c), .cfg_stride_d(cfg_stride_d),
        .axi_rresp(m_axi_rresp),
        .axi_rresp_valid(m_axi_rvalid && m_axi_rready),
        .axi_bresp(m_axi_bresp),
        .axi_bresp_valid(m_axi_bvalid && m_axi_bready),
        .fsm_state({sch_busy, sch_done, sch_err, 5'b0}),
        .fsm_err(sch_err),
        .core_err(core_err),
        .pp_err(pp_err),
        .busy_in(sch_busy),
        .err_valid(),
        .err_code(sch_err_code),
        .err_addr(),
        .err_src(),
        .fatal_err(),
        .warn_err()
    );

    // Performance Counter
    perf_counter #(
        .PERF_CNT_W(PERF_CNT_W), .NUM_STALL_REASONS(NUM_STALL_REASONS),
        .AXI_DATA_W(AXI_DATA_W)
    ) u_perf_counter (
        .clk(clk), .rst_n(rst_n),
        .cnt_start(cnt_start), .cnt_stop(cnt_stop),
        .cnt_clear(cnt_clear), .cnt_freeze(cnt_freeze), .snap_req(snap_req),
        .core_busy(core_busy),
        .core_active(core_busy && !core_done),
        .dma_rd_wait(1'b0),
        .dma_wr_wait(1'b0),
        .axi_rd_beat(m_axi_rvalid && m_axi_rready),
        .axi_wr_beat(m_axi_wvalid && m_axi_wready),
        .stall_reason(stall_reason_vec),
        .cycle_total(perf_cycle_total),
        .cycle_compute(perf_cycle_compute),
        .cycle_dma_wait(perf_cycle_dma_wait),
        .axi_rd_bytes(perf_axi_rd_bytes),
        .axi_wr_bytes(perf_axi_wr_bytes),
        .stall_reason_cnt(),
        .snap_valid()
    );

    // Trace Debug Interface
    trace_debug_if #(
        .TRACE_W(128), .TRACE_FIFO_DEPTH(256), .TILE_W(TILE_W)
    ) u_trace_debug (
        .clk(clk), .rst_n(rst_n),
        .trace_en(1'b0),
        .trace_freeze(1'b0),
        .trace_clr(cfg_soft_reset),
        .fsm_state(fsm_state_for_trace),
        .tile_idx_m(sch_tile_m_idx),
        .tile_idx_n(sch_tile_n_idx),
        .tile_idx_k(sch_tile_k_idx),
        .stall_code(stall_code_for_trace),
        .timestamp(timestamp_cnt),
        .event_valid(sch_done || sch_err),
        .trace_valid(),
        .trace_ready(1'b0),
        .trace_data(),
        .trace_overflow(),
        .trace_level()
    );

    // AXI Read Master
    axi_rd_master #(
        .ADDR_W(ADDR_W), .AXI_DATA_W(AXI_DATA_W), .AXI_ID_W(AXI_ID_W),
        .MAX_BURST_LEN(MAX_BURST_LEN), .OUTSTANDING_RD(OUTSTANDING_RD)
    ) u_axi_rd_master (
        .clk(clk), .rst_n(rst_n),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot),
        .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
        .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
        .cmd_valid(axi_rd_cmd_valid),
        .cmd_ready(axi_rd_cmd_ready),
        .cmd_addr(axi_rd_cmd_addr),
        .cmd_len(axi_rd_cmd_len),
        .cmd_size(axi_rd_cmd_size),
        .data_valid(axi_rd_data_valid),
        .data_ready(axi_rd_data_ready),
        .data_payload(axi_rd_data_payload),
        .data_last(axi_rd_data_last),
        .resp_err(axi_rd_resp_err)
    );

    // AXI Write Master
    axi_wr_master #(
        .ADDR_W(ADDR_W), .AXI_DATA_W(AXI_DATA_W), .AXI_ID_W(AXI_ID_W),
        .MAX_BURST_LEN(MAX_BURST_LEN), .OUTSTANDING_WR(OUTSTANDING_WR)
    ) u_axi_wr_master (
        .clk(clk), .rst_n(rst_n),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awcache(m_axi_awcache), .m_axi_awprot(m_axi_awprot),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
        .cmd_valid(axi_wr_cmd_valid),
        .cmd_ready(axi_wr_cmd_ready),
        .cmd_addr(axi_wr_cmd_addr),
        .cmd_len(axi_wr_cmd_len),
        .cmd_size(axi_wr_cmd_size),
        .data_valid(axi_wr_data_valid),
        .data_ready(axi_wr_data_ready),
        .data_payload(axi_wr_data_payload),
        .data_last(axi_wr_data_last),
        .data_strb(axi_wr_data_strb),
        .resp_err(axi_wr_resp_err)
    );

    // DMA Read Controller
    dma_rd #(
        .ADDR_W(ADDR_W), .DIM_W(DIM_W), .STRIDE_W(STRIDE_W),
        .AXI_DATA_W(AXI_DATA_W), .MAX_BURST_LEN(MAX_BURST_LEN),
        .OUTSTANDING_RD(OUTSTANDING_RD)
    ) u_dma_rd (
        .clk(clk), .rst_n(rst_n),
        .rd_req_valid(rd_req_valid), .rd_req_ready(rd_req_ready),
        .rd_req_type(rd_req_type), .rd_req_base_addr(rd_req_base_addr),
        .rd_req_rows(rd_req_rows), .rd_req_cols(rd_req_cols),
        .rd_req_stride(rd_req_stride), .rd_req_last(rd_req_last),
        .rd_done(rd_done), .rd_err(rd_err),
        .rd_data_valid(rd_data_valid), .rd_data_ready(rd_data_ready),
        .rd_data_payload(rd_data_payload), .rd_data_last(rd_data_last),
        .rd_data_type(rd_data_type),
        .axi_rd_cmd_valid(axi_rd_cmd_valid),
        .axi_rd_cmd_ready(axi_rd_cmd_ready),
        .axi_rd_cmd_addr(axi_rd_cmd_addr),
        .axi_rd_cmd_len(axi_rd_cmd_len),
        .axi_rd_cmd_size(axi_rd_cmd_size),
        .axi_rd_data_valid(axi_rd_data_valid),
        .axi_rd_data_ready(axi_rd_data_ready),
        .axi_rd_data_payload(axi_rd_data_payload),
        .axi_rd_data_last(axi_rd_data_last),
        .axi_rd_resp_err(axi_rd_resp_err)
    );

    // DMA Write Controller
    dma_wr #(
        .ADDR_W(ADDR_W), .DIM_W(DIM_W), .STRIDE_W(STRIDE_W),
        .AXI_DATA_W(AXI_DATA_W), .MAX_BURST_LEN(MAX_BURST_LEN),
        .OUTSTANDING_WR(OUTSTANDING_WR)
    ) u_dma_wr (
        .clk(clk), .rst_n(rst_n),
        .wr_req_valid(wr_req_valid), .wr_req_ready(wr_req_ready),
        .wr_req_base_addr(wr_req_base_addr),
        .wr_req_rows(wr_req_rows), .wr_req_cols(wr_req_cols),
        .wr_req_stride(wr_req_stride), .wr_req_last(wr_req_last),
        .wr_done(wr_done), .wr_err(wr_err),
        .wr_data_valid(dma_wr_data_valid), .wr_data_ready(dma_wr_data_ready),
        .wr_data_payload(dma_wr_data_payload), .wr_data_last(dma_wr_data_last),
        .axi_wr_cmd_valid(axi_wr_cmd_valid),
        .axi_wr_cmd_ready(axi_wr_cmd_ready),
        .axi_wr_cmd_addr(axi_wr_cmd_addr),
        .axi_wr_cmd_len(axi_wr_cmd_len),
        .axi_wr_cmd_size(axi_wr_cmd_size),
        .axi_wr_data_valid(axi_wr_data_valid),
        .axi_wr_data_ready(axi_wr_data_ready),
        .axi_wr_data_payload(axi_wr_data_payload),
        .axi_wr_data_last(axi_wr_data_last),
        .axi_wr_data_strb(axi_wr_data_strb),
        .axi_wr_resp_err(axi_wr_resp_err)
    );

    // Buffer Bank
    buffer_bank #(
        .P_M(P_M), .P_N(P_N), .ELEM_W(ELEM_W), .ACC_W(ACC_W),
        .BUF_BANKS(BUF_BANKS), .BUF_DEPTH(BUF_DEPTH),
        .AXI_DATA_W(AXI_DATA_W)
    ) u_buffer_bank (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(buf_wr_valid_mux), .wr_ready(buf_wr_ready_mux),
        .wr_sel(buf_wr_sel_mux), .wr_bank(buf_wr_bank_mux),
        .wr_addr(buf_wr_addr_mux), .wr_data(buf_wr_data_mux),
        .wr_mask(buf_wr_mask_mux),
        .rd_req_valid(array_io_adapter_rd_req_valid),
        .rd_req_ready(buf_rd_req_ready_mux),
        .rd_sel(array_io_adapter_rd_sel),
        .rd_bank(array_io_adapter_rd_bank),
        .rd_addr(array_io_adapter_rd_addr),
        .rd_data_valid(buf_rd_data_valid_mux),
        .rd_data(buf_rd_data_mux),
        .pp_switch_req(pp_switch_req),
        .pp_switch_ack(),
        .pp_a_compute_sel(),
        .pp_b_compute_sel(),
        .pp_a_load_sel(),
        .pp_b_load_sel(),
        .conflict_stall(),
        .bank_occ()
    );

    // A Loader
    a_loader #(
        .P_M(P_M), .P_N(P_N), .ELEM_W(ELEM_W),
        .BUF_BANKS(BUF_BANKS), .BUF_DEPTH(BUF_DEPTH),
        .AXI_DATA_W(AXI_DATA_W)
    ) u_a_loader (
        .clk(clk), .rst_n(rst_n),
        .dma_valid(a_dma_valid), .dma_ready(a_loader_dma_ready),
        .dma_data(a_dma_data), .dma_last(a_dma_last),
        .tile_rows(act_rows), .tile_cols(act_cols),
        .tile_stride(cfg_stride_a), .base_addr(cfg_addr_a),
        .pp_sel(1'b0),
        .buf_wr_valid(a_loader_buf_wr_valid),
        .buf_wr_ready(a_loader_buf_wr_ready),
        .buf_wr_sel(a_loader_buf_wr_sel),
        .buf_wr_bank(a_loader_buf_wr_bank),
        .buf_wr_addr(a_loader_buf_wr_addr),
        .buf_wr_data(a_loader_buf_wr_data),
        .buf_wr_mask(a_loader_buf_wr_mask),
        .load_done(),
        .load_err()
    );

    // B Loader
    b_loader #(
        .P_M(P_M), .P_N(P_N), .ELEM_W(ELEM_W),
        .BUF_BANKS(BUF_BANKS), .BUF_DEPTH(BUF_DEPTH),
        .AXI_DATA_W(AXI_DATA_W)
    ) u_b_loader (
        .clk(clk), .rst_n(rst_n),
        .dma_valid(b_dma_valid), .dma_ready(b_loader_dma_ready),
        .dma_data(b_dma_data), .dma_last(b_dma_last),
        .tile_rows(act_rows), .tile_cols(act_cols),
        .tile_stride(cfg_stride_b), .base_addr(cfg_addr_b),
        .pp_sel(1'b0),
        .buf_wr_valid(b_loader_buf_wr_valid),
        .buf_wr_ready(b_loader_buf_wr_ready),
        .buf_wr_sel(b_loader_buf_wr_sel),
        .buf_wr_bank(b_loader_buf_wr_bank),
        .buf_wr_addr(b_loader_buf_wr_addr),
        .buf_wr_data(b_loader_buf_wr_data),
        .buf_wr_mask(b_loader_buf_wr_mask),
        .load_done(),
        .load_err()
    );

    // C Loader
    c_loader #(
        .P_M(P_M), .P_N(P_N), .ELEM_W(ELEM_W),
        .BUF_BANKS(BUF_BANKS), .BUF_DEPTH(BUF_DEPTH),
        .AXI_DATA_W(AXI_DATA_W)
    ) u_c_loader (
        .clk(clk), .rst_n(rst_n),
        .dma_valid(c_dma_valid), .dma_ready(c_loader_dma_ready),
        .dma_data(c_dma_data), .dma_last(c_dma_last),
        .tile_rows(act_rows), .tile_cols(act_cols),
        .tile_stride(cfg_stride_c), .base_addr(cfg_addr_c),
        .buf_wr_valid(c_loader_buf_wr_valid),
        .buf_wr_ready(c_loader_buf_wr_ready),
        .buf_wr_bank(c_loader_buf_wr_bank),
        .buf_wr_addr(c_loader_buf_wr_addr),
        .buf_wr_data(c_loader_buf_wr_data),
        .buf_wr_mask(c_loader_buf_wr_mask),
        .load_done(),
        .load_err()
    );

    // D Storer
    d_storer #(
        .P_M(P_M), .P_N(P_N), .ELEM_W(ELEM_W),
        .BUF_BANKS(BUF_BANKS), .BUF_DEPTH(BUF_DEPTH),
        .AXI_DATA_W(AXI_DATA_W)
    ) u_d_storer (
        .clk(clk), .rst_n(rst_n),
        .post_valid(pp_d_valid), .post_ready(pp_d_ready),
        .post_data(pp_d_data), .post_last(pp_d_last),
        .tile_rows(act_rows), .tile_cols(act_cols),
        .tile_stride(cfg_stride_d), .base_addr(cfg_addr_d),
        .buf_wr_valid(d_storer_buf_wr_valid),
        .buf_wr_ready(d_storer_buf_wr_ready),
        .buf_wr_sel(d_storer_buf_wr_sel),
        .buf_wr_bank(d_storer_buf_wr_bank),
        .buf_wr_addr(d_storer_buf_wr_addr),
        .buf_wr_data(d_storer_buf_wr_data),
        .buf_wr_mask(d_storer_buf_wr_mask),
        .store_done(),
        .store_err()
    );

    // Array IO Adapter
    array_io_adapter #(
        .P_M(P_M), .P_N(P_N), .ELEM_W(ELEM_W)
    ) u_array_io_adapter (
        .clk(clk), .rst_n(rst_n),
        .buf_a_data(buf_a_data),
        .buf_b_data(buf_b_data),
        .issue_valid(core_busy),
        .mask_cfg(tile_mask),
        .a_vec_valid(core_a_vec_valid),
        .a_vec_data(core_a_vec_data),
        .a_vec_mask(core_a_vec_mask),
        .b_vec_valid(core_b_vec_valid),
        .b_vec_data(core_b_vec_data),
        .b_vec_mask(core_b_vec_mask),
        .issue_ready(issue_ready)
    );

    // Systolic Core
    systolic_core #(
        .P_M(P_M), .P_N(P_N), .ELEM_W(ELEM_W), .ACC_W(ACC_W)
    ) u_systolic_core (
        .clk(clk), .rst_n(rst_n),
        .core_start(core_start), .core_mode(1'b0),
        .core_busy(core_busy), .core_done(core_done),
        .core_err(core_err),
        .a_vec_valid(core_a_vec_valid),
        .a_vec_data(core_a_vec_data),
        .a_vec_mask(core_a_vec_mask),
        .b_vec_valid(core_b_vec_valid),
        .b_vec_data(core_b_vec_data),
        .b_vec_mask(core_b_vec_mask),
        .k_iter_cfg(act_k),
        .tile_mask_cfg(tile_mask),
        .debug_cfg(core_debug_cfg),
        .acc_out_valid(acc_out_valid),
        .acc_out_data(acc_out_data),
        .acc_out_last(acc_out_last),
        .perf_active_cycles(core_perf_active),
        .perf_fill_cycles(core_perf_fill),
        .perf_drain_cycles(core_perf_drain),
        .perf_stall_cycles(core_perf_stall),
        .err_code(core_err_code)
    );

    // Postprocess
    postproc #(
        .P_M(P_M), .P_N(P_N), .ELEM_W(ELEM_W), .ACC_W(ACC_W)
    ) u_postproc (
        .clk(clk), .rst_n(rst_n),
        .pp_start(pp_start), .pp_busy(pp_busy),
        .pp_done(pp_done), .pp_err(pp_err),
        .add_c_en(cfg_add_c_en),
        .round_mode(cfg_round_mode),
        .sat_en(cfg_sat_en),
        .tile_mask(tile_mask),
        .acc_valid(acc_out_valid),
        .acc_data(acc_out_data),
        .acc_last(acc_out_last),
        .c_valid(1'b0),
        .c_ready(),
        .c_data('0),
        .c_last(1'b0),
        .d_valid(pp_d_valid),
        .d_ready(dma_wr_data_ready),
        .d_data(pp_d_data),
        .d_last(pp_d_last),
        .d_mask(pp_d_mask),
        .exc_nan_cnt(),
        .exc_inf_cnt(),
        .exc_ovf_cnt(),
        .exc_udf_cnt(),
        .exc_denorm_cnt()
    );

endmodule : gemm_top
`endif // GEMM_TOP_SV
