//------------------------------------------------------------------------------
// rd_addr_gen.sv
// GEMM Read Address Generator - 2D Tile to Linear Burst Commands
//
// Description:
//   Converts a 2D tile (rows x cols) into a sequence of AXI burst commands.
//   Handles 4KB boundary splitting and max burst length clipping.
//   Bytes per beat = AXI_DATA_W / 8.
//------------------------------------------------------------------------------
`ifndef RD_ADDR_GEN_SV
`define RD_ADDR_GEN_SV

module rd_addr_gen #(
    parameter int ADDR_W       = 64,
    parameter int DIM_W        = 16,
    parameter int STRIDE_W     = 32,
    parameter int AXI_DATA_W   = 256,
    parameter int MAX_BURST_LEN= 16
)(
    input  wire              clk,
    input  wire              rst_n,

    input  wire              start,
    input  wire [ADDR_W-1:0] base_addr,
    input  wire [DIM_W-1:0]  rows,
    input  wire [DIM_W-1:0]  cols,
    input  wire [STRIDE_W-1:0] stride,
    input  wire [2:0]        elem_bytes,  // FP16=2

    output reg               cmd_valid,
    input  wire              cmd_ready,
    output reg  [ADDR_W-1:0] cmd_addr,
    output reg  [7:0]        cmd_len,     // ARLEN = beats-1
    output reg  [15:0]       cmd_bytes,   // valid bytes in this burst
    output reg               cmd_last     // last burst of this tile
);

    localparam int BEAT_BYTES = AXI_DATA_W / 8;
    localparam int BEAT_CNT_W = $clog2(MAX_BURST_LEN);

    typedef enum logic [2:0] {
        IDLE,
        CALC,
        EMIT,
        NEXT_ROW,
        DONE
    } state_t;

    state_t state, next_state;

    reg [DIM_W-1:0]    row_cnt;
    reg [STRIDE_W-1:0] col_rem;      // bytes remaining in current row
    reg [ADDR_W-1:0]   cur_addr;
    reg [15:0]         burst_cnt;

    // Combinational calc wires
    wire [ADDR_W-1:0] addr_4k_boundary;
    wire [15:0]       max_to_4k;
    wire [15:0]       max_burst_bytes;
    wire [15:0]       this_burst;
    wire [BEAT_CNT_W:0] beats;

    assign addr_4k_boundary = (cur_addr | 12'hFFF) + 1'b1;
    assign max_to_4k        = addr_4k_boundary - cur_addr;
    assign max_burst_bytes  = MAX_BURST_LEN * BEAT_BYTES;
    assign this_burst       = (col_rem < max_to_4k) ? col_rem : max_to_4k;
    assign beats            = (this_burst + BEAT_BYTES - 1) / BEAT_BYTES;

    // Next state
    always_comb begin
        next_state = state;
        case (state)
            IDLE:      if (start)              next_state = CALC;
            CALC:                               next_state = EMIT;
            EMIT:      if (cmd_ready) begin
                           if (col_rem == 0 && row_cnt == rows-1) next_state = DONE;
                           else if (col_rem == 0)                 next_state = NEXT_ROW;
                           else                                   next_state = CALC;
                       end
            NEXT_ROW:                          next_state = CALC;
            DONE:                              next_state = IDLE;
            default:   next_state = IDLE;
        endcase
    end

    // Row/col tracking
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            row_cnt   <= '0;
            col_rem   <= '0;
            cur_addr  <= '0;
            burst_cnt <= '0;
        end else begin
            state <= next_state;
            case (state)
                IDLE: begin
                    if (start) begin
                        row_cnt   <= '0;
                        burst_cnt <= '0;
                        cur_addr  <= base_addr;
                        col_rem   <= cols * elem_bytes;
                    end
                end
                EMIT: begin
                    if (cmd_ready) begin
                        burst_cnt <= burst_cnt + 1'b1;
                        if (col_rem != 0) begin
                            cur_addr <= cur_addr + cmd_bytes;
                            col_rem  <= col_rem - cmd_bytes;
                        end
                    end
                end
                NEXT_ROW: begin
                    row_cnt  <= row_cnt + 1'b1;
                    cur_addr <= base_addr + (row_cnt + 1'b1) * stride;
                    col_rem  <= cols * elem_bytes;
                end
            endcase
        end
    end

    // Combinational burst outputs
    always_comb begin
        cmd_valid = 1'b0;
        cmd_addr  = cur_addr;
        cmd_len   = 8'd0;
        cmd_bytes = 16'd0;
        cmd_last  = 1'b0;

        if (state == CALC || state == EMIT) begin
            cmd_valid = 1'b1;
            cmd_addr  = cur_addr;
            cmd_len   = (beats > MAX_BURST_LEN) ? MAX_BURST_LEN - 1 : beats - 1;
            cmd_bytes = (beats == 0) ? BEAT_BYTES[15:0] :
                        (beats > MAX_BURST_LEN) ? MAX_BURST_LEN * BEAT_BYTES :
                        this_burst;
            cmd_last  = (col_rem <= ((beats > MAX_BURST_LEN) ? MAX_BURST_LEN * BEAT_BYTES : this_burst))
                        && (row_cnt == rows-1);
        end
    end

endmodule : rd_addr_gen
`endif // RD_ADDR_GEN_SV
