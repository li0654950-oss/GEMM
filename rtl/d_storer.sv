//------------------------------------------------------------------------------
// d_storer.sv
// D Tile Collector and AXI Beat Packer
//
// Description:
//   Collects postproc output (P_M*P_N FP16 elements per cycle) and packs
//   into AXI beat format for DMA writeback.
//   Operates in row-major order.
//   Supports P_M > 1 by maintaining separate row buffers.
//
// Spec Reference: spec/onchip_buffer_reorder_spec.md Section 4.6
//------------------------------------------------------------------------------

`ifndef D_STORER_SV
`define D_STORER_SV

module d_storer #(
    parameter int P_M         = 2,
    parameter int P_N         = 2,
    parameter int ELEM_W      = 16,
    parameter int BUF_BANKS   = 4,
    parameter int BUF_DEPTH   = 512,
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

    // Buffer write interface (for accumulation writeback) ----------------
    output reg               buf_wr_valid,
    input  wire              buf_wr_ready,
    output reg  [2:0]        buf_wr_sel,
    output reg  [$clog2(BUF_BANKS)-1:0] buf_wr_bank,
    output reg  [$clog2(BUF_DEPTH)-1:0] buf_wr_addr,
    output reg  [AXI_DATA_W-1:0]        buf_wr_data,
    output reg  [AXI_DATA_W/8-1:0]      buf_wr_mask,

    // Status ---------------------------------------------------------------
    output reg               store_done,
    output reg               store_err
);

    localparam int BEAT_BYTES    = AXI_DATA_W / 8;
    localparam int ELEM_BYTES    = ELEM_W / 8;
    localparam int ELEM_PER_BEAT = AXI_DATA_W / ELEM_W;

    // Per-row accumulators
    reg [AXI_DATA_W-1:0] row_buffer [0:P_M-1];
    reg [$clog2(ELEM_PER_BEAT):0] row_buf_cnt [0:P_M-1];
    reg row_buf_valid [0:P_M-1];

    // Track row position within tile for each accumulator
    reg [15:0] row_buf_row [0:P_M-1];
    reg [15:0] row_buf_col [0:P_M-1];

    // Current write slot (round-robin among valid row buffers)
    reg [$clog2(P_M):0] wr_slot;

    // Global position tracking for incoming postproc data
    reg [15:0] next_row;
    reg [15:0] next_col;

    // Address and mask calculation for a specific row buffer slot
    wire [31:0] slot_byte_addr [0:P_M-1];
    wire [31:0] slot_beat_idx [0:P_M-1];
    wire [$clog2(BUF_BANKS)-1:0] slot_bank [0:P_M-1];
    wire [$clog2(BUF_DEPTH)-1:0] slot_addr [0:P_M-1];
    
    genvar gi;
    generate
        for (gi = 0; gi < P_M; gi++) begin : g_slot_addr
            assign slot_byte_addr[gi] = base_addr + row_buf_row[gi] * tile_stride + row_buf_col[gi] * ELEM_BYTES;
            assign slot_beat_idx[gi]  = slot_byte_addr[gi] / BEAT_BYTES;
            assign slot_bank[gi]      = slot_beat_idx[gi] % BUF_BANKS;
            assign slot_addr[gi]      = slot_beat_idx[gi] / BUF_BANKS;
        end
    endgenerate

    // Mask for a specific row buffer
    function automatic [AXI_DATA_W/8-1:0] gen_mask(input [15:0] start_col, input [15:0] the_row);
        reg [AXI_DATA_W/8-1:0] m;
        begin
            m = '0;
            for (int e = 0; e < ELEM_PER_BEAT; e++) begin
                if ((start_col + e) < tile_cols && the_row < tile_rows) begin
                    m[e*ELEM_BYTES +: ELEM_BYTES] = {ELEM_BYTES{1'b1}};
                end
            end
            gen_mask = m;
        end
    endfunction

    // Check if any row buffer is ready to write
    wire any_valid;
    reg any_valid_reg;
    always_comb begin
        any_valid_reg = 1'b0;
        for (int i = 0; i < P_M; i++) begin
            any_valid_reg = any_valid_reg | row_buf_valid[i];
        end
    end
    assign any_valid = any_valid_reg;

    // Find next valid slot to write
    reg [$clog2(P_M):0] next_wr_slot;
    always_comb begin
        next_wr_slot = wr_slot;
        for (int s = 0; s < P_M; s++) begin
            int idx = (wr_slot + s) % P_M;
            if (row_buf_valid[idx]) begin
                next_wr_slot = idx;
                break;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            next_row     <= '0;
            next_col     <= '0;
            wr_slot      <= '0;
            store_done   <= 1'b0;
            store_err    <= 1'b0;
            buf_wr_valid <= 1'b0;
            for (int r = 0; r < P_M; r++) begin
                row_buffer[r]    <= '0;
                row_buf_cnt[r]   <= '0;
                row_buf_valid[r] <= 1'b0;
                row_buf_row[r]   <= '0;
                row_buf_col[r]   <= '0;
            end
        end else begin
            store_done   <= 1'b0;
            store_err    <= 1'b0;
            buf_wr_valid <= 1'b0;

            // Stage 2: Write one ready row buffer to buffer_bank
            if (any_valid && buf_wr_ready) begin
                wr_slot <= next_wr_slot;
                buf_wr_valid <= 1'b1;
                buf_wr_sel   <= 3'd4;  // D_BUF
                buf_wr_bank  <= slot_bank[next_wr_slot];
                buf_wr_addr  <= slot_addr[next_wr_slot];
                buf_wr_data  <= row_buffer[next_wr_slot];
                buf_wr_mask  <= gen_mask(row_buf_col[next_wr_slot], row_buf_row[next_wr_slot]);
                row_buf_valid[next_wr_slot] <= 1'b0;
                row_buffer[next_wr_slot]    <= '0;
            end

            // Stage 1: Accept postproc data
            if (post_valid && post_ready) begin
                // Distribute elements to per-row accumulators
                for (int r = 0; r < P_M; r++) begin
                    for (int c = 0; c < P_N; c++) begin
                        if ((next_row + r) < tile_rows && (next_col + c) < tile_cols) begin
                            int elem_idx = r * P_N + c;
                            int buf_pos  = row_buf_cnt[r] + c;
                            if (buf_pos < ELEM_PER_BEAT) begin
                                row_buffer[r][buf_pos * ELEM_W +: ELEM_W] <= post_data[elem_idx * ELEM_W +: ELEM_W];
                            end
                        end
                    end
                end

                // Update counters and mark row buffers valid when full or at row boundary
                for (int r = 0; r < P_M; r++) begin
                    if ((next_row + r) < tile_rows) begin
                        if (next_col + P_N >= tile_cols) begin
                            // End of row: mark this row buffer valid
                            row_buf_valid[r] <= 1'b1;
                            row_buf_row[r]   <= next_row + r;
                            row_buf_col[r]   <= '0;
                            row_buf_cnt[r]   <= '0;
                        end else begin
                            row_buf_cnt[r] <= row_buf_cnt[r] + P_N;
                            if (row_buf_cnt[r] + P_N >= ELEM_PER_BEAT) begin
                                row_buf_valid[r] <= 1'b1;
                                row_buf_row[r]   <= next_row + r;
                                row_buf_col[r]   <= next_col;
                                row_buf_cnt[r]   <= '0;
                            end
                        end
                    end
                end

                // Update global position
                if (next_col + P_N >= tile_cols) begin
                    next_col <= '0;
                    if (next_row + P_M >= tile_rows) begin
                        next_row <= '0;
                        if (post_last) begin
                            store_done <= 1'b1;
                        end
                    end else begin
                        next_row <= next_row + P_M;
                    end
                end else begin
                    next_col <= next_col + P_N;
                end
            end

            // Error detection
            if (next_row >= tile_rows && post_valid) begin
                store_err <= 1'b1;
            end
        end
    end

    // post_ready: ready when we can accept data (at least one row buffer has space)
    // For simplicity, always ready if not all row buffers are full
    // A more sophisticated implementation would stall when all buffers are full
    always_comb begin
        post_ready = 1'b1;
        for (int r = 0; r < P_M; r++) begin
            if ((next_row + r) < tile_rows && row_buf_valid[r]) begin
                post_ready = 1'b0;
            end
        end
    end

endmodule : d_storer

`endif // D_STORER_SV
