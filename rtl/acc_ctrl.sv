//------------------------------------------------------------------------------
// acc_ctrl.sv
// Accumulator Control for Systolic Array
//
// Description:
//   Standalone accumulator lifecycle controller per tile_scheduler spec.
//   Manages acc_clear (k-chunk start), acc_hold (freeze), acc_commit
//   (result latch), and tile_done signaling.
//
//   Can be instantiated inside systolic_core or used standalone.
//
// Spec Reference: spec/systolic_compute_core_spec.md Section 4.3, 7.5
//------------------------------------------------------------------------------

`ifndef ACC_CTRL_SV
`define ACC_CTRL_SV

module acc_ctrl #(
    parameter int K_MAX = 4096
)(
    input  wire  clk,
    input  wire  rst_n,

    // Control inputs from scheduler / core FSM -----------------------------
    input  wire  tile_start,       // tile launch pulse
    input  wire  k_chunk_start,    // k0-chunk boundary (trigger clear)
    input  wire  k_chunk_last,     // last k-chunk of tile
    input  wire  drain_done,       // drain/wavefront flush complete
    input  wire  compute_busy,     // core is computing (for protocol check)

    // Outputs broadcast to PE array -----------------------------------------
    output reg   acc_clear,        // clear accumulators
    output reg   acc_hold,         // freeze accumulators
    output reg   acc_commit,       // latch / present results
    output reg   tile_done         // tile complete pulse
);

    typedef enum logic [2:0] {
        ACC_IDLE,
        ACC_CLEAR,
        ACC_COMPUTE,
        ACC_DRAIN,
        ACC_COMMIT,
        ACC_DONE
    } acc_state_t;

    acc_state_t state, next_state;

    reg [15:0] k_cnt;

    // Sequential
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ACC_IDLE;
            k_cnt     <= '0;
            acc_clear <= 1'b0;
            acc_hold  <= 1'b0;
            acc_commit<= 1'b0;
            tile_done <= 1'b0;
        end else begin
            state     <= next_state;
            tile_done <= 1'b0;   // pulse
            acc_commit<= 1'b0;   // pulse

            case (state)
                ACC_IDLE: begin
                    if (tile_start) begin
                        k_cnt <= '0;
                    end
                end
                ACC_CLEAR: begin
                    // hold: acc_clear driven combinationally
                end
                ACC_COMPUTE: begin
                    k_cnt <= k_cnt + 1'b1;
                end
                ACC_DRAIN: begin
                    k_cnt <= k_cnt + 1'b1;
                end
                ACC_COMMIT: begin
                    acc_commit <= 1'b1;
                end
                ACC_DONE: begin
                    tile_done <= 1'b1;
                end
                default: ;
            endcase
        end
    end

    // Next-state
    always_comb begin
        next_state = state;
        case (state)
            ACC_IDLE:    if (tile_start)          next_state = ACC_CLEAR;
            ACC_CLEAR:   next_state = ACC_COMPUTE;
            ACC_COMPUTE: if (k_chunk_last)         next_state = ACC_DRAIN;
            ACC_DRAIN:   if (drain_done)           next_state = ACC_COMMIT;
            ACC_COMMIT:  next_state = ACC_DONE;
            ACC_DONE:    next_state = ACC_IDLE;
            default:     next_state = ACC_IDLE;
        endcase
    end

    // Combinational outputs
    always_comb begin
        acc_clear = 1'b0;
        acc_hold  = 1'b0;
        case (state)
            ACC_CLEAR:   acc_clear = 1'b1;
            ACC_COMPUTE: acc_hold  = 1'b0;
            ACC_DRAIN:   acc_hold  = 1'b1;   // freeze during drain
            ACC_COMMIT:  acc_hold  = 1'b1;   // hold during readout
            ACC_DONE:    acc_hold  = 1'b1;
            default: ;
        endcase
    end

    // Protocol error: tile_start while compute_busy asserted
    // (Not latched here; err_checker handles aggregation)

endmodule : acc_ctrl

`endif // ACC_CTRL_SV
