//------------------------------------------------------------------------------
// err_checker.sv
// GEMM Error Checker & Aggregator
//
// Description:
//   Unified error detection for config-time and runtime errors.
//   Latches err_code/err_addr/err_src. Distinguishes fatal vs warning.
//   Includes timeout watchdog.
//------------------------------------------------------------------------------
`ifndef ERR_CHECKER_SV
`define ERR_CHECKER_SV

module err_checker #(
    parameter int ADDR_W        = 64,
    parameter int DIM_W         = 16,
    parameter int STRIDE_W      = 32,
    parameter int TILE_W        = 16,
    parameter int ERR_CODE_W    = 16,
    parameter int TIMEOUT_CYCLES= 100000
)(
    input  wire              clk,
    input  wire              rst_n,

    // Configuration check trigger -------------------------------------------
    input  wire              chk_valid,
    input  wire [DIM_W-1:0]  cfg_m,
    input  wire [DIM_W-1:0]  cfg_n,
    input  wire [DIM_W-1:0]  cfg_k,
    input  wire [TILE_W-1:0] cfg_tile_m,
    input  wire [TILE_W-1:0] cfg_tile_n,
    input  wire [TILE_W-1:0] cfg_tile_k,
    input  wire [ADDR_W-1:0] cfg_addr_a,
    input  wire [ADDR_W-1:0] cfg_addr_b,
    input  wire [ADDR_W-1:0] cfg_addr_c,
    input  wire [ADDR_W-1:0] cfg_addr_d,
    input  wire [STRIDE_W-1:0] cfg_stride_a,
    input  wire [STRIDE_W-1:0] cfg_stride_b,
    input  wire [STRIDE_W-1:0] cfg_stride_c,
    input  wire [STRIDE_W-1:0] cfg_stride_d,

    // Runtime events --------------------------------------------------------
    input  wire [1:0]        axi_rresp,
    input  wire              axi_rresp_valid,
    input  wire [1:0]        axi_bresp,
    input  wire              axi_bresp_valid,
    input  wire [7:0]        fsm_state,
    input  wire              fsm_err,
    input  wire              core_err,
    input  wire              pp_err,
    input  wire              busy_in,          // for timeout

    // Error outputs ---------------------------------------------------------
    output reg               err_valid,
    output reg  [ERR_CODE_W-1:0] err_code,
    output reg  [ADDR_W-1:0] err_addr,
    output reg  [7:0]        err_src,
    output reg               fatal_err,
    output reg               warn_err
);

    import gemm_pkg::*;

    // Error source IDs
    localparam [7:0] SRC_CFG      = 8'h01;
    localparam [7:0] SRC_AXI_RD   = 8'h02;
    localparam [7:0] SRC_AXI_WR   = 8'h03;
    localparam [7:0] SRC_FSM      = 8'h04;
    localparam [7:0] SRC_CORE     = 8'h05;
    localparam [7:0] SRC_PP       = 8'h06;
    localparam [7:0] SRC_TIMEOUT  = 8'h07;

    reg [$clog2(TIMEOUT_CYCLES+1)-1:0] timeout_cnt;
    reg         timeout_evt;

    // Timeout watchdog
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timeout_cnt <= '0;
            timeout_evt <= 1'b0;
        end else begin
            if (!busy_in) begin
                timeout_cnt <= '0;
                timeout_evt <= 1'b0;
            end else if (timeout_cnt < TIMEOUT_CYCLES) begin
                timeout_cnt <= timeout_cnt + 1'b1;
            end else begin
                timeout_evt <= 1'b1;
            end
        end
    end

    // Config check combinational
    wire align_err  = (cfg_addr_a[0] != 1'b0) || (cfg_addr_b[0] != 1'b0) ||
                      (cfg_addr_c[0] != 1'b0) || (cfg_addr_d[0] != 1'b0) ||
                      (cfg_stride_a[0] != 1'b0) || (cfg_stride_b[0] != 1'b0) ||
                      (cfg_stride_c[0] != 1'b0) || (cfg_stride_d[0] != 1'b0);

    wire dim_err    = (cfg_m == '0) || (cfg_n == '0) || (cfg_k == '0);
    wire tile_err   = (cfg_tile_m == '0) || (cfg_tile_n == '0) || (cfg_tile_k == '0);
    wire oversize_err = (cfg_tile_m > cfg_m) || (cfg_tile_n > cfg_n) || (cfg_tile_k > cfg_k);

    reg [ERR_CODE_W-1:0] chk_err_code;
    reg                  chk_err_occurred;
    reg [ADDR_W-1:0]     chk_err_addr;

    always_comb begin
        chk_err_code    = ERR_NONE;
        chk_err_occurred= 1'b0;
        chk_err_addr    = '0;
        if (chk_valid) begin
            if (dim_err) begin
                chk_err_code = ERR_ILLEGAL_DIM;
                chk_err_occurred = 1'b1;
            end else if (tile_err) begin
                chk_err_code = ERR_ILLEGAL_TILE;
                chk_err_occurred = 1'b1;
            end else if (align_err) begin
                chk_err_code = ERR_ADDR_ALIGN;
                chk_err_occurred = 1'b1;
                // latch first offending address
                if (cfg_addr_a[0])      chk_err_addr = cfg_addr_a;
                else if (cfg_addr_b[0]) chk_err_addr = cfg_addr_b;
                else if (cfg_addr_c[0]) chk_err_addr = cfg_addr_c;
                else if (cfg_addr_d[0]) chk_err_addr = cfg_addr_d;
                else if (cfg_stride_a[0]) chk_err_addr = {{(ADDR_W-STRIDE_W){1'b0}}, cfg_stride_a};
                else if (cfg_stride_b[0]) chk_err_addr = {{(ADDR_W-STRIDE_W){1'b0}}, cfg_stride_b};
                else if (cfg_stride_c[0]) chk_err_addr = {{(ADDR_W-STRIDE_W){1'b0}}, cfg_stride_c};
                else                      chk_err_addr = {{(ADDR_W-STRIDE_W){1'b0}}, cfg_stride_d};
            end else if (oversize_err) begin
                chk_err_code = ERR_TILE_OVERSIZE;
                chk_err_occurred = 1'b1;
            end
        end
    end

    // Error latch
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            err_valid  <= 1'b0;
            err_code   <= ERR_NONE;
            err_addr   <= '0;
            err_src    <= 8'h0;
            fatal_err  <= 1'b0;
            warn_err   <= 1'b0;
        end else begin
            if (chk_err_occurred) begin
                err_valid <= 1'b1;
                err_code  <= chk_err_code;
                err_addr  <= chk_err_addr;
                err_src   <= SRC_CFG;
                fatal_err <= 1'b1;
                warn_err  <= 1'b0;
            end else if (axi_rresp_valid && (axi_rresp != 2'b00)) begin
                err_valid <= 1'b1;
                err_code  <= ERR_AXI_RD_RESP;
                err_src   <= SRC_AXI_RD;
                fatal_err <= 1'b1;
                warn_err  <= 1'b0;
            end else if (axi_bresp_valid && (axi_bresp != 2'b00)) begin
                err_valid <= 1'b1;
                err_code  <= ERR_AXI_WR_RESP;
                err_src   <= SRC_AXI_WR;
                fatal_err <= 1'b1;
                warn_err  <= 1'b0;
            end else if (fsm_err) begin
                err_valid <= 1'b1;
                err_code  <= ERR_DMA_RD; // mapped from fsm_err
                err_src   <= SRC_FSM;
                fatal_err <= 1'b1;
                warn_err  <= 1'b0;
            end else if (core_err) begin
                err_valid <= 1'b1;
                err_code  <= ERR_CORE;
                err_src   <= SRC_CORE;
                fatal_err <= 1'b1;
                warn_err  <= 1'b0;
            end else if (pp_err) begin
                err_valid <= 1'b1;
                err_code  <= ERR_PP;
                err_src   <= SRC_PP;
                fatal_err <= 1'b0; // postproc error is warning by default
                warn_err  <= 1'b1;
            end else if (timeout_evt) begin
                err_valid <= 1'b1;
                err_code  <= ERR_TIMEOUT;
                err_src   <= SRC_TIMEOUT;
                fatal_err <= 1'b1;
                warn_err  <= 1'b0;
            end
            // Note: In full design, err_valid should be clearable via CSR W1C
        end
    end

endmodule : err_checker
`endif // ERR_CHECKER_SV
