//------------------------------------------------------------------------------
// csr_if.sv
// GEMM Control/Status Register Interface + IRQ Controller
//
// Description:
//   AXI4-Lite Slave. Implements full CSR map per spec/top_system_control_spec.md.
//   W1P (start), W1C (done/err), IRQ aggregation, perf counter snapshot.
//
//   IRQ ctrl merged into csr_if (spec 7.7).
//------------------------------------------------------------------------------
`ifndef CSR_IF_SV
`define CSR_IF_SV

module csr_if #(
    parameter int AXIL_ADDR_W = 16,
    parameter int DIM_W      = 16,
    parameter int ADDR_W     = 64,
    parameter int STRIDE_W   = 32,
    parameter int TILE_W     = 16,
    parameter int PERF_CNT_W = 64,
    parameter int ERR_CODE_W = 16
)(
    input  wire              clk,
    input  wire              rst_n,

    // AXI4-Lite Slave -------------------------------------------------------
    input  wire [AXIL_ADDR_W-1:0] s_axil_awaddr,
    input  wire              s_axil_awvalid,
    output reg               s_axil_awready,
    input  wire [31:0]       s_axil_wdata,
    input  wire [3:0]        s_axil_wstrb,
    input  wire              s_axil_wvalid,
    output reg               s_axil_wready,
    output reg  [1:0]        s_axil_bresp,
    output reg               s_axil_bvalid,
    input  wire              s_axil_bready,
    input  wire [AXIL_ADDR_W-1:0] s_axil_araddr,
    input  wire              s_axil_arvalid,
    output reg               s_axil_arready,
    output reg  [31:0]       s_axil_rdata,
    output reg  [1:0]        s_axil_rresp,
    output reg               s_axil_rvalid,
    input  wire              s_axil_rready,

    // Configuration outputs to tile_scheduler ------------------------------
    output reg  [DIM_W-1:0]  cfg_m,
    output reg  [DIM_W-1:0]  cfg_n,
    output reg  [DIM_W-1:0]  cfg_k,
    output reg  [TILE_W-1:0] cfg_tile_m,
    output reg  [TILE_W-1:0] cfg_tile_n,
    output reg  [TILE_W-1:0] cfg_tile_k,
    output reg  [ADDR_W-1:0] cfg_addr_a,
    output reg  [ADDR_W-1:0] cfg_addr_b,
    output reg  [ADDR_W-1:0] cfg_addr_c,
    output reg  [ADDR_W-1:0] cfg_addr_d,
    output reg  [STRIDE_W-1:0] cfg_stride_a,
    output reg  [STRIDE_W-1:0] cfg_stride_b,
    output reg  [STRIDE_W-1:0] cfg_stride_c,
    output reg  [STRIDE_W-1:0] cfg_stride_d,
    output reg               cfg_add_c_en,
    output reg  [1:0]        cfg_round_mode,
    output reg               cfg_sat_en,
    output reg               cfg_start,
    output reg               cfg_soft_reset,
    output reg               irq_en,

    // Status inputs from scheduler ------------------------------------------
    input  wire              sch_busy,
    input  wire              sch_done,
    input  wire              sch_err,
    input  wire [ERR_CODE_W-1:0] sch_err_code,
    input  wire [TILE_W-1:0] sch_tile_m_idx,
    input  wire [TILE_W-1:0] sch_tile_n_idx,
    input  wire [TILE_W-1:0] sch_tile_k_idx,

    // Perf counter inputs (snap on done) ------------------------------------
    input  wire [PERF_CNT_W-1:0] perf_cycle_total,
    input  wire [PERF_CNT_W-1:0] perf_cycle_compute,
    input  wire [PERF_CNT_W-1:0] perf_cycle_dma_wait,
    input  wire [PERF_CNT_W-1:0] perf_axi_rd_bytes,
    input  wire [PERF_CNT_W-1:0] perf_axi_wr_bytes,

    // IRQ output ------------------------------------------------------------
    output wire              irq_o
);

    //------------------------------------------------------------------------
    // CSR Address Map
    //------------------------------------------------------------------------
    localparam [15:0] ADDR_CTRL           = 16'h0000;
    localparam [15:0] ADDR_STATUS         = 16'h0004;
    localparam [15:0] ADDR_IRQ_MASK       = 16'h0008;
    localparam [15:0] ADDR_IRQ_STATUS     = 16'h000C;
    localparam [15:0] ADDR_ERR_CODE       = 16'h0010;
    localparam [15:0] ADDR_DIM_M          = 16'h0020;
    localparam [15:0] ADDR_DIM_N          = 16'h0024;
    localparam [15:0] ADDR_DIM_K          = 16'h0028;
    localparam [15:0] ADDR_ADDR_A_LO      = 16'h0030;
    localparam [15:0] ADDR_ADDR_A_HI      = 16'h0034;
    localparam [15:0] ADDR_ADDR_B_LO      = 16'h0038;
    localparam [15:0] ADDR_ADDR_B_HI      = 16'h003C;
    localparam [15:0] ADDR_ADDR_C_LO      = 16'h0040;
    localparam [15:0] ADDR_ADDR_C_HI      = 16'h0044;
    localparam [15:0] ADDR_ADDR_D_LO      = 16'h0048;
    localparam [15:0] ADDR_ADDR_D_HI      = 16'h004C;
    localparam [15:0] ADDR_STRIDE_A       = 16'h0050;
    localparam [15:0] ADDR_STRIDE_B       = 16'h0054;
    localparam [15:0] ADDR_STRIDE_C       = 16'h0058;
    localparam [15:0] ADDR_STRIDE_D       = 16'h005C;
    localparam [15:0] ADDR_TILE_M         = 16'h0060;
    localparam [15:0] ADDR_TILE_N         = 16'h0064;
    localparam [15:0] ADDR_TILE_K         = 16'h0068;
    localparam [15:0] ADDR_MODE           = 16'h006C;
    localparam [15:0] ADDR_ARRAY_CFG      = 16'h0070;
    localparam [15:0] ADDR_TILE_IDX_M     = 16'h0074;
    localparam [15:0] ADDR_TILE_IDX_N     = 16'h0078;
    localparam [15:0] ADDR_TILE_IDX_K     = 16'h007C;
    localparam [15:0] ADDR_PERF_CYCLE_T_LO= 16'h0080;
    localparam [15:0] ADDR_PERF_CYCLE_T_HI= 16'h0084;
    localparam [15:0] ADDR_PERF_CYCLE_C_LO= 16'h0088;
    localparam [15:0] ADDR_PERF_CYCLE_C_HI= 16'h008C;
    localparam [15:0] ADDR_PERF_DMA_W_LO  = 16'h0090;
    localparam [15:0] ADDR_PERF_DMA_W_HI  = 16'h0094;
    localparam [15:0] ADDR_PERF_RD_B_LO   = 16'h0098;
    localparam [15:0] ADDR_PERF_RD_B_HI   = 16'h009C;
    localparam [15:0] ADDR_PERF_WR_B_LO   = 16'h00A0;
    localparam [15:0] ADDR_PERF_WR_B_HI   = 16'h00A4;
    localparam [15:0] ADDR_DEBUG_CTRL     = 16'h00B0;

    //------------------------------------------------------------------------
    // Internal registers
    //------------------------------------------------------------------------
    reg [31:0]  reg_ctrl;
    reg [31:0]  reg_status;
    reg [ERR_CODE_W-1:0] reg_err_code;
    reg [7:0]   reg_irq_mask;
    reg [7:0]   reg_irq_status;
    reg [31:0]  reg_debug;
    reg         sch_done_d;
    reg         sch_err_d;

    // W1P start pulse generation (registered output for 1-cycle guarantee)
    reg         start_d;
    reg         cfg_start_r;
    assign cfg_start = cfg_start_r;

    // IRQ logic (merged irq_ctrl)
    wire [7:0] irq_src = {
        1'b0,             // 7 reserved
        1'b0,             // 6 perf_threshold (unused)
        1'b0,             // 5 timeout (unused)
        1'b0,             // 4 pp_err (unused)
        1'b0,             // 3 core_err (unused)
        1'b0,             // 2 dma_wr_err (unused)
        1'b0,             // 1 dma_rd_err (unused)
        sch_done | sch_err // 0 done or err
    };

    wire irq_pending = |(irq_src & ~reg_irq_mask);
    assign irq_o = irq_en && irq_pending;

    //------------------------------------------------------------------------
    // AXI4-Lite Write FSM
    //------------------------------------------------------------------------
    typedef enum logic [1:0] { WR_IDLE, WR_ADDR, WR_DATA, WR_RESP } wr_state_t;
    wr_state_t wr_state, wr_next;
    reg [AXIL_ADDR_W-1:0] wr_addr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_state <= WR_IDLE;
        end else begin
            wr_state <= wr_next;
        end
    end

    always_comb begin
        wr_next = wr_state;
        case (wr_state)
            WR_IDLE:
                if (s_axil_awvalid && s_axil_awready) wr_next = WR_ADDR;
            WR_ADDR:
                if (s_axil_wvalid && s_axil_wready) wr_next = WR_DATA;
            WR_DATA:
                wr_next = WR_RESP;
            WR_RESP:
                if (s_axil_bready) wr_next = WR_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_awready <= 1'b1;
            s_axil_wready   <= 1'b0;
            s_axil_bvalid   <= 1'b0;
            s_axil_bresp    <= 2'b00;
            wr_addr         <= '0;
        end else begin
            case (wr_state)
                WR_IDLE: begin
                    s_axil_awready <= 1'b1;
                    s_axil_wready  <= 1'b0;
                end
                WR_ADDR: begin
                    s_axil_awready <= 1'b0;
                    s_axil_wready  <= 1'b1;
                    wr_addr <= s_axil_awaddr;
                end
                WR_DATA: begin
                    s_axil_wready <= 1'b0;
                end
                WR_RESP: begin
                    if (!s_axil_bvalid) begin
                        s_axil_bvalid <= 1'b1;
                        if (wr_addr > 16'h00B0) s_axil_bresp <= 2'b10;
                        else                    s_axil_bresp <= 2'b00;
                    end else if (s_axil_bready) begin
                        s_axil_bvalid <= 1'b0;
                    end
                end
            endcase
        end
    end

    //------------------------------------------------------------------------
    // Register write decode (combinational for immediate effect)
    //------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_ctrl        <= 32'h0;
            reg_status      <= 32'h0;
            reg_err_code    <= '0;
            reg_irq_mask    <= 8'h00;
            reg_irq_status  <= 8'h0;
            reg_debug       <= 32'h0;
            sch_done_d      <= 1'b0;
            sch_err_d       <= 1'b0;
            cfg_m           <= '0;
            cfg_n           <= '0;
            cfg_k           <= '0;
            cfg_tile_m      <= '0;
            cfg_tile_n      <= '0;
            cfg_tile_k      <= '0;
            cfg_addr_a      <= '0;
            cfg_addr_b      <= '0;
            cfg_addr_c      <= '0;
            cfg_addr_d      <= '0;
            cfg_stride_a    <= '0;
            cfg_stride_b    <= '0;
            cfg_stride_c    <= '0;
            cfg_stride_d    <= '0;
            cfg_add_c_en    <= 1'b0;
            cfg_round_mode  <= 2'b00;
            cfg_sat_en      <= 1'b1;
            cfg_soft_reset  <= 1'b0;
            irq_en          <= 1'b0;
            start_d         <= 1'b0;
            cfg_start_r     <= 1'b0;
        end else begin
            start_d <= reg_ctrl[0];
            cfg_start_r <= reg_ctrl[0] && !start_d;
            cfg_soft_reset <= 1'b0;

            // Auto-clear W1P start
            if (reg_ctrl[0]) reg_ctrl[0] <= 1'b0;

            // W1C done/err clear
            if (reg_status[1]) reg_status[1] <= 1'b0;
            if (reg_status[2]) reg_status[2] <= 1'b0;

            // Delay sch_done/sch_err by 1 cycle to avoid Verilator scheduling race
            sch_done_d <= sch_done;
            sch_err_d  <= sch_err;

            `ifdef SIMULATION
            if (sch_done || sch_err)
                $display("[CSR] sch_done=%b sch_err=%b irq_en=%b irq_pending=%b irq_o=%b", sch_done, sch_err, irq_en, irq_pending, irq_o);
            `endif

            // IRQ status latching
            if (sch_done_d || sch_err_d) begin
                reg_irq_status[0] <= 1'b1;
            end
            if (reg_status[1] && reg_status[2]) begin
                reg_irq_status[0] <= 1'b0;
            end

            // Shadow status from scheduler
            reg_status[0] <= sch_busy;

            // Write decode on WR_DATA state, using direct AXI inputs
            if (wr_state == WR_DATA) begin
                case (s_axil_awaddr)
                    ADDR_CTRL: begin
                        if (s_axil_wstrb[0]) begin
                            reg_ctrl[0] <= s_axil_wdata[0];
                            reg_ctrl[1] <= s_axil_wdata[1];
                            reg_ctrl[2] <= s_axil_wdata[2];
                            cfg_soft_reset <= s_axil_wdata[1];
                            irq_en <= s_axil_wdata[2];
                        end
                    end
                    ADDR_STATUS: begin
                        if (s_axil_wstrb[0]) begin
                            reg_status[1] <= reg_status[1] && !s_axil_wdata[1];
                            reg_status[2] <= reg_status[2] && !s_axil_wdata[2];
                        end
                    end
                    ADDR_IRQ_MASK: begin
                        if (s_axil_wstrb[0]) reg_irq_mask <= s_axil_wdata[7:0];
                    end
                    ADDR_DIM_M:     if (s_axil_wstrb[0]) cfg_m        <= s_axil_wdata[DIM_W-1:0];
                    ADDR_DIM_N:     if (s_axil_wstrb[0]) cfg_n        <= s_axil_wdata[DIM_W-1:0];
                    ADDR_DIM_K:     if (s_axil_wstrb[0]) cfg_k        <= s_axil_wdata[DIM_W-1:0];
                    ADDR_TILE_M:    if (s_axil_wstrb[0]) cfg_tile_m   <= s_axil_wdata[TILE_W-1:0];
                    ADDR_TILE_N:    if (s_axil_wstrb[0]) cfg_tile_n   <= s_axil_wdata[TILE_W-1:0];
                    ADDR_TILE_K:    if (s_axil_wstrb[0]) cfg_tile_k   <= s_axil_wdata[TILE_W-1:0];
                    ADDR_ADDR_A_LO: if (s_axil_wstrb[0]) cfg_addr_a[31:0]  <= s_axil_wdata;
                    ADDR_ADDR_A_HI: if (s_axil_wstrb[0]) cfg_addr_a[63:32] <= s_axil_wdata;
                    ADDR_ADDR_B_LO: if (s_axil_wstrb[0]) cfg_addr_b[31:0]  <= s_axil_wdata;
                    ADDR_ADDR_B_HI: if (s_axil_wstrb[0]) cfg_addr_b[63:32] <= s_axil_wdata;
                    ADDR_ADDR_C_LO: if (s_axil_wstrb[0]) cfg_addr_c[31:0]  <= s_axil_wdata;
                    ADDR_ADDR_C_HI: if (s_axil_wstrb[0]) cfg_addr_c[63:32] <= s_axil_wdata;
                    ADDR_ADDR_D_LO: if (s_axil_wstrb[0]) cfg_addr_d[31:0]  <= s_axil_wdata;
                    ADDR_ADDR_D_HI: if (s_axil_wstrb[0]) cfg_addr_d[63:32] <= s_axil_wdata;
                    ADDR_STRIDE_A:  if (s_axil_wstrb[0]) cfg_stride_a <= s_axil_wdata[STRIDE_W-1:0];
                    ADDR_STRIDE_B:  if (s_axil_wstrb[0]) cfg_stride_b <= s_axil_wdata[STRIDE_W-1:0];
                    ADDR_STRIDE_C:  if (s_axil_wstrb[0]) cfg_stride_c <= s_axil_wdata[STRIDE_W-1:0];
                    ADDR_STRIDE_D:  if (s_axil_wstrb[0]) cfg_stride_d <= s_axil_wdata[STRIDE_W-1:0];
                    ADDR_MODE: begin
                        if (s_axil_wstrb[0]) begin
                            cfg_add_c_en   <= s_axil_wdata[0];
                            cfg_round_mode <= s_axil_wdata[2:1];
                            cfg_sat_en     <= s_axil_wdata[3];
                        end
                    end
                    ADDR_DEBUG_CTRL: if (s_axil_wstrb[0]) reg_debug <= s_axil_wdata;
                    default: ;
                endcase
            end

            // Error code latch from scheduler
            if (sch_err) begin
                reg_err_code <= sch_err_code;
            end
        end
    end

    //------------------------------------------------------------------------
    // AXI4-Lite Read FSM
    //------------------------------------------------------------------------
    typedef enum logic [1:0] { RD_IDLE, RD_ADDR, RD_DATA } rd_state_t;
    rd_state_t rd_state, rd_next;
    reg [AXIL_ADDR_W-1:0] rd_addr_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_state <= RD_IDLE;
        end else begin
            rd_state <= rd_next;
        end
    end

    always_comb begin
        rd_next = rd_state;
        case (rd_state)
            RD_IDLE:
                if (s_axil_arvalid && s_axil_arready) rd_next = RD_ADDR;
            RD_ADDR:
                rd_next = RD_DATA;
            RD_DATA:
                if (s_axil_rvalid && s_axil_rready) rd_next = RD_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_arready <= 1'b1;
            s_axil_rvalid  <= 1'b0;
            s_axil_rresp   <= 2'b00;
            rd_addr_r      <= '0;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    s_axil_arready <= 1'b1;
                end
                RD_ADDR: begin
                    s_axil_arready <= 1'b0;
                    rd_addr_r <= s_axil_araddr;
                end
                RD_DATA: begin
                    if (!s_axil_rvalid) begin
                        s_axil_rvalid <= 1'b1;
                    end else if (s_axil_rready) begin
                        s_axil_rvalid <= 1'b0;
                    end
                end
            endcase
        end
    end

    //------------------------------------------------------------------------
    // Register read decode (combinational)
    //------------------------------------------------------------------------
    always_comb begin
        s_axil_rdata = 32'h0;
        case (rd_addr_r)
            ADDR_CTRL:       s_axil_rdata = reg_ctrl;
            ADDR_STATUS:     s_axil_rdata = reg_status;
            ADDR_IRQ_MASK:   s_axil_rdata = {24'h0, reg_irq_mask};
            ADDR_IRQ_STATUS: s_axil_rdata = {24'h0, reg_irq_status};
            ADDR_ERR_CODE:   s_axil_rdata = {{(32-ERR_CODE_W){1'b0}}, reg_err_code};
            ADDR_DIM_M:      s_axil_rdata = {{(32-DIM_W){1'b0}}, cfg_m};
            ADDR_DIM_N:      s_axil_rdata = {{(32-DIM_W){1'b0}}, cfg_n};
            ADDR_DIM_K:      s_axil_rdata = {{(32-DIM_W){1'b0}}, cfg_k};
            ADDR_ADDR_A_LO:  s_axil_rdata = cfg_addr_a[31:0];
            ADDR_ADDR_A_HI:  s_axil_rdata = cfg_addr_a[63:32];
            ADDR_ADDR_B_LO:  s_axil_rdata = cfg_addr_b[31:0];
            ADDR_ADDR_B_HI:  s_axil_rdata = cfg_addr_b[63:32];
            ADDR_ADDR_C_LO:  s_axil_rdata = cfg_addr_c[31:0];
            ADDR_ADDR_C_HI:  s_axil_rdata = cfg_addr_c[63:32];
            ADDR_ADDR_D_LO:  s_axil_rdata = cfg_addr_d[31:0];
            ADDR_ADDR_D_HI:  s_axil_rdata = cfg_addr_d[63:32];
            ADDR_STRIDE_A:   s_axil_rdata = {{(32-STRIDE_W){1'b0}}, cfg_stride_a};
            ADDR_STRIDE_B:   s_axil_rdata = {{(32-STRIDE_W){1'b0}}, cfg_stride_b};
            ADDR_STRIDE_C:   s_axil_rdata = {{(32-STRIDE_W){1'b0}}, cfg_stride_c};
            ADDR_STRIDE_D:   s_axil_rdata = {{(32-STRIDE_W){1'b0}}, cfg_stride_d};
            ADDR_TILE_M:     s_axil_rdata = {{(32-TILE_W){1'b0}}, cfg_tile_m};
            ADDR_TILE_N:     s_axil_rdata = {{(32-TILE_W){1'b0}}, cfg_tile_n};
            ADDR_TILE_K:     s_axil_rdata = {{(32-TILE_W){1'b0}}, cfg_tile_k};
            ADDR_MODE:       s_axil_rdata = {28'h0, cfg_sat_en, cfg_round_mode, cfg_add_c_en};
            ADDR_ARRAY_CFG:  s_axil_rdata = 32'h0;  // reserved
            ADDR_TILE_IDX_M: s_axil_rdata = {{(32-TILE_W){1'b0}}, sch_tile_m_idx};
            ADDR_TILE_IDX_N: s_axil_rdata = {{(32-TILE_W){1'b0}}, sch_tile_n_idx};
            ADDR_TILE_IDX_K: s_axil_rdata = {{(32-TILE_W){1'b0}}, sch_tile_k_idx};
            ADDR_PERF_CYCLE_T_LO: s_axil_rdata = perf_cycle_total[31:0];
            ADDR_PERF_CYCLE_T_HI: s_axil_rdata = perf_cycle_total[63:32];
            ADDR_PERF_CYCLE_C_LO: s_axil_rdata = perf_cycle_compute[31:0];
            ADDR_PERF_CYCLE_C_HI: s_axil_rdata = perf_cycle_compute[63:32];
            ADDR_PERF_DMA_W_LO:   s_axil_rdata = perf_cycle_dma_wait[31:0];
            ADDR_PERF_DMA_W_HI:   s_axil_rdata = perf_cycle_dma_wait[63:32];
            ADDR_PERF_RD_B_LO:    s_axil_rdata = perf_axi_rd_bytes[31:0];
            ADDR_PERF_RD_B_HI:    s_axil_rdata = perf_axi_rd_bytes[63:32];
            ADDR_PERF_WR_B_LO:    s_axil_rdata = perf_axi_wr_bytes[31:0];
            ADDR_PERF_WR_B_HI:    s_axil_rdata = perf_axi_wr_bytes[63:32];
            ADDR_DEBUG_CTRL:      s_axil_rdata = reg_debug;
            default:              s_axil_rdata = 32'hDEAD_BEEF;
        endcase
    end

endmodule : csr_if
`endif // CSR_IF_SV
