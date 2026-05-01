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
    output reg               dma_ready,
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

    localparam int BEAT_BYTES = AXI_DATA_W / 8;
    localparam int ELEM_BYTES = ELEM_W / 8;
    localparam int ELEM_PER_BEAT = AXI_DATA_W / ELEM_W;

    reg [15:0] row_cnt;  // 0..Tk-1
    reg [15:0] col_cnt;  // 0..Tn-1
    reg [31:0] elem_byte_addr;

    reg [AXI_DATA_W-1:0]   beat_buffer;
    reg                      beat_valid;

    wire [$clog2(BUF_BANKS)-1:0] bank_calc;
    wire [$clog2(BUF_DEPTH)-1:0] addr_calc;
    wire [31:0]                  beat_idx;

    // Column-major: elem_byte_addr = base_addr + col * stride + row * ELEM_BYTES
    assign beat_idx  = elem_byte_addr / BEAT_BYTES;
    assign bank_calc   = beat_idx % BUF_BANKS;
    assign addr_calc   = beat_idx / BUF_BANKS;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_cnt        <= '0;
            col_cnt        <= '0;
            elem_byte_addr <= '0;
            beat_buffer    <= '0;
            beat_valid     <= 1'b0;
            dma_ready      <= 1'b1;
            buf_wr_valid   <= 1'b0;
            buf_wr_sel     <= pp_sel ? 3'd3 : 3'd2;  // B_BUF[pp_sel]
            buf_wr_bank    <= '0;
            buf_wr_addr    <= '0;
            buf_wr_data    <= '0;
            buf_wr_mask    <= '0;
            load_done      <= 1'b0;
            load_err       <= 1'b0;
        end else begin
            load_done <= 1'b0;
            load_err  <= 1'b0;

            if (dma_valid && dma_ready) begin
                beat_buffer <= dma_data;
                beat_valid  <= 1'b1;

                // Update counters for next beat (column-major order)
                if (row_cnt + ELEM_PER_BEAT >= tile_rows) begin
                    // End of column
                    row_cnt <= '0;
                    if (col_cnt + 1 >= tile_cols) begin
                        col_cnt <= '0;
                    end else begin
                        col_cnt <= col_cnt + 1;
                    end
                end else begin
                    row_cnt <= row_cnt + ELEM_PER_BEAT;
                end
            end

            if (beat_valid && buf_wr_ready) begin
                buf_wr_valid <= 1'b1;
                buf_wr_sel   <= pp_sel ? 3'd3 : 3'd2;  // B_BUF[pp_sel]
                buf_wr_bank  <= bank_calc;
                buf_wr_addr  <= addr_calc;
                buf_wr_data  <= beat_buffer;

                // Mask generation
                buf_wr_mask <= '0;
                for (int e = 0; e < ELEM_PER_BEAT; e++) begin
                    if ((row_cnt + e) < tile_rows && col_cnt < tile_cols) begin
                        for (int b = 0; b < ELEM_BYTES; b++) begin
                            buf_wr_mask[e*ELEM_BYTES + b] <= 1'b1;
                        end
                    end
                end

                beat_valid <= 1'b0;

                if (dma_last && !dma_valid) begin
                    load_done <= 1'b1;
                end
            end else begin
                buf_wr_valid <= 1'b0;
            end

            elem_byte_addr <= base_addr + col_cnt * tile_stride + row_cnt * ELEM_BYTES;

            if (col_cnt >= tile_cols && dma_valid) begin
                load_err <= 1'b1;
            end
        end
    end

endmodule : b_loader

`endif // B_LOADER_SV
