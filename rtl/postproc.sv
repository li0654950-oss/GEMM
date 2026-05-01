//------------------------------------------------------------------------------
// postproc.sv
// GEMM Post-Processing Pipeline Top Level
//
// Description:
//   3-stage pipeline connecting systolic_core accumulator output to d_storer.
//   Stage0: align and mask application (internal register)
//   Stage1: fp_add_c - optional FP16 C tile fusion (1-cycle, registered)
//   Stage2: fp_round_sat - FP32 to FP16 conversion (1-cycle, registered)
//
//   Supports valid/ready backpressure at each stage boundary.
//   Latches configuration on pp_start. Tracks tile completion.
//   Sticky exception counters per tile.
//
// Spec Reference: spec/postprocess_numeric_spec.md Section 4.2
//------------------------------------------------------------------------------

`ifndef POSTPROC_SV
`define POSTPROC_SV

module postproc #(
    parameter int P_M    = 2,
    parameter int P_N    = 2,
    parameter int ELEM_W = 16,
    parameter int ACC_W  = 32,
    parameter int LANES  = P_M * P_N
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // System control --------------------------------------------------------
    input  wire                  pp_start,      // tile start pulse
    output reg                   pp_busy,
    output reg                   pp_done,        // tile complete pulse
    output reg                   pp_err,         // protocol error

    // Configuration (latched on pp_start) -----------------------------------
    input  wire                  add_c_en,       // 1=enable C fusion
    input  wire [1:0]            round_mode,     // 00=RNE,01=RTZ,10=RUP,11=RDN
    input  wire                  sat_en,         // 1=saturate overflow
    input  wire [LANES-1:0]      tile_mask,      // per-lane valid mask

    // Upstream from systolic_core -------------------------------------------
    input  wire                  acc_valid,
    input  wire [LANES*ACC_W-1:0] acc_data,
    input  wire                  acc_last,

    // Upstream C tile from c_loader -----------------------------------------
    input  wire                  c_valid,
    output wire                  c_ready,
    input  wire [LANES*ELEM_W-1:0] c_data,
    input  wire                  c_last,

    // Downstream to d_storer ------------------------------------------------
    output wire                  d_valid,
    input  wire                  d_ready,
    output wire [LANES*ELEM_W-1:0] d_data,
    output wire                  d_last,
    output wire [LANES-1:0]      d_mask,

    // Exception counters (sticky, cleared on rst_n) -------------------------
    output reg  [15:0]           exc_nan_cnt,
    output reg  [15:0]           exc_inf_cnt,
    output reg  [15:0]           exc_ovf_cnt,
    output reg  [15:0]           exc_udf_cnt,
    output reg  [15:0]           exc_denorm_cnt
);

    //------------------------------------------------------------------------
    // Configuration latch
    //------------------------------------------------------------------------
    reg                  add_c_en_r;
    reg [1:0]            round_mode_r;
    reg                  sat_en_r;
    reg [LANES-1:0]      tile_mask_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            add_c_en_r   <= 1'b0;
            round_mode_r <= 2'b00;
            sat_en_r     <= 1'b1;
            tile_mask_r  <= {LANES{1'b1}};
        end else if (pp_start) begin
            add_c_en_r   <= add_c_en;
            round_mode_r <= round_mode;
            sat_en_r     <= sat_en;
            tile_mask_r  <= tile_mask;
        end
    end

    //------------------------------------------------------------------------
    // C tile alignment buffer
    //------------------------------------------------------------------------
    reg [LANES*ELEM_W-1:0] c_buf_data;
    reg                    c_buf_valid;
    reg                    c_buf_last;

    assign c_ready = !c_buf_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_buf_valid <= 1'b0;
            c_buf_last  <= 1'b0;
        end else begin
            if (c_valid && c_ready) begin
                c_buf_data <= c_data;
                c_buf_valid <= 1'b1;
                c_buf_last  <= c_last;
            end else if (s0_advance && add_c_en_r && (c_buf_valid || c_valid)) begin
                c_buf_valid <= 1'b0;
            end
        end
    end

    wire c_needed       = add_c_en_r;
    wire c_available    = !c_needed || c_buf_valid || c_valid;
    wire [LANES*ELEM_W-1:0] c_sync_data = c_buf_valid ? c_buf_data : c_data;
    wire c_sync_last    = c_buf_valid ? c_buf_last : c_last;
    wire c_sync_valid   = c_needed && (c_buf_valid || c_valid);

    //------------------------------------------------------------------------
    // Stage0: alignment register
    //------------------------------------------------------------------------
    reg [LANES*ACC_W-1:0] s0_data;
    reg                   s0_valid;
    reg                   s0_last;
    wire                  s0_ready;

    wire s0_advance = acc_valid && c_available && s0_ready;

    assign s0_ready = !s0_valid || fp_add_c_in_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_valid <= 1'b0;
            s0_data  <= '0;
            s0_last  <= 1'b0;
        end else if (s0_ready) begin
            s0_valid <= s0_advance;
            if (s0_advance) begin
                s0_data <= acc_data;
                s0_last <= acc_last;
            end
        end
    end

    //------------------------------------------------------------------------
    // Stage1: fp_add_c instance
    //------------------------------------------------------------------------
    wire [LANES*ACC_W-1:0] s1_data;
    wire                   s1_valid;
    wire                   s1_last;
    wire [LANES-1:0]       s1_add_exc;
    wire                   fp_add_c_in_ready;

    fp_add_c #(
        .ACC_W  (ACC_W),
        .ELEM_W (ELEM_W),
        .LANES  (LANES)
    ) u_fp_add_c (
        .clk        (clk),
        .rst_n      (rst_n),
        .out_ready  (fp_round_sat_in_ready),
        .in_ready   (fp_add_c_in_ready),
        .add_en     (add_c_en_r),
        .lane_mask  (tile_mask_r),
        .x_valid    (s0_valid),
        .x_data     (s0_data),
        .x_last     (s0_last),
        .c_valid    (c_sync_valid),
        .c_data     (c_sync_data),
        .y_valid    (s1_valid),
        .y_data     (s1_data),
        .y_last     (s1_last),
        .add_exc    (s1_add_exc)
    );

    //------------------------------------------------------------------------
    // Stage2: fp_round_sat instance
    //------------------------------------------------------------------------
    wire [LANES*ELEM_W-1:0] s2_data;
    wire                    s2_valid;
    wire                    s2_last;
    wire [LANES*5-1:0]      s2_exc_flags;
    wire                    fp_round_sat_in_ready;

    fp_round_sat #(
        .ACC_W  (ACC_W),
        .ELEM_W (ELEM_W),
        .LANES  (LANES)
    ) u_fp_round_sat (
        .clk        (clk),
        .rst_n      (rst_n),
        .out_ready  (d_ready),
        .in_ready   (fp_round_sat_in_ready),
        .round_mode (round_mode_r),
        .sat_en     (sat_en_r),
        .lane_mask  (tile_mask_r),
        .in_valid   (s1_valid),
        .in_data    (s1_data),
        .in_last    (s1_last),
        .out_valid  (s2_valid),
        .out_data   (s2_data),
        .out_last   (s2_last),
        .exc_flags  (s2_exc_flags)
    );

    //------------------------------------------------------------------------
    // Output assignment
    //------------------------------------------------------------------------
    assign d_valid = s2_valid;
    assign d_data  = s2_data;
    assign d_last  = s2_last;
    assign d_mask  = tile_mask_r;

    //------------------------------------------------------------------------
    // Exception counting (on d_valid && d_ready)
    //------------------------------------------------------------------------
    logic [LANES-1:0] nan_vec;
    logic [LANES-1:0] inf_vec;
    logic [LANES-1:0] ovf_vec;
    logic [LANES-1:0] udf_vec;
    logic [LANES-1:0] denorm_vec;

    genvar gi;
    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : g_exc_vec
            always_comb begin
                nan_vec[gi]    = s2_exc_flags[gi*5 + 4];
                inf_vec[gi]    = s2_exc_flags[gi*5 + 3];
                ovf_vec[gi]    = s2_exc_flags[gi*5 + 2];
                udf_vec[gi]    = s2_exc_flags[gi*5 + 1];
                denorm_vec[gi] = s2_exc_flags[gi*5 + 0];
            end
        end
    endgenerate

    wire exc_update = d_valid && d_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exc_nan_cnt    <= '0;
            exc_inf_cnt    <= '0;
            exc_ovf_cnt    <= '0;
            exc_udf_cnt    <= '0;
            exc_denorm_cnt <= '0;
        end else if (exc_update) begin
            if (|nan_vec)    exc_nan_cnt    <= exc_nan_cnt    + 1'b1;
            if (|inf_vec)    exc_inf_cnt    <= exc_inf_cnt    + 1'b1;
            if (|ovf_vec)    exc_ovf_cnt    <= exc_ovf_cnt    + 1'b1;
            if (|udf_vec)    exc_udf_cnt    <= exc_udf_cnt    + 1'b1;
            if (|denorm_vec) exc_denorm_cnt <= exc_denorm_cnt + 1'b1;
        end
    end

    //------------------------------------------------------------------------
    // State machine: IDLE / ALIGN / FLUSH / DONE
    //------------------------------------------------------------------------
    typedef enum logic [2:0] {
        IDLE,
        ALIGN,
        FLUSH,
        DONE
    } state_t;

    state_t state, next_state;
    reg tile_last_captured;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            tile_last_captured <= 1'b0;
            pp_busy <= 1'b0;
            pp_done <= 1'b0;
            pp_err  <= 1'b0;
        end else begin
            state <= next_state;
            pp_done <= 1'b0;
            pp_err  <= 1'b0;

            case (state)
                IDLE: begin
                    if (pp_start) begin
                        pp_busy <= 1'b1;
                        tile_last_captured <= 1'b0;
                    end
                end

                ALIGN: begin
                    if (s0_advance) begin
                        if (acc_last) begin
                            tile_last_captured <= 1'b1;
                        end
                        // Protocol check: if this is last acc beat, c must also be last
                        if (acc_last && add_c_en_r && c_needed && !c_sync_last) begin
                            pp_err <= 1'b1;
                        end
                    end
                end

                FLUSH: begin
                    if (d_valid && d_last && d_ready) begin
                        tile_last_captured <= 1'b0;
                    end
                end

                DONE: begin
                    pp_busy <= 1'b0;
                    pp_done <= 1'b1;
                end

                default: ;
            endcase
        end
    end

    always_comb begin
        next_state = state;
        case (state)
            IDLE:  if (pp_start)            next_state = ALIGN;
            ALIGN: if (s0_advance && acc_last) next_state = FLUSH;
            FLUSH: if (d_valid && d_last && d_ready) next_state = DONE;
            DONE:  next_state = IDLE;
            default: next_state = IDLE;
        endcase
    end

endmodule : postproc

`endif // POSTPROC_SV
