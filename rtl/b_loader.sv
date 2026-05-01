//------------------------------------------------------------------------------
// b_loader.sv
// B Tile Loader with Column-Major Reorder
//
// Description:
//   Receives DMA read data stream and writes B tile to buffer_bank
//   in column-major order to match systolic_core column injection.
//
// Spec Reference: spec/onchip_buffer_reorder_spec.md Section 4.4
//------------------------------------------------------------------------------

`ifndef B_LOADER_SV
`define B_LOADER_SV

module b_loader #(
    parameter int P_M         = 2,
    parameter int P_N         = 2,
    parameter int ELEM_W      = 16,
    parameter int BUF_BANKS   = 4,
    parameter int BUF_DEPTH   = 512,
    parameter int AXI_DATA_W  = 256
)(
    input  wire              clk,
    input  wire              rst_n,

    // DMA interface --------------------------------------------------------
    input  wire              dma_valid,
    output wire              dma_ready,
    input  wire [AXI_DATA_W-1:0]        dma_data,
    input  wire              dma_last,

    // Tile configuration ---------------------------------------------------
    input  wire [15:0]       tile_rows,      // Tk
    input  wire [15:0]       tile_cols,      // Tn
    input  wire [31:0]       tile_stride,    // bytes per column in source matrix
    input  wire [31:0]       base_addr,
    input  wire              pp_sel,

    // Buffer write interface -----------------------------------------------
    output reg               buf_wr_valid,
    input  wire              buf_wr_ready,
    output reg  [2:0]        buf_wr_sel,
    output reg  [$clog2(BUF_BANKS)-1:0] buf_wr_bank,
    output reg  [$clog2(BUF_DEPTH)-1:0] buf_wr_addr,
    output reg  [AXI_DATA_W-1:0]        buf_wr_data,
    output reg  [AXI_DATA_W/8-1:0]      buf_wr_mask,

    // Status ---------------------------------------------------------------
    output reg               load_done,
    output reg               load_err
);

    localparam int BEAT_BYTES    = AXI_DATA_W / 8;
    localparam int ELEM_BYTES    = ELEM_W / 8;
    localparam int ELEM_PER_BEAT = AXI_DATA_W / ELEM_W;

    // Counters track the NEXT beat to be received
    reg [15:0] row_cnt;
    reg [15:0] col_cnt;

    // Saved state for the beat currently in beat_buffer
    reg [15:0] wr_row;
    reg [15:0] wr_col;
    reg [AXI_DATA_W-1:0]   beat_buffer;
    reg                    beat_valid;

    // Address calculation for counters (next beat)
    wire [31:0] next_byte_addr;
    wire [31:0] next_beat_idx;
    assign next_byte_addr = base_addr + col_cnt * tile_stride + row_cnt * ELEM_BYTES;
    assign next_beat_idx  = next_byte_addr / BEAT_BYTES;

    // Address calculation for saved beat (current beat in buffer)
    wire [31:0] wr_byte_addr;
    wire [31:0] wr_beat_idx;
    wire [$clog2(BUF_BANKS)-1:0] wr_bank_calc;
    wire [$clog2(BUF_DEPTH)-1:0] wr_addr_calc;
    assign wr_byte_addr = base_addr + wr_col * tile_stride + wr_row * ELEM_BYTES;
    assign wr_beat_idx  = wr_byte_addr / BEAT_BYTES;
    assign wr_bank_calc = wr_beat_idx % BUF_BANKS;
    assign wr_addr_calc = wr_beat_idx / BUF_BANKS;

    // Mask generation for saved beat (combinational)
    reg [AXI_DATA_W/8-1:0] mask_calc;
    always_comb begin
        mask_calc = '0;
        for (int e = 0; e < ELEM_PER_BEAT; e++) begin
            if ((wr_row + e) < tile_rows && wr_col < tile_cols) begin
                mask_calc[e*ELEM_BYTES +: ELEM_BYTES] = {ELEM_BYTES{1'b1}};
            end
        end
    end

    // DMA ready: can accept if buffer empty or can drain in same cycle
    assign dma_ready = !beat_valid || buf_wr_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_cnt      <= '0;
            col_cnt      <= '0;
            wr_row       <= '0;
            wr_col       <= '0;
            beat_buffer  <= '0;
            beat_valid   <= 1'b0;
            buf_wr_valid <= 1'b0;
            buf_wr_sel   <= '0;
            buf_wr_bank  <= '0;
            buf_wr_addr  <= '0;
            buf_wr_data  <= '0;
            buf_wr_mask  <= '0;
            load_done    <= 1'b0;
            load_err     <= 1'b0;
        end else begin
            load_done <= 1'b0;
            load_err  <= 1'b0;
            buf_wr_valid <= 1'b0;

            // Stage 2: Write beat_buffer to buffer_bank
            if (beat_valid && buf_wr_ready) begin
                buf_wr_valid <= 1'b1;
                buf_wr_sel   <= pp_sel ? 3'd3 : 3'd2;
                buf_wr_bank  <= wr_bank_calc;
                buf_wr_addr  <= wr_addr_calc;
                buf_wr_data  <= beat_buffer;
                buf_wr_mask  <= mask_calc;
                beat_valid   <= 1'b0;
            end

            // Stage 1: Accept DMA beat
            if (dma_valid && dma_ready) begin
                beat_buffer <= dma_data;
                beat_valid  <= 1'b1;
                wr_row      <= row_cnt;
                wr_col      <= col_cnt;

                // Update counters for next beat (column-major order)
                if (row_cnt + ELEM_PER_BEAT >= tile_rows) begin
                    row_cnt <= '0;
                    if (col_cnt + 1 >= tile_cols) begin
                        col_cnt <= '0;
                    end else begin
                        col_cnt <= col_cnt + 1;
                    end
                end else begin
                    row_cnt <= row_cnt + ELEM_PER_BEAT;
                end

                if (dma_last) begin
                    load_done <= 1'b1;
                end
            end
        end
    end

endmodule : b_loader

`endif // B_LOADER_SV
