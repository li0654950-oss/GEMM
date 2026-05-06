//------------------------------------------------------------------------------
// trace_debug_if.sv
// GEMM Trace Debug Interface (Optional)
//
// Description:
//   128-bit trace packet export with 256-entry FIFO.
//   Packet: {timestamp[63:0], fsm_state[7:0], tile_m[7:0], tile_n[7:0],
//            tile_k[7:0], stall_code[7:0], event_type[7:0], reserved[15:0]}
//------------------------------------------------------------------------------
`ifndef TRACE_DEBUG_IF_SV
`define TRACE_DEBUG_IF_SV

module trace_debug_if #(
    parameter int TRACE_W        = 128,
    parameter int TRACE_FIFO_DEPTH = 256,
    parameter int TILE_W         = 16
)(
    input  wire              clk,
    input  wire              rst_n,

    input  wire              trace_en,
    input  wire              trace_freeze,
    input  wire              trace_clr,

    input  wire [7:0]        fsm_state,
    input  wire [TILE_W-1:0] tile_idx_m,
    input  wire [TILE_W-1:0] tile_idx_n,
    input  wire [TILE_W-1:0] tile_idx_k,
    input  wire [7:0]        stall_code,
    input  wire [63:0]       timestamp,
    input  wire              event_valid,

    output reg               trace_valid,
    input  wire              trace_ready,
    output reg  [TRACE_W-1:0] trace_data,
    output reg               trace_overflow,
    output reg  [$clog2(TRACE_FIFO_DEPTH):0] trace_level
);

    localparam int PTR_W = $clog2(TRACE_FIFO_DEPTH);

    reg [TRACE_W-1:0] fifo [0:TRACE_FIFO_DEPTH-1];
    reg [PTR_W:0]       wr_ptr;
    reg [PTR_W:0]       rd_ptr;
    wire [PTR_W:0]      fifo_cnt = wr_ptr - rd_ptr;
    wire                fifo_full  = (fifo_cnt >= TRACE_FIFO_DEPTH);
    wire                fifo_empty = (fifo_cnt == 0);

    reg [63:0] time_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr        <= '0;
            rd_ptr        <= '0;
            trace_valid   <= 1'b0;
            trace_overflow<= 1'b0;
            trace_level   <= '0;
            time_cnt      <= '0;
        end else begin
            time_cnt <= time_cnt + 1'b1;
            trace_valid <= 1'b0;

            if (trace_clr) begin
                wr_ptr <= '0;
                rd_ptr <= '0;
                trace_overflow <= 1'b0;
            end

            // Write
            if (trace_en && !trace_freeze && event_valid) begin
                if (!fifo_full) begin
                    fifo[wr_ptr[PTR_W-1:0]] <= {
                        time_cnt,
                        fsm_state,
                        tile_idx_m[7:0],
                        tile_idx_n[7:0],
                        tile_idx_k[7:0],
                        stall_code,
                        8'h00, // event_type placeholder
                        16'h0000
                    };
                    wr_ptr <= wr_ptr + 1'b1;
                end else begin
                    trace_overflow <= 1'b1;
                end
            end

            // Read
            if (!fifo_empty && trace_ready) begin
                trace_data  <= fifo[rd_ptr[PTR_W-1:0]];
                trace_valid <= 1'b1;
                rd_ptr      <= rd_ptr + 1'b1;
            end

            trace_level <= fifo_cnt[PTR_W:0];
        end
    end

endmodule : trace_debug_if
`endif // TRACE_DEBUG_IF_SV
