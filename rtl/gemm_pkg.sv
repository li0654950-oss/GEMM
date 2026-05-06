//------------------------------------------------------------------------------
// gemm_pkg.sv
// GEMM Accelerator - Global Parameter Package
//------------------------------------------------------------------------------
`ifndef GEMM_PKG_SV
`define GEMM_PKG_SV

package gemm_pkg;
    // Array dimensions
    parameter int P_M             = 4;
    parameter int P_N             = 4;
    parameter int LANES           = P_M * P_N;

    // Data widths
    parameter int ELEM_W          = 16;     // FP16
    parameter int ACC_W           = 32;     // FP32 accumulator
    parameter int ELEM_BYTES      = 2;

    // Address & config
    parameter int ADDR_W          = 64;
    parameter int DIM_W           = 16;
    parameter int STRIDE_W        = 32;
    parameter int TILE_W          = 16;

    // AXI4 bus
    parameter int AXI_DATA_W      = 256;
    parameter int AXI_ID_W        = 4;
    parameter int AXI_STRB_W      = AXI_DATA_W / 8;
    parameter int AXI_ADDR_W      = ADDR_W;
    parameter int AXIL_ADDR_W     = 16;
    parameter int MAX_BURST_LEN   = 16;
    parameter int MAX_BURST_BYTES = MAX_BURST_LEN * (AXI_DATA_W / 8);

    // Buffer
    parameter int BUF_BANKS       = 8;
    parameter int BUF_DEPTH       = 2048;
    parameter int BUF_ADDR_W      = $clog2(BUF_DEPTH);

    // Performance & limits
    parameter int K_MAX           = 4096;
    parameter int OUTSTANDING_RD  = 8;
    parameter int OUTSTANDING_WR  = 8;
    parameter int TIMEOUT_CYCLES  = 100000;

    // Error codes
    parameter int ERR_CODE_W      = 16;
    localparam int ERR_NONE            = 32'h00;
    localparam int ERR_ILLEGAL_DIM     = 32'h01;
    localparam int ERR_ILLEGAL_TILE    = 32'h02;
    localparam int ERR_ADDR_ALIGN      = 32'h03;
    localparam int ERR_STRIDE_ALIGN    = 32'h04;
    localparam int ERR_TILE_OVERSIZE   = 32'h05;
    localparam int ERR_DMA_RD          = 32'h10;
    localparam int ERR_DMA_WR          = 32'h11;
    localparam int ERR_AXI_RD_RESP     = 32'h20;
    localparam int ERR_AXI_WR_RESP     = 32'h21;
    localparam int ERR_CORE            = 32'h30;
    localparam int ERR_PP              = 32'h40;
    localparam int ERR_TIMEOUT         = 32'h50;

    // Round modes
    typedef enum logic [1:0] {
        RNE = 2'b00,
        RTZ = 2'b01,
        RUP = 2'b10,
        RDN = 2'b11
    } round_mode_t;

    // Scheduler states (exposed for debug)
    typedef enum logic [3:0] {
        SCH_IDLE        = 4'd0,
        SCH_PRECHECK    = 4'd1,
        SCH_LOAD_AB     = 4'd2,
        SCH_LOAD_C      = 4'd3,
        SCH_WAIT_RD     = 4'd4,
        SCH_COMPUTE     = 4'd5,
        SCH_CHECK_K     = 4'd6,
        SCH_STORE       = 4'd7,
        SCH_CHECK_MN    = 4'd8,
        SCH_NEXT_K      = 4'd9,
        SCH_NEXT_MN     = 4'd10,
        SCH_DONE        = 4'd11,
        SCH_DONE2       = 4'd13,
        SCH_ERR         = 4'd12
    } sched_state_t;

endpackage : gemm_pkg

`endif // GEMM_PKG_SV
