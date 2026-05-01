//------------------------------------------------------------------------------
// a_loader.sv
// A Tile Loader with Row-Major Reorder
//
// Description:
//   Receives DMA read data stream and writes A tile to buffer_bank
//   in row-major order to match systolic_core row injection.
//
// Spec Reference: spec/onchip_buffer_reorder_spec.md Section 4.3
//------------------------------------------------------------------------------

`ifndef A_LOADER_SV
`define A_LOADER_SV

module a_loader #(
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
    input  wire [15:0]       tile_rows,      // Tm
    input  wire [15:0]       tile_cols,      // Tk
    input  wire [31:0]       tile_stride,    // bytes per row in source matrix
    input  wire [31:0]       base_addr,      // byte offset in buffer
    input  wire              pp_sel,         // 0=A_BUF[0], 1=A_BUF[1]

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

    // Counters
    reg [15:0] row_cnt;
    reg [15:0] col_cnt;
    reg [31:0] elem_byte_addr;

    // Internal buffer for a beat of elements
    reg [AXI_DATA_W-1:0]   beat_buffer;
    reg                      beat_valid;

    // Address mapping helpers
    wire [$clog2(BUF_BANKS)-1:0] bank_calc;
    wire [$clog2(BUF_DEPTH)-1:0] addr_calc;
    wire [31:0]                  beat_idx;

    // Row-major: elem_byte_addr = base_addr + row * stride + col * ELEM_BYTES
    // beat_idx = elem_byte_addr / BEAT_BYTES
    assign beat_idx  = elem_byte_addr / BEAT_BYTES;
    assign bank_calc   = beat_idx % BUF_BANKS;
    assign addr_calc   = beat_idx / BUF_BANKS;

    // Mask generation: mask valid elements in beat
    // Each element = ELEM_BYTES bytes
    // Number of elements per beat = AXI_DATA_W / ELEM_W
    localparam int ELEM_PER_BEAT = AXI_DATA_W / ELEM_W;

    // For simplicity: assume DMA delivers elements in beat order
    // and we write one beat per buffer write
    // Boundary mask: if row >= tile_rows, mask all; if col + elem_idx >= tile_cols, mask partial

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_cnt        <= '0;
            col_cnt        <= '0;
            elem_byte_addr <= '0;
            beat_buffer    <= '0;
            beat_valid     <= 1'b0;
            dma_ready      <= 1'b1;
            buf_wr_valid   <= 1'b0;
            buf_wr_sel     <= pp_sel;  // 0 or 1 for A_BUF
            buf_wr_bank    <= '0;
            buf_wr_addr    <= '0;
            buf_wr_data    <= '0;
            buf_wr_mask    <= '0;
            load_done      <= 1'b0;
            load_err       <= 1'b0;
        end else begin
            load_done <= 1'b0;  // pulse
            load_err  <= 1'b0;

            if (dma_valid && dma_ready) begin
                // Accept DMA beat
                beat_buffer <= dma_data;
                beat_valid  <= 1'b1;

                // Update counters for next beat
                if (col_cnt + ELEM_PER_BEAT >= tile_cols) begin
                    // End of row
                    col_cnt <= '0;
                    if (row_cnt + 1 >= tile_rows) begin
                        // End of tile
                        row_cnt <= '0;
                    end else begin
                        row_cnt <= row_cnt + 1;
                    end
                end else begin
                    col_cnt <= col_cnt + ELEM_PER_BEAT;
                end
            end

            if (beat_valid && buf_wr_ready) begin
                // Write to buffer
                buf_wr_valid <= 1'b1;
                buf_wr_sel   <= pp_sel ? 3'd1 : 3'd0;  // A_BUF[pp_sel]
                buf_wr_bank  <= bank_calc;
                buf_wr_addr  <= addr_calc;
                buf_wr_data  <= beat_buffer;

                // Generate mask for boundary elements
                // Each bit in mask corresponds to one byte
                buf_wr_mask <= '0;  // default all masked
                for (int e = 0; e < ELEM_PER_BEAT; e++) begin
                    if ((col_cnt + e) < tile_cols && row_cnt < tile_rows) begin
                        for (int b = 0; b < ELEM_BYTES; b++) begin
                            buf_wr_mask[e*ELEM_BYTES + b] <= 1'b1;
                        end
                    end
                end

                beat_valid <= 1'b0;

                // Check if this was the last beat
                if (dma_last && !dma_valid) begin
                    load_done <= 1'b1;
                end
            end else begin
                buf_wr_valid <= 1'b0;
            end

            // Calculate next element address based on current counters
            elem_byte_addr <= base_addr + row_cnt * tile_stride + col_cnt * ELEM_BYTES;

            // Error detection
            if (row_cnt >= tile_rows && dma_valid) begin
                load_err <= 1'b1;
            end
        end
    end

endmodule : a_loader

`endif // A_LOADER_SV
