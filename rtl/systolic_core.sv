//------------------------------------------------------------------------------
// systolic_core.sv
// GEMM Systolic Array - Compute Core (PE Array + Control)
//
// Description:
//   P_M x P_N PE 阵列顶层。实现 A 左入右传、B 上入下传的脉动数据流。
//   包含 fill/drain 周期控制、acc_clear/acc_hold 广播、累加结果收集。
//   集成错误检测、调试模式、性能计数器、低功耗门控。
//
//   Output-Stationary: 每个 PE 保留本地累加器，tile 结束后统一读出。
//
// Spec Reference: spec/systolic_compute_core_spec.md
//------------------------------------------------------------------------------

`ifndef SYSTOLIC_CORE_SV
`define SYSTOLIC_CORE_SV

module systolic_core #(
    parameter int P_M     = 2,
    parameter int P_N     = 2,
    parameter int ELEM_W  = 16,
    parameter int ACC_W   = 32,
    parameter int K_MAX   = 4096
)(
    input  wire              clk,
    input  wire              rst_n,

    // Control interface -----------------------------------------------------
    input  wire              core_start,      // one-shot pulse to start tile
    input  wire              core_mode,       // 0=FP16acc, 1=FP32acc
    output reg               core_busy,
    output reg               core_done,       // pulse when tile complete
    output reg               core_err,

    // A vector input (from array_io_adapter / buffer) -----------------------
    input  wire              a_vec_valid,
    input  wire [P_M*ELEM_W-1:0] a_vec_data,
    input  wire [P_M-1:0]    a_vec_mask,

    // B vector input
    input  wire              b_vec_valid,
    input  wire [P_N*ELEM_W-1:0] b_vec_data,
    input  wire [P_N-1:0]    b_vec_mask,

    // Tile configuration -----------------------------------------------------
    input  wire [15:0]       k_iter_cfg,
    input  wire [P_M*P_N-1:0] tile_mask_cfg,

    // Debug / Test mode (from CSR / debug controller) ----------------------
    input  wire [2:0]        debug_cfg,       // [0]=single_pe, [1]=bypass_acc, [2]=force_mask

    // Diagnostic / Performance counters -------------------------------------
    output reg  [31:0]       perf_active_cycles,
    output reg  [31:0]       perf_fill_cycles,
    output reg  [31:0]       perf_drain_cycles,
    output reg  [31:0]       perf_stall_cycles,

    // Error reporting -------------------------------------------------------
    output reg  [2:0]        err_code,        // [0]=illegal_mode, [1]=protocol_mismatch, [2]=internal_overflow

    // Accumulator output (to postproc / d_storer) ---------------------------
    output reg               acc_out_valid,
    output logic [P_M*P_N*ACC_W-1:0] acc_out_data,
    output reg               acc_out_last
);

    //------------------------------------------------------------------------
    // Internal arrays for PE mesh connections
    //------------------------------------------------------------------------

    // A propagation: horizontal, size [P_M][P_N+1]
    logic [ELEM_W-1:0] a_mesh [0:P_M-1][0:P_N];

    // B propagation: vertical, size [P_M+1][P_N]
    logic [ELEM_W-1:0] b_mesh [0:P_M][0:P_N-1];

    // Valid propagation
    logic              v_mesh [0:P_M-1][0:P_N];
    /* verilator lint_off UNOPTFLAT */
    logic              v_bmesh [0:P_M][0:P_N-1];
    /* verilator lint_on UNOPTFLAT */

    // Accumulator unpacked view
    logic [ACC_W-1:0]  acc_pe [0:P_M-1][0:P_N-1];
    logic              sat_pe [0:P_M-1][0:P_N-1];

    // Flat packed accumulator
    logic [P_M*P_N*ACC_W-1:0] acc_pe_flat;

    // Per-PE control (broadcast)
    logic              pe_acc_clear;
    logic              pe_acc_hold;

    // Debug mode decode
    wire               dbg_single_pe  = debug_cfg[0];
    wire               dbg_bypass_acc  = debug_cfg[1];
    wire               dbg_force_mask  = debug_cfg[2];

    // Effective mask (debug force_mask overrides tile_mask_cfg)
    logic [P_M*P_N-1:0] eff_mask;
    always_comb begin
        if (dbg_force_mask)
            // Force only PE[0][0] active for debug
            eff_mask = {{(P_M*P_N-1){1'b0}}, 1'b1};
        else
            eff_mask = tile_mask_cfg;
    end

    //------------------------------------------------------------------------
    // A/B vector demux to mesh boundary
    //------------------------------------------------------------------------
    genvar gi, gj;

    generate
        for (gi = 0; gi < P_M; gi = gi + 1) begin : g_a_demux
            assign a_mesh[gi][0] = a_vec_data[(gi+1)*ELEM_W-1 : gi*ELEM_W];
        end
        for (gj = 0; gj < P_N; gj = gj + 1) begin : g_b_demux
            assign b_mesh[0][gj] = b_vec_data[(gj+1)*ELEM_W-1 : gj*ELEM_W];
        end
    endgenerate

    // Valid demux with mask
    generate
        for (gi = 0; gi < P_M; gi = gi + 1) begin : g_v_a_demux
            assign v_mesh[gi][0] = a_vec_valid && a_vec_mask[gi];
        end
        for (gj = 0; gj < P_N; gj = gj + 1) begin : g_v_b_demux
            assign v_bmesh[0][gj] = b_vec_valid && b_vec_mask[gj];
        end
    endgenerate

    // B-valid vertical propagation
    generate
        for (gi = 0; gi < P_M-1; gi = gi + 1) begin : g_v_b_prop
            for (gj = 0; gj < P_N; gj = gj + 1) begin : g_v_b_prop_col
                assign v_bmesh[gi+1][gj] = v_bmesh[gi][gj];
            end
        end
    endgenerate

    //------------------------------------------------------------------------
    // PE Array Instantiation
    //------------------------------------------------------------------------
    generate
        for (gi = 0; gi < P_M; gi = gi + 1) begin : g_row
            for (gj = 0; gj < P_N; gj = gj + 1) begin : g_col

                // Base valid: A && B && effective mask
                logic pe_valid_base;
                assign pe_valid_base = v_mesh[gi][gj] && v_bmesh[gi][gj]
                                       && eff_mask[gi*P_N+gj];

                // Single-PE mode: only PE[0][0] active
                logic pe_valid;
                assign pe_valid = dbg_single_pe ? ((gi==0 && gj==0) ? pe_valid_base : 1'b0)
                                                : pe_valid_base;

                pe_cell #(
                    .ELEM_W (ELEM_W),
                    .ACC_W  (ACC_W),
                    .ACC_FP32_DEFAULT (1'b1)
                ) u_pe (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .a_in      (a_mesh[gi][gj]),
                    .b_in      (b_mesh[gi][gj]),
                    .a_out     (a_mesh[gi][gj+1]),
                    .b_out     (b_mesh[gi+1][gj]),
                    .valid_in  (pe_valid),
                    .acc_clear (pe_acc_clear),
                    .acc_hold  (pe_acc_hold),
                    .acc_mode  (core_mode),
                    .acc_out   (acc_pe_flat[(gi*P_N+gj)*ACC_W +: ACC_W]),
                    .valid_out (v_mesh[gi][gj+1]),
                    .sat_flag  (sat_pe[gi][gj])
                );

            end
        end
    endgenerate

    // Unpack acc_pe_flat to acc_pe array
    generate
        for (gi = 0; gi < P_M; gi = gi + 1) begin : g_acc_unpack_row
            for (gj = 0; gj < P_N; gj = gj + 1) begin : g_acc_unpack_col
                always_comb begin
                    acc_pe[gi][gj] = acc_pe_flat[(gi*P_N+gj)*ACC_W +: ACC_W];
                end
            end
        end
    endgenerate

    // Output assignment
    assign acc_out_data = acc_pe_flat;

    //------------------------------------------------------------------------
    // Control FSM
    //------------------------------------------------------------------------
    localparam int FILL_DRAIN_CYCLES = P_M + P_N - 2;

    typedef enum logic [2:0] {
        IDLE,
        CLEAR,
        COMPUTE,
        COMMIT,
        DONE
    } state_t;

    state_t state, next_state;

    reg [15:0] k_cnt;
    reg        err_protocol;    // core_start while busy
    reg        err_k_overflow;  // k_cnt > K_MAX

    // Sequential update
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= IDLE;
            k_cnt         <= '0;
            core_busy     <= 1'b0;
            core_done     <= 1'b0;
            core_err      <= 1'b0;
            err_code      <= '0;
            err_protocol  <= 1'b0;
            err_k_overflow<= 1'b0;
            acc_out_valid <= 1'b0;
            acc_out_last  <= 1'b0;
            // Counters
        perf_active_cycles <= '0;
        perf_fill_cycles   <= '0;
        perf_drain_cycles  <= '0;
        perf_stall_cycles  <= '0;
            perf_active_cycles <= '0;
            perf_fill_cycles   <= '0;
            perf_drain_cycles  <= '0;
            perf_stall_cycles  <= '0;
        end else begin
            state     <= next_state;
            core_done <= 1'b0;
            acc_out_valid <= 1'b0;
            acc_out_last  <= 1'b0;

            // Error detection ------------------------------------------------
            if (core_start && core_busy) begin
                err_protocol <= 1'b1;
                err_code[1]  <= 1'b1;  // protocol_mismatch
                core_err     <= 1'b1;
            end

            if (k_cnt > K_MAX) begin
                err_k_overflow <= 1'b1;
                err_code[2]    <= 1'b1;  // internal_overflow
                core_err       <= 1'b1;
            end

            // Illegal mode: only 0 and 1 are valid
            if (core_mode !== 1'b0 && core_mode !== 1'b1) begin
                err_code[0] <= 1'b1;  // illegal_mode
                core_err    <= 1'b1;
            end

            case (state)
                IDLE: begin
                    if (core_start) begin
                        core_busy <= 1'b1;
                        k_cnt     <= '0;
                        // Clear sticky errors for new tile
                        err_protocol   <= 1'b0;
                        err_k_overflow <= 1'b0;
                        core_err       <= 1'b0;
                        err_code       <= '0;
                    end else begin
                        perf_stall_cycles <= perf_stall_cycles + 1'b1;
                    end
                end

                CLEAR: begin
                    // one cycle clear
                end

                COMPUTE: begin
                    k_cnt <= k_cnt + 1'b1;

                    // Performance counters
                    if (a_vec_valid && b_vec_valid)
                        perf_active_cycles <= perf_active_cycles + 1'b1;

                    if (k_cnt < FILL_DRAIN_CYCLES)
                        perf_fill_cycles <= perf_fill_cycles + 1'b1;

                    if (k_cnt >= k_iter_cfg)
                        perf_drain_cycles <= perf_drain_cycles + 1'b1;
                end

                COMMIT: begin
                    acc_out_valid <= 1'b1;
                    acc_out_last  <= 1'b1;
                end

                DONE: begin
                    core_busy <= 1'b0;
                    core_done <= 1'b1;
                end

                default: ;
            endcase
        end
    end

    // Next-state logic
    always_comb begin
        next_state = state;
        case (state)
            IDLE:    if (core_start)           next_state = CLEAR;
            CLEAR:   next_state = COMPUTE;
            COMPUTE: if (k_cnt >= k_iter_cfg + FILL_DRAIN_CYCLES)
                                                next_state = COMMIT;
            COMMIT:  next_state = DONE;
            DONE:    next_state = IDLE;
            default: next_state = IDLE;
        endcase
    end

    // Acc control generation (with bypass_acc debug mode)
    always_comb begin
        pe_acc_clear = 1'b0;
        pe_acc_hold  = 1'b0;
        case (state)
            CLEAR:   pe_acc_clear = 1'b1;
            COMPUTE: pe_acc_hold  = dbg_bypass_acc ? 1'b1 : 1'b0;
            COMMIT:  pe_acc_hold  = 1'b1;
            DONE:    pe_acc_hold  = 1'b1;
            default: ;
        endcase
        // bypass_acc also forces clear to keep acc at 0
        if (dbg_bypass_acc)
            pe_acc_clear = (state == CLEAR) ? 1'b1 : 1'b0;
    end

endmodule : systolic_core

`endif // SYSTOLIC_CORE_SV
