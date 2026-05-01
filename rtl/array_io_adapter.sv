//------------------------------------------------------------------------------
// array_io_adapter.sv
// Systolic Array IO Adapter with Skew Delay
//
// Description:
//   Converts buffer-side flat vectors into skewed systolic injection vectors.
//   A row i is delayed by i cycles; B column j is delayed by j cycles.
//   This matches the systolic wavefront so A[i][k] and B[k][j] arrive at
//   PE[i][j] in the same cycle.
//
//   MVP simplifications:
//   - Global valid (no per-row/per-col valid skew)
//   - a_vec_mask / b_vec_mask driven all-1s (tile_mask_cfg handles masking)
//   - issue_ready always high
//
// Spec Reference: spec/systolic_compute_core_spec.md Section 4.4, 7.8
//------------------------------------------------------------------------------

`ifndef ARRAY_IO_ADAPTER_SV
`define ARRAY_IO_ADAPTER_SV

module array_io_adapter #(
    parameter int P_M    = 2,
    parameter int P_N    = 2,
    parameter int ELEM_W = 16
)(
    input  wire              clk,
    input  wire              rst_n,

    // Buffer-side interface -------------------------------------------------
    input  wire [P_M*ELEM_W-1:0] buf_a_data,
    input  wire [P_N*ELEM_W-1:0] buf_b_data,
    input  wire              issue_valid,
    input  wire [P_M*P_N-1:0] mask_cfg,      // per-PE mask (for reference)

    // Core-side interface ---------------------------------------------------
    output reg               a_vec_valid,
    output reg  [P_M*ELEM_W-1:0] a_vec_data,
    output reg  [P_M-1:0]    a_vec_mask,
    output reg               b_vec_valid,
    output reg  [P_N*ELEM_W-1:0] b_vec_data,
    output reg  [P_N-1:0]    b_vec_mask,
    output wire              issue_ready
);

    // Skew shift registers --------------------------------------------------
    // A: a_skew[row][stage]  -- row i delayed by i stages
    logic [ELEM_W-1:0] a_skew [0:P_M-1][0:P_M-1];
    // B: b_skew[col][stage]  -- col j delayed by j stages
    logic [ELEM_W-1:0] b_skew [0:P_N-1][0:P_N-1];

    // Valid pipeline (track issue_valid through max skew depth)
    localparam int MAX_SKEW = (P_M > P_N) ? P_M : P_N;
    logic [MAX_SKEW-1:0] v_pipe;

    // Sequential: shift registers
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < P_M; i++) begin
                for (int d = 0; d < P_M; d++) begin
                    a_skew[i][d] <= '0;
                end
            end
            for (int j = 0; j < P_N; j++) begin
                for (int d = 0; d < P_N; d++) begin
                    b_skew[j][d] <= '0;
                end
            end
            v_pipe <= '0;
        end else begin
            // Valid pipe
            v_pipe <= {v_pipe[MAX_SKEW-2:0], issue_valid};

            // A skew
            for (int i = 0; i < P_M; i++) begin
                a_skew[i][0] <= buf_a_data[i*ELEM_W +: ELEM_W];
                for (int d = 1; d < P_M; d++) begin
                    a_skew[i][d] <= a_skew[i][d-1];
                end
            end

            // B skew
            for (int j = 0; j < P_N; j++) begin
                b_skew[j][0] <= buf_b_data[j*ELEM_W +: ELEM_W];
                for (int d = 1; d < P_N; d++) begin
                    b_skew[j][d] <= b_skew[j][d-1];
                end
            end
        end
    end

    // Combinational output: pick skewed stage --------------------------------
    always_comb begin
        for (int i = 0; i < P_M; i++) begin
            a_vec_data[i*ELEM_W +: ELEM_W] = a_skew[i][i];
        end
        for (int j = 0; j < P_N; j++) begin
            b_vec_data[j*ELEM_W +: ELEM_W] = b_skew[j][j];
        end
    end

    // Valid: global, delayed by max(P_M,P_N)-1? No -- in MVP we keep it
    // aligned with the earliest row/col (stage 0). The fill/drain in
    // systolic_core absorbs the wavefront propagation.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_vec_valid <= 1'b0;
            b_vec_valid <= 1'b0;
        end else begin
            a_vec_valid <= issue_valid;
            b_vec_valid <= issue_valid;
        end
    end

    // Mask: all-ones in MVP (tile_mask_cfg in systolic_core handles per-PE)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_vec_mask <= '0;
            b_vec_mask <= '0;
        end else begin
            a_vec_mask <= {P_M{1'b1}};
            b_vec_mask <= {P_N{1'b1}};
        end
    end

    // Ready: MVP always ready
    assign issue_ready = 1'b1;

endmodule : array_io_adapter

`endif // ARRAY_IO_ADAPTER_SV
