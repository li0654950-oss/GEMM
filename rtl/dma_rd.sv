//------------------------------------------------------------------------------
// dma_rd.sv
// GEMM Read DMA Controller
//
// Description:
//   Accepts tile_scheduler read requests, dispatches to rd_addr_gen,
//   then drives axi_rd_master. Distributes returned data to A/B/C lanes.
//   Round-robin arbitration for A/B/C.
//------------------------------------------------------------------------------
`ifndef DMA_RD_SV
`define DMA_RD_SV

module dma_rd #(
    parameter int ADDR_W       = 64,
    parameter int DIM_W        = 16,
    parameter int STRIDE_W     = 32,
    parameter int AXI_DATA_W   = 256,
    parameter int MAX_BURST_LEN= 16,
    parameter int OUTSTANDING_RD = 8
)(
    input  wire              clk,
    input  wire              rst_n,

    // Request from tile_scheduler -------------------------------------------
    input  wire              rd_req_valid,
    output reg               rd_req_ready,
    input  wire [1:0]        rd_req_type,
    input  wire [ADDR_W-1:0] rd_req_base_addr,
    input  wire [DIM_W-1:0]  rd_req_rows,
    input  wire [DIM_W-1:0]  rd_req_cols,
    input  wire [STRIDE_W-1:0] rd_req_stride,
    input  wire              rd_req_last,
    output reg               rd_done,
    output reg               rd_err,

    // Data outputs to buffer loaders ----------------------------------------
    output reg               rd_data_valid,
    input  wire              rd_data_ready,
    output reg  [AXI_DATA_W-1:0] rd_data_payload,
    output reg               rd_data_last,
    output reg  [1:0]        rd_data_type,

    // To axi_rd_master ------------------------------------------------------
    output reg               axi_rd_cmd_valid,
    input  wire              axi_rd_cmd_ready,
    output reg  [ADDR_W-1:0] axi_rd_cmd_addr,
    output reg  [7:0]        axi_rd_cmd_len,
    output reg  [2:0]        axi_rd_cmd_size,
    input  wire              axi_rd_data_valid,
    output reg               axi_rd_data_ready,
    input  wire [AXI_DATA_W-1:0] axi_rd_data_payload,
    input  wire              axi_rd_data_last,
    input  wire              axi_rd_resp_err
);

    localparam int BEAT_BYTES = AXI_DATA_W / 8;

    typedef enum logic [2:0] {
        IDLE,
        ADDR_ISSUE,
        DATA_WAIT,
        DONE,
        ERR
    } state_t;

    state_t state, next_state;
    reg [1:0]    req_type_r;
    reg [15:0]   burst_rem;
    reg          addr_gen_busy;

    // Addr gen start trigger
    reg          addr_gen_start;
    wire         addr_gen_cmd_valid;
    wire         addr_gen_cmd_ready;
    assign addr_gen_cmd_ready = axi_rd_cmd_ready;

    wire [ADDR_W-1:0] addr_gen_cmd_addr;
    wire [7:0]   addr_gen_cmd_len;
    wire [15:0]  addr_gen_cmd_bytes;
    wire         addr_gen_cmd_last;

    // Outstanding tracking
    reg [15:0]   rd_beat_cnt;
    reg          tile_done;

    always_comb begin
        next_state = state;
        case (state)
            IDLE:      if (rd_req_valid)           next_state = ADDR_ISSUE;
            ADDR_ISSUE:if (addr_gen_cmd_last && axi_rd_cmd_ready) next_state = DATA_WAIT;
            DATA_WAIT: if (tile_done)              next_state = DONE;
                       else if (axi_rd_resp_err)  next_state = ERR;
            DONE:                                 next_state = IDLE;
            ERR:                                  next_state = IDLE;
            default:   next_state = IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= IDLE;
            rd_req_ready    <= 1'b1;
            rd_done         <= 1'b0;
            rd_err          <= 1'b0;
            rd_data_valid   <= 1'b0;
            axi_rd_cmd_valid<= 1'b0;
            axi_rd_data_ready<= 1'b1;
            addr_gen_start  <= 1'b0;
            req_type_r      <= '0;
            rd_beat_cnt     <= '0;
            tile_done       <= 1'b0;
        end else begin
            state <= next_state;
            rd_done  <= 1'b0;
            rd_err   <= 1'b0;
            rd_data_valid <= 1'b0;
            addr_gen_start <= 1'b0;
            tile_done <= 1'b0;

            case (state)
                IDLE: begin
                    rd_req_ready <= 1'b1;
                    if (rd_req_valid) begin
                        rd_req_ready <= 1'b0;
                        req_type_r   <= rd_req_type;
                        addr_gen_start <= 1'b1;
                        rd_beat_cnt  <= '0;
                    end
                end
                ADDR_ISSUE: begin
                    // Forward addr_gen commands to axi_rd_master
                    axi_rd_cmd_valid <= addr_gen_cmd_valid;
                    axi_rd_cmd_addr  <= addr_gen_cmd_addr;
                    axi_rd_cmd_len   <= addr_gen_cmd_len;
                    axi_rd_cmd_size  <= $clog2(BEAT_BYTES);
                    if (addr_gen_cmd_ready) begin
                        if (addr_gen_cmd_last) begin
                            // all bursts issued
                        end
                    end
                end
                DATA_WAIT: begin
                    if (axi_rd_data_valid && axi_rd_data_ready) begin
                        rd_data_valid   <= 1'b1;
                        rd_data_payload <= axi_rd_data_payload;
                        rd_data_last    <= axi_rd_data_last;
                        rd_data_type    <= req_type_r;
                        rd_beat_cnt     <= rd_beat_cnt + 1'b1;
                        if (axi_rd_data_last) begin
                            tile_done <= 1'b1;
                        end
                    end
                end
                DONE: begin
                    rd_done <= 1'b1;
                    rd_req_ready <= 1'b1;
                end
                ERR: begin
                    rd_err <= 1'b1;
                    rd_req_ready <= 1'b1;
                end
            endcase
        end
    end

    // Addr gen instance
    rd_addr_gen #(
        .ADDR_W       (ADDR_W),
        .DIM_W        (DIM_W),
        .STRIDE_W     (STRIDE_W),
        .AXI_DATA_W   (AXI_DATA_W),
        .MAX_BURST_LEN(MAX_BURST_LEN)
    ) u_addr_gen (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (addr_gen_start),
        .base_addr     (rd_req_base_addr),
        .rows          (rd_req_rows),
        .cols          (rd_req_cols),
        .stride        (rd_req_stride),
        .elem_bytes    (3'd2),
        .cmd_valid     (addr_gen_cmd_valid),
        .cmd_ready     (addr_gen_cmd_ready && axi_rd_cmd_ready),
        .cmd_addr      (addr_gen_cmd_addr),
        .cmd_len       (addr_gen_cmd_len),
        .cmd_bytes     (addr_gen_cmd_bytes),
        .cmd_last      (addr_gen_cmd_last)
    );

endmodule : dma_rd
`endif // DMA_RD_SV
