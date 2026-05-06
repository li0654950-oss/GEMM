//------------------------------------------------------------------------------
// tile_scheduler.sv
// GEMM Tile Scheduler - Triple Loop Controller
//
// Description:
//   Manages (m0,n0,k0) tile loops, boundary mask generation, DMA handshake,
//   compute/postproc triggering, and ping-pong buffer switching.
//   Implements full FSM per spec/top_system_control_spec.md Section 7.5.2.
//------------------------------------------------------------------------------
`ifndef TILE_SCHEDULER_SV
`define TILE_SCHEDULER_SV

module tile_scheduler #(
    parameter int P_M      = 4,
    parameter int P_N      = 4,
    parameter int DIM_W    = 16,
    parameter int ADDR_W   = 64,
    parameter int STRIDE_W = 32,
    parameter int TILE_W   = 16,
    parameter int ELEM_W   = 16,
    parameter int ERR_CODE_W = 16
)(
    input  wire              clk,
    input  wire              rst_n,

    // Configuration from csr_if --------------------------------------------
    input  wire [DIM_W-1:0]  cfg_m,
    input  wire [DIM_W-1:0]  cfg_n,
    input  wire [DIM_W-1:0]  cfg_k,
    input  wire [TILE_W-1:0] cfg_tile_m,
    input  wire [TILE_W-1:0] cfg_tile_n,
    input  wire [TILE_W-1:0] cfg_tile_k,
    input  wire [ADDR_W-1:0] cfg_addr_a,
    input  wire [ADDR_W-1:0] cfg_addr_b,
    input  wire [ADDR_W-1:0] cfg_addr_c,
    input  wire [ADDR_W-1:0] cfg_addr_d,
    input  wire [STRIDE_W-1:0] cfg_stride_a,
    input  wire [STRIDE_W-1:0] cfg_stride_b,
    input  wire [STRIDE_W-1:0] cfg_stride_c,
    input  wire [STRIDE_W-1:0] cfg_stride_d,
    input  wire              cfg_add_c_en,
    input  wire              cfg_start,

    // Status outputs to csr_if ---------------------------------------------
    output reg               sch_busy,
    output reg               sch_done,
    output reg               sch_err,
    output reg  [ERR_CODE_W-1:0] sch_err_code,
    output reg  [TILE_W-1:0] sch_tile_m_idx,
    output reg  [TILE_W-1:0] sch_tile_n_idx,
    output reg  [TILE_W-1:0] sch_tile_k_idx,
    output wire [P_M*P_N-1:0] tile_mask,

    // DMA read request interface -------------------------------------------
    output reg               rd_req_valid,
    input  wire              rd_req_ready,
    output reg  [1:0]        rd_req_type,
    output reg  [ADDR_W-1:0] rd_req_base_addr,
    output reg  [TILE_W-1:0] rd_req_rows,
    output reg  [TILE_W-1:0] rd_req_cols,
    output reg  [STRIDE_W-1:0] rd_req_stride,
    output reg               rd_req_last,
    input  wire              rd_done,
    input  wire              rd_err,

    // DMA write request interface ------------------------------------------
    output reg               wr_req_valid,
    input  wire              wr_req_ready,
    output reg  [ADDR_W-1:0] wr_req_base_addr,
    output reg  [TILE_W-1:0] wr_req_rows,
    output reg  [TILE_W-1:0] wr_req_cols,
    output reg  [STRIDE_W-1:0] wr_req_stride,
    output reg               wr_req_last,
    input  wire              wr_done,
    input  wire              wr_err,

    // Compute core control -------------------------------------------------
    output reg               core_start,
    input  wire              core_done,
    input  wire              core_busy,
    input  wire              core_err,

    // Postproc control -----------------------------------------------------
    output reg               pp_start,
    input  wire              pp_done,
    input  wire              pp_busy,

    // Buffer ping-pong -----------------------------------------------------
    output reg               pp_switch_req,
    input  wire              pp_switch_ack,

    // Performance counter triggers -----------------------------------------
    output reg               cnt_start,
    output reg               cnt_stop,

    // Active tile dimensions (for loaders) ---------------------------------
    output reg  [TILE_W-1:0] act_rows_o,
    output reg  [TILE_W-1:0] act_cols_o,
    output reg  [TILE_W-1:0] act_k_o
);

    import gemm_pkg::*;

    //------------------------------------------------------------------------
    // Tile loop indices and remainders
    //------------------------------------------------------------------------
    reg [DIM_W-1:0] m0, n0, k0;
    reg [DIM_W-1:0] m_rem, n_rem, k_rem;
    reg [TILE_W-1:0] act_rows, act_cols, act_k;
    reg core_started;
    reg wr_req_issued;

    //------------------------------------------------------------------------
    // Boundary mask generation
    //------------------------------------------------------------------------
    wire [P_M-1:0] row_mask;
    wire [P_N-1:0] col_mask;
    genvar gi, gj;

    generate
        for (gi = 0; gi < P_M; gi = gi + 1) begin : g_row_mask
            assign row_mask[gi] = (gi < act_rows);
        end
        for (gj = 0; gj < P_N; gj = gj + 1) begin : g_col_mask
            assign col_mask[gj] = (gj < act_cols);
        end
    endgenerate

    // Flatten mask: tile_mask[i] = (i/P_N < act_rows) && (i%P_N < act_cols)
    genvar gk;
    generate
        for (gk = 0; gk < P_M*P_N; gk = gk + 1) begin : g_flat_mask
            localparam int row_idx = gk / P_N;
            localparam int col_idx = gk % P_N;
            assign tile_mask[gk] = (row_idx < act_rows) && (col_idx < act_cols);
        end
    endgenerate

    //------------------------------------------------------------------------
    // FSM
    //------------------------------------------------------------------------
    sched_state_t state, next_state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= SCH_IDLE;
        end else begin
            state <= next_state;
        end
    end

    // Next state logic
    always_comb begin
        next_state = state;
        case (state)
            SCH_IDLE:
                if (cfg_start && !sch_busy) next_state = SCH_PRECHECK;
            SCH_PRECHECK:
                if (m_rem == '0 || n_rem == '0 || k_rem == '0) next_state = SCH_ERR;
                else next_state = SCH_LOAD_AB;
            SCH_LOAD_AB:
                if (rd_err) next_state = SCH_ERR;
                else if (rd_req_ready && rd_req_last) next_state = (cfg_add_c_en) ? SCH_LOAD_C : SCH_WAIT_RD;
            SCH_LOAD_C:
                if (rd_err) next_state = SCH_ERR;
                else if (rd_req_ready && rd_req_last) next_state = SCH_WAIT_RD;
            SCH_WAIT_RD:
                if (rd_err) next_state = SCH_ERR;
                else if (rd_done && pp_switch_ack) next_state = SCH_COMPUTE;
            SCH_COMPUTE:
                if (core_err) next_state = SCH_ERR;
                else if (core_done) next_state = SCH_CHECK_K;
            SCH_CHECK_K:
                if (k_rem > cfg_tile_k) next_state = SCH_NEXT_K;
                else next_state = SCH_STORE;
            SCH_STORE:
                if (wr_err) next_state = SCH_ERR;
                else if (wr_done) next_state = SCH_CHECK_MN;
            SCH_CHECK_MN:
                if (n_rem > cfg_tile_n) next_state = SCH_NEXT_MN;
                else if (m_rem > cfg_tile_m) next_state = SCH_NEXT_MN;
                else next_state = SCH_DONE;
            SCH_NEXT_K:
                next_state = SCH_LOAD_AB;
            SCH_NEXT_MN:
                next_state = SCH_LOAD_AB;
            SCH_DONE:
                next_state = SCH_DONE2;
            SCH_DONE2:
                next_state = SCH_IDLE;
            SCH_ERR:
                next_state = SCH_IDLE;  // wait for soft_reset or auto-clear
            default: next_state = SCH_IDLE;
        endcase
    end

    //------------------------------------------------------------------------
    // Sequential logic: loop counters, outputs, status
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m0 <= '0; n0 <= '0; k0 <= '0;
            m_rem <= '0; n_rem <= '0; k_rem <= '0;
            act_rows <= '0; act_cols <= '0; act_k <= '0;
            act_rows_o <= '0; act_cols_o <= '0; act_k_o <= '0;
            sch_busy <= 1'b0;
            sch_done <= 1'b0;
            sch_err  <= 1'b0;
            sch_err_code <= ERR_NONE;
            sch_tile_m_idx <= '0;
            sch_tile_n_idx <= '0;
            sch_tile_k_idx <= '0;
            rd_req_valid <= 1'b0;
            wr_req_valid <= 1'b0;
            wr_req_issued <= 1'b0;
            core_start <= 1'b0;
            pp_start <= 1'b0;
            pp_switch_req <= 1'b0;
            cnt_start <= 1'b0;
            cnt_stop <= 1'b0;
            core_started <= 1'b0;
        end else begin
            `ifdef SIMULATION
            if (state != next_state) begin
                $display("[SCH] state %0d -> %0d at time %0t", state, next_state, $time);
            end
            `endif
            sch_done <= 1'b0;
            sch_err  <= 1'b0;
            rd_req_valid <= 1'b0;
            wr_req_valid <= 1'b0;
            core_start <= 1'b0;
            pp_start <= 1'b0;
            cnt_start <= 1'b0;
            cnt_stop <= 1'b0;
            core_started <= 1'b0;

            case (state)
                SCH_IDLE: begin
                    `ifdef SIMULATION
                    if (cfg_start) $display("[SCH] SCH_IDLE cfg_start=1 sch_busy=%b", sch_busy);
                    `endif
                    if (cfg_start && !sch_busy) begin
                        sch_busy <= 1'b1;
                        m0 <= '0; n0 <= '0; k0 <= '0;
                        m_rem <= cfg_m;
                        n_rem <= cfg_n;
                        k_rem <= cfg_k;
                        cnt_start <= 1'b1;
                    end
                end

                SCH_PRECHECK: begin
                    act_rows <= (m_rem < cfg_tile_m) ? m_rem[TILE_W-1:0] : cfg_tile_m;
                    act_cols <= (n_rem < cfg_tile_n) ? n_rem[TILE_W-1:0] : cfg_tile_n;
                    act_k    <= (k_rem < cfg_tile_k) ? k_rem[TILE_W-1:0] : cfg_tile_k;
                    act_rows_o <= (m_rem < cfg_tile_m) ? m_rem[TILE_W-1:0] : cfg_tile_m;
                    act_cols_o <= (n_rem < cfg_tile_n) ? n_rem[TILE_W-1:0] : cfg_tile_n;
                    act_k_o    <= (k_rem < cfg_tile_k) ? k_rem[TILE_W-1:0] : cfg_tile_k;
                end

                SCH_LOAD_AB: begin
                    // Issue A read
                    rd_req_valid <= 1'b1;
                    rd_req_type  <= 2'b00; // A
                    rd_req_base_addr <= cfg_addr_a + m0 * cfg_stride_a + k0 * ELEM_W;
                    rd_req_rows  <= act_rows;
                    rd_req_cols  <= act_k;
                    rd_req_stride <= cfg_stride_a;
                    rd_req_last  <= !cfg_add_c_en;
                end

                SCH_LOAD_C: begin
                    if (k0 == '0) begin
                        rd_req_valid <= 1'b1;
                        rd_req_type  <= 2'b10; // C
                        rd_req_base_addr <= cfg_addr_c + m0 * cfg_stride_c + n0 * ELEM_W;
                        rd_req_rows  <= act_rows;
                        rd_req_cols  <= act_cols;
                        rd_req_stride <= cfg_stride_c;
                        rd_req_last  <= 1'b1;
                    end
                end

                SCH_WAIT_RD: begin
                    if (rd_done) begin
                        `ifdef SIMULATION
                        $display("[SCH] WAIT_RD -> rd_done=1 at cycle %0t", $time);
                        `endif
                        pp_switch_req <= 1'b1;
                    end
                end

                SCH_COMPUTE: begin
                    `ifdef SIMULATION
                    if (core_done) $display("[SCH] COMPUTE -> core_done=1");
                    $display("[SCH] SCH_COMPUTE core_busy=%b core_started=%b", core_busy, core_started);
                    `endif
                    if (!core_busy && !core_started) begin
                        core_start <= 1'b1;
                        core_started <= 1'b1;
                    end
                    pp_start <= 1'b1;
                end

                SCH_CHECK_K: begin
                    `ifdef SIMULATION
                    $display("[SCH] CHECK_K k_rem=%0d cfg_tile_k=%0d", k_rem, cfg_tile_k);
                    `endif
                    if (k_rem <= cfg_tile_k) begin
                        // last k-chunk, trigger postproc
                        // pp_start moved to SCH_COMPUTE for timing
                    end
                end

                SCH_STORE: begin
                    `ifdef SIMULATION
                    if (wr_done) $display("[SCH] STORE -> wr_done=1");
                    `endif
                    if (wr_req_ready && !wr_req_issued) begin
                        wr_req_valid <= 1'b1;
                        wr_req_base_addr <= cfg_addr_d + m0 * cfg_stride_d + n0 * ELEM_W;
                        wr_req_rows  <= act_rows;
                        wr_req_cols  <= act_cols;
                        wr_req_stride <= cfg_stride_d;
                        wr_req_last  <= (m_rem <= cfg_tile_m) && (n_rem <= cfg_tile_n);
                        wr_req_issued <= 1'b1;
                    end
                end

                SCH_CHECK_MN: begin
                    wr_req_issued <= 1'b0;
                end

                SCH_NEXT_K: begin
                    k0 <= k0 + cfg_tile_k;
                    k_rem <= k_rem - cfg_tile_k;
                    sch_tile_k_idx <= k0[TILE_W-1:0];
                end

                SCH_NEXT_MN: begin
                    if (n_rem > cfg_tile_n) begin
                        n0 <= n0 + cfg_tile_n;
                        n_rem <= n_rem - cfg_tile_n;
                        k0 <= '0;
                        k_rem <= cfg_k;
                    end else if (m_rem > cfg_tile_m) begin
                        m0 <= m0 + cfg_tile_m;
                        m_rem <= m_rem - cfg_tile_m;
                        n0 <= '0;
                        n_rem <= cfg_n;
                        k0 <= '0;
                        k_rem <= cfg_k;
                    end
                    sch_tile_m_idx <= m0[TILE_W-1:0];
                    sch_tile_n_idx <= n0[TILE_W-1:0];
                    sch_tile_k_idx <= k0[TILE_W-1:0];
                end

                SCH_DONE: begin
                    sch_busy <= 1'b0;
                    sch_done <= 1'b1;
                    cnt_stop <= 1'b1;
                end

                SCH_DONE2: begin
                    sch_busy <= 1'b0;
                    sch_done <= 1'b1;
                    cnt_stop <= 1'b1;
                end

                SCH_ERR: begin
                    sch_busy <= 1'b0;
                    sch_err  <= 1'b1;
                    if (m_rem == '0 || n_rem == '0 || k_rem == '0)
                        sch_err_code <= ERR_ILLEGAL_DIM;
                    else if (rd_err)
                        sch_err_code <= ERR_DMA_RD;
                    else if (wr_err)
                        sch_err_code <= ERR_DMA_WR;
                    else if (core_err)
                        sch_err_code <= ERR_CORE;
                    else
                        sch_err_code <= ERR_NONE;
                    cnt_stop <= 1'b1;
                end

                default: ;
            endcase
        end
    end

endmodule : tile_scheduler
`endif // TILE_SCHEDULER_SV
