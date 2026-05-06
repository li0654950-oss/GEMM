//------------------------------------------------------------------------------
// dma_wr.sv
// GEMM Write DMA Controller
//
// Description:
//   Accepts tile_scheduler write requests, dispatches to wr_addr_gen,
//   then drives axi_wr_master. Forwards d_storer data to W channel.
//------------------------------------------------------------------------------
`ifndef DMA_WR_SV
`define DMA_WR_SV

module dma_wr #(
    parameter int ADDR_W       = 64,
    parameter int DIM_W        = 16,
    parameter int STRIDE_W     = 32,
    parameter int AXI_DATA_W   = 256,
    parameter int MAX_BURST_LEN= 16,
    parameter int OUTSTANDING_WR = 8
)(
    input  wire              clk,
    input  wire              rst_n,

    // Request from tile_scheduler -------------------------------------------
    input  wire              wr_req_valid,
    output reg               wr_req_ready,
    input  wire [ADDR_W-1:0] wr_req_base_addr,
    input  wire [DIM_W-1:0]  wr_req_rows,
    input  wire [DIM_W-1:0]  wr_req_cols,
    input  wire [STRIDE_W-1:0] wr_req_stride,
    input  wire              wr_req_last,
    output reg               wr_done,
    output reg               wr_err,

    // Data input from d_storer ----------------------------------------------
    input  wire              wr_data_valid,
    output reg               wr_data_ready,
    input  wire [AXI_DATA_W-1:0] wr_data_payload,
    input  wire              wr_data_last,

    // To axi_wr_master ------------------------------------------------------
    output reg               axi_wr_cmd_valid,
    input  wire              axi_wr_cmd_ready,
    output reg  [ADDR_W-1:0] axi_wr_cmd_addr,
    output reg  [7:0]        axi_wr_cmd_len,
    output reg  [2:0]        axi_wr_cmd_size,
    output reg               axi_wr_data_valid,
    input  wire              axi_wr_data_ready,
    output reg  [AXI_DATA_W-1:0] axi_wr_data_payload,
    output reg               axi_wr_data_last,
    output reg  [AXI_DATA_W/8-1:0] axi_wr_data_strb,
    input  wire              axi_wr_resp_err
);

    localparam int BEAT_BYTES = AXI_DATA_W / 8;
    localparam int STRB_W     = AXI_DATA_W / 8;

    typedef enum logic [2:0] {
        IDLE,
        ADDR_ISSUE,
        DATA_SEND,
        WAIT_B,
        DONE,
        ERR
    } state_t;

    state_t state, next_state;

    wire         addr_gen_wr_cmd_valid;
    wire         addr_gen_wr_cmd_ready;
    wire [ADDR_W-1:0] addr_gen_wr_cmd_addr;
    wire [7:0]   addr_gen_wr_cmd_len;
    wire [15:0]  addr_gen_wr_cmd_bytes;
    wire         addr_gen_wr_cmd_last;

    reg          addr_gen_start;
    reg [15:0]   wbeat_cnt;
    reg [15:0]   total_beats;
    reg          tile_done;

    always_comb begin
        next_state = state;
        case (state)
            IDLE:       if (wr_req_valid)            next_state = ADDR_ISSUE;
            ADDR_ISSUE: if (addr_gen_wr_cmd_last) next_state = DATA_SEND;
            DATA_SEND:  if (wr_data_last && wr_data_valid && wr_data_ready) next_state = WAIT_B;
                        else if (axi_wr_resp_err)     next_state = ERR;
            WAIT_B:     if (tile_done)               next_state = DONE;
                        else if (axi_wr_resp_err)    next_state = ERR;
            DONE:                                   next_state = IDLE;
            ERR:                                    next_state = IDLE;
            default:    next_state = IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            wr_req_ready     <= 1'b1;
            wr_done          <= 1'b0;
            wr_err           <= 1'b0;
            wr_data_ready    <= 1'b0;
            axi_wr_cmd_valid <= 1'b0;
            axi_wr_data_valid<= 1'b0;
            addr_gen_start   <= 1'b0;
            wbeat_cnt        <= '0;
            tile_done        <= 1'b0;
        end else begin
            state <= next_state;
            wr_done  <= 1'b0;
            wr_err   <= 1'b0;
            addr_gen_start <= 1'b0;
            tile_done <= 1'b0;
            `ifdef SIMULATION
            if (state != next_state) $display("[DMA_WR] state %0d -> %0d at time %0t", state, next_state, $time);
            `endif

            case (state)
                IDLE: begin
                    wr_req_ready <= 1'b1;
                    wr_data_ready <= 1'b0;
                    if (wr_req_valid) begin
                        wr_req_ready <= 1'b0;
                        addr_gen_start <= 1'b1;
                        wbeat_cnt <= '0;
                    end
                end
                ADDR_ISSUE: begin
                    axi_wr_cmd_valid <= addr_gen_wr_cmd_valid;
                    axi_wr_cmd_addr  <= addr_gen_wr_cmd_addr;
                    axi_wr_cmd_len   <= addr_gen_wr_cmd_len;
                    axi_wr_cmd_size  <= $clog2(BEAT_BYTES);
                end
                DATA_SEND: begin
                    wr_data_ready <= axi_wr_data_ready;
                    `ifdef SIMULATION
                    $display("[DMA_WR] DATA_SEND wr_data_valid=%b wr_data_ready=%b axi_wr_data_ready=%b", wr_data_valid, wr_data_ready, axi_wr_data_ready);
                    `endif
                    if (wr_data_valid && wr_data_ready) begin
                        axi_wr_data_valid   <= 1'b1;
                        axi_wr_data_payload <= wr_data_payload;
                        axi_wr_data_strb    <= {STRB_W{1'b1}};
                        axi_wr_data_last    <= wr_data_last;
                        wbeat_cnt <= wbeat_cnt + 1'b1;
                        if (wr_data_last) tile_done <= 1'b1;
                    end
                    if (axi_wr_data_valid && axi_wr_data_ready) begin
                        axi_wr_data_valid <= 1'b0;
                    end
                end
                WAIT_B: begin
                    // Wait for B resp handled in axi_wr_master, tile_done set
                    if (tile_done) begin
                        // Hold until B comes back (os_cnt tracking in master)
                    end
                end
                DONE: begin
                    wr_done <= 1'b1;
                    wr_req_ready <= 1'b1;
                end
                ERR: begin
                    wr_err <= 1'b1;
                    wr_req_ready <= 1'b1;
                end
            endcase
        end
    end

    wr_addr_gen #(
        .ADDR_W       (ADDR_W),
        .DIM_W        (DIM_W),
        .STRIDE_W     (STRIDE_W),
        .AXI_DATA_W   (AXI_DATA_W),
        .MAX_BURST_LEN(MAX_BURST_LEN)
    ) u_addr_gen (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (addr_gen_start),
        .base_addr     (wr_req_base_addr),
        .rows          (wr_req_rows),
        .cols          (wr_req_cols),
        .stride        (wr_req_stride),
        .elem_bytes    (3'd2),
        .wr_cmd_valid  (addr_gen_wr_cmd_valid),
        .wr_cmd_ready  (axi_wr_cmd_ready),
        .wr_cmd_addr   (addr_gen_wr_cmd_addr),
        .wr_cmd_len    (addr_gen_wr_cmd_len),
        .wr_cmd_bytes  (addr_gen_wr_cmd_bytes),
        .wr_cmd_last   (addr_gen_wr_cmd_last)
    );

endmodule : dma_wr
`endif // DMA_WR_SV
