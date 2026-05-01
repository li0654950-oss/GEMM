//------------------------------------------------------------------------------
// d_storer.sv
// D Tile Collector and AXI Beat Packer
//
// Description:
//   Collects postproc output (P_M*P_N FP16 elements per cycle) and packs
//   into AXI beat format for DMA writeback.
//
// Spec Reference: spec/onchip_buffer_reorder_spec.md Section 4.6
//------------------------------------------------------------------------------

`ifndef D_STORER_SV
`define D_STORER_SV

module d_storer #(
    parameter int P_M         = 2,
    parameter int P_N         = 2,
    parameter int ELEM_W      = 16,
    parameter int AXI_DATA_W  = 256
)(
    input  wire              clk,
    input  wire              rst_n,

    // Postproc interface ----------------------------------------------------
    input  wire              post_valid,
    output reg               post_ready,
    input  wire [P_M*P_N*ELEM_W-1:0]    post_data,
    input  wire              post_last,

    // Tile configuration ---------------------------------------------------
    input  wire [15:0]       tile_rows,
    input  wire [15:0]       tile_cols,
    input  wire [31:0]       tile_stride,
    input  wire [31:0]       base_addr,

    // DMA write interface --------------------------------------------------
    output reg               dma_wr_valid,
    input  wire              dma_wr_ready,
    output reg  [AXI_DATA_W-1:0]        dma_wr_data,
    output reg  [AXI_DATA_W/8-1:0]      dma_wr_strb,
    output reg               dma_wr_last,

    // Status ---------------------------------------------------------------
    output reg               store_done,
    output reg               store_err
);

    localparam int BEAT_BYTES    = AXI_DATA_W / 8;
    localparam int ELEM_BYTES    = ELEM_W / 8;
    localparam int ELEM_PER_BEAT = AXI_DATA_W / ELEM_W;

    // Internal state
    reg [15:0] row_cnt;
    reg [15:0] col_cnt;
    reg [31:0] elem_byte_addr;

    // Row buffer: collects elements until a full AXI beat is ready
    reg [AXI_DATA_W-1:0] row_buffer;
    reg [$clog2(ELEM_PER_BEAT):0] row_buffer_cnt;  // elements collected
    reg row_buffer_valid;

    // Address mapping
    wire [$clog2(ELEM_PER_BEAT)-1:0] beat_offset;
    assign beat_offset = (elem_byte_addr / ELEM_BYTES) % ELEM_PER_BEAT;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_cnt         <= '0;
            col_cnt         <= '0;
            elem_byte_addr  <= '0;
            row_buffer      <= '0;
            row_buffer_cnt  <= '0;
            row_buffer_valid<= 1'b0;
            post_ready      <= 1'b1;
            dma_wr_valid    <= 1'b0;
            dma_wr_data     <= '0;
            dma_wr_strb     <= '0;
            dma_wr_last     <= 1'b0;
            store_done      <= 1'b0;
            store_err       <= 1'b0;
        end else begin
            store_done <= 1'b0;
            store_err  <= 1'b0;

            if (post_valid && post_ready) begin
                // Accept postproc output (P_M*P_N elements)
                // Pack elements into row_buffer
                for (int r = 0; r < P_M; r++) begin
                    for (int c = 0; c < P_N; c++) begin
                        int elem_idx = r * P_N + c;
                        int global_col = col_cnt + c;
                        int global_row = row_cnt + r;
                        if (global_col < tile_cols && global_row < tile_rows) begin
                            int buf_idx = row_buffer_cnt + c;
                            if (buf_idx < ELEM_PER_BEAT) begin
                                row_buffer[buf_idx * ELEM_W +: ELEM_W] <= post_data[elem_idx * ELEM_W +: ELEM_W];
                            end
                        end
                    end
                end

                // Update counters
                if (col_cnt + P_N >= tile_cols) begin
                    // End of row in tile
                    col_cnt <= '0;
                    row_buffer_valid <= 1'b1;

                    if (row_cnt + P_M >= tile_rows) begin
                        // End of tile
                        row_cnt <= '0;
                        if (post_last) begin
                            store_done <= 1'b1;
                        end
                    end else begin
                        row_cnt <= row_cnt + P_M;
                    end
                end else begin
                    col_cnt <= col_cnt + P_N;
                    row_buffer_cnt <= row_buffer_cnt + P_N;
                    if (row_buffer_cnt + P_N >= ELEM_PER_BEAT) begin
                        row_buffer_valid <= 1'b1;
                        row_buffer_cnt <= '0;
                    end
                end
            end

            // Flush row_buffer when full or at tile boundary
            if (row_buffer_valid && dma_wr_ready) begin
                dma_wr_valid <= 1'b1;
                dma_wr_data  <= row_buffer;

                // Generate strobe: mask invalid elements at tile boundary
                dma_wr_strb <= '0;
                for (int e = 0; e < ELEM_PER_BEAT; e++) begin
                    int global_col_offset = (elem_byte_addr / ELEM_BYTES) % ELEM_PER_BEAT;
                    int global_col = (col_cnt >= tile_cols) ? '0 : col_cnt + (e - global_col_offset);
                    if (e >= global_col_offset && global_col < tile_cols) begin
                        for (int b = 0; b < ELEM_BYTES; b++) begin
                            dma_wr_strb[e * ELEM_BYTES + b] <= 1'b1;
                        end
                    end
                end

                // Check if this is the last beat of the tile
                if (row_cnt + P_M >= tile_rows && col_cnt + P_N >= tile_cols) begin
                    dma_wr_last <= 1'b1;
                end else begin
                    dma_wr_last <= 1'b0;
                end

                row_buffer_valid <= 1'b0;
                row_buffer <= '0;
            end else begin
                dma_wr_valid <= 1'b0;
                dma_wr_last  <= 1'b0;
            end

            // Calculate address for next element
            elem_byte_addr <= base_addr + row_cnt * tile_stride + col_cnt * ELEM_BYTES;

            // Error detection
            if (row_cnt >= tile_rows && post_valid) begin
                store_err <= 1'b1;
            end
        end
    end

endmodule : d_storer

`endif // D_STORER_SV
