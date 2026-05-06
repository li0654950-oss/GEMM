//------------------------------------------------------------------------------
// c_loader.sv
// GEMM C Tile Loader
//
// Description:
//   Receives DMA read data stream and writes C tile to buffer_bank
//   for postproc C-fusion. Operates in row-major order.
//   Similar structure to a_loader/b_loader.
//------------------------------------------------------------------------------
`ifndef C_LOADER_SV
`define C_LOADER_SV

module c_loader #(
    parameter int P_M         = 4,
    parameter int P_N         = 4,
    parameter int ELEM_W      = 16,
    parameter int BUF_BANKS   = 8,
    parameter int BUF_DEPTH   = 2048,
    parameter int AXI_DATA_W  = 256
)(
    input  wire              clk,
    input  wire              rst_n,

    // DMA interface ---------------------------------------------------------
    input  wire              dma_valid,
    output wire              dma_ready,
    input  wire [AXI_DATA_W-1:0] dma_data,
    input  wire              dma_last,

    // Tile configuration ----------------------------------------------------
    input  wire [15:0]       tile_rows,
    input  wire [15:0]       tile_cols,
    input  wire [31:0]       tile_stride,
    input  wire [31:0]       base_addr,

    // Buffer write interface ------------------------------------------------
    output reg               buf_wr_valid,
    output reg  [$clog2(BUF_BANKS)-1:0] buf_wr_bank,
    output reg  [$clog2(BUF_DEPTH)-1:0] buf_wr_addr,
    output reg  [AXI_DATA_W-1:0] buf_wr_data,
    output reg  [AXI_DATA_W/8-1:0] buf_wr_mask,
    input  wire              buf_wr_ready,

    output reg               load_done,
    output reg               load_err
);

    localparam int BYTES_PER_BEAT = AXI_DATA_W / 8;
    localparam int ELEM_PER_BEAT  = BYTES_PER_BEAT / (ELEM_W/8);
    localparam int ELEM_BYTES     = ELEM_W / 8;

    typedef enum logic [2:0] {
        IDLE,
        LOAD,
        WAIT_BUF,
        DONE,
        ERR
    } state_t;

    state_t state, next_state;
    reg [15:0] row_cnt;
    reg [15:0] col_cnt;
    reg [31:0] buf_offset;
    reg [31:0] row_base;

    always_comb begin
        next_state = state;
        case (state)
            IDLE:      if (dma_valid)         next_state = LOAD;
            LOAD:      if (!buf_wr_ready)     next_state = WAIT_BUF;
                       else if (dma_last)     next_state = DONE;
            WAIT_BUF:  if (buf_wr_ready)      next_state = LOAD;
            DONE:                            next_state = IDLE;
            ERR:                             next_state = IDLE;
            default:   next_state = IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            row_cnt    <= '0;
            col_cnt    <= '0;
            buf_offset <= '0;
            row_base   <= '0;
            load_done  <= 1'b0;
            load_err   <= 1'b0;
            buf_wr_valid <= 1'b0;
            buf_wr_bank  <= '0;
            buf_wr_addr  <= '0;
            buf_wr_data  <= '0;
            buf_wr_mask  <= '0;
        end else begin
            state <= next_state;
            load_done <= 1'b0;
            load_err  <= 1'b0;
            buf_wr_valid <= 1'b0;

            case (state)
                IDLE: begin
                    if (dma_valid) begin
                        row_cnt    <= '0;
                        col_cnt    <= '0;
                        buf_offset <= base_addr;
                        row_base   <= base_addr;
                    end
                end
                LOAD: begin
                    if (buf_wr_ready) begin
                        buf_wr_valid <= 1'b1;
                        buf_wr_bank  <= '0; // C uses dedicated bank
                        buf_wr_addr  <= buf_offset[$clog2(BUF_DEPTH)-1:0];
                        buf_wr_data  <= dma_data;
                        // Compute byte mask for partial last row
                        if (col_cnt + ELEM_PER_BEAT >= tile_cols) begin
                            automatic int valid_bytes;
                            valid_bytes = (tile_cols - col_cnt) * ELEM_BYTES;
                            buf_wr_mask <= (valid_bytes >= BYTES_PER_BEAT)
                                        ? {BYTES_PER_BEAT{1'b1}}
                                        : ({BYTES_PER_BEAT{1'b1}} >> (BYTES_PER_BEAT - valid_bytes));
                        end else begin
                            buf_wr_mask <= {BYTES_PER_BEAT{1'b1}};
                        end

                        if (col_cnt + ELEM_PER_BEAT >= tile_cols) begin
                            col_cnt <= '0;
                            row_cnt <= row_cnt + 1'b1;
                            row_base <= row_base + tile_stride;
                            buf_offset <= row_base + tile_stride;
                        end else begin
                            col_cnt <= col_cnt + ELEM_PER_BEAT;
                            buf_offset <= buf_offset + BYTES_PER_BEAT;
                        end
                    end
                end
                WAIT_BUF: begin
                    // Wait for buffer
                end
                DONE: begin
                    load_done <= 1'b1;
                end
                ERR: begin
                    load_err <= 1'b1;
                end
            endcase
        end
    end

    assign dma_ready = (state == LOAD) && buf_wr_ready;

endmodule : c_loader
`endif // C_LOADER_SV
