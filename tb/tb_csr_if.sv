//------------------------------------------------------------------------------
// tb_csr_if.sv
// GEMM CSR Interface Testbench - Fixed FSM timing for Verilator
//------------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_csr_if;
    localparam int AXIL_ADDR_W = 16;
    localparam int DIM_W       = 16;
    localparam int ADDR_W      = 64;
    localparam int STRIDE_W    = 32;
    localparam int TILE_W      = 16;
    localparam int PERF_CNT_W  = 64;
    localparam int ERR_CODE_W  = 16;

    reg  clk = 0;
    reg  rst_n = 0;

    reg  [AXIL_ADDR_W-1:0] s_axil_awaddr;
    reg              s_axil_awvalid;
    wire             s_axil_awready;
    reg  [31:0]      s_axil_wdata;
    reg  [3:0]       s_axil_wstrb;
    reg              s_axil_wvalid;
    wire             s_axil_wready;
    wire [1:0]       s_axil_bresp;
    wire             s_axil_bvalid;
    reg              s_axil_bready;
    reg  [AXIL_ADDR_W-1:0] s_axil_araddr;
    reg              s_axil_arvalid;
    wire             s_axil_arready;
    wire [31:0]      s_axil_rdata;
    wire [1:0]       s_axil_rresp;
    wire             s_axil_rvalid;
    reg              s_axil_rready;

    reg              sch_busy = 0;
    reg              sch_done = 0;
    reg              sch_err  = 0;
    reg  [ERR_CODE_W-1:0] sch_err_code = 0;
    reg  [TILE_W-1:0] sch_tile_m_idx = 0;
    reg  [TILE_W-1:0] sch_tile_n_idx = 0;
    reg  [TILE_W-1:0] sch_tile_k_idx = 0;

    reg  [PERF_CNT_W-1:0] perf_cycle_total = 0;
    reg  [PERF_CNT_W-1:0] perf_cycle_compute = 0;
    reg  [PERF_CNT_W-1:0] perf_cycle_dma_wait = 0;
    reg  [PERF_CNT_W-1:0] perf_axi_rd_bytes = 0;
    reg  [PERF_CNT_W-1:0] perf_axi_wr_bytes = 0;

    wire [DIM_W-1:0]  cfg_m, cfg_n, cfg_k;
    wire [TILE_W-1:0] cfg_tile_m, cfg_tile_n, cfg_tile_k;
    wire [ADDR_W-1:0] cfg_addr_a, cfg_addr_b, cfg_addr_c, cfg_addr_d;
    wire [STRIDE_W-1:0] cfg_stride_a, cfg_stride_b, cfg_stride_c, cfg_stride_d;
    wire              cfg_add_c_en;
    wire [1:0]        cfg_round_mode;
    wire              cfg_sat_en;
    wire              cfg_start;
    wire              cfg_soft_reset;
    wire              irq_en;
    wire              irq_o;

    csr_if #(
        .AXIL_ADDR_W(AXIL_ADDR_W), .DIM_W(DIM_W), .ADDR_W(ADDR_W),
        .STRIDE_W(STRIDE_W), .TILE_W(TILE_W), .PERF_CNT_W(PERF_CNT_W), .ERR_CODE_W(ERR_CODE_W)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb), .s_axil_wvalid(s_axil_wvalid), .s_axil_wready(s_axil_wready),
        .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid), .s_axil_bready(s_axil_bready),
        .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready),
        .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp), .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),
        .cfg_m(cfg_m), .cfg_n(cfg_n), .cfg_k(cfg_k),
        .cfg_tile_m(cfg_tile_m), .cfg_tile_n(cfg_tile_n), .cfg_tile_k(cfg_tile_k),
        .cfg_addr_a(cfg_addr_a), .cfg_addr_b(cfg_addr_b), .cfg_addr_c(cfg_addr_c), .cfg_addr_d(cfg_addr_d),
        .cfg_stride_a(cfg_stride_a), .cfg_stride_b(cfg_stride_b), .cfg_stride_c(cfg_stride_c), .cfg_stride_d(cfg_stride_d),
        .cfg_add_c_en(cfg_add_c_en), .cfg_round_mode(cfg_round_mode), .cfg_sat_en(cfg_sat_en),
        .cfg_start(cfg_start), .cfg_soft_reset(cfg_soft_reset), .irq_en(irq_en),
        .sch_busy(sch_busy), .sch_done(sch_done), .sch_err(sch_err), .sch_err_code(sch_err_code),
        .sch_tile_m_idx(sch_tile_m_idx), .sch_tile_n_idx(sch_tile_n_idx), .sch_tile_k_idx(sch_tile_k_idx),
        .perf_cycle_total(perf_cycle_total), .perf_cycle_compute(perf_cycle_compute),
        .perf_cycle_dma_wait(perf_cycle_dma_wait),
        .perf_axi_rd_bytes(perf_axi_rd_bytes), .perf_axi_wr_bytes(perf_axi_wr_bytes),
        .irq_o(irq_o)
    );

    always #5 clk = ~clk;

    initial begin
        rst_n = 0;
        repeat(5) @(posedge clk);
        rst_n = 1;
    end

    reg [31:0] rdata;
    integer pass_cnt = 0;
    integer fail_cnt = 0;
    reg [7:0] timeout_cnt;
    reg [7:0] global_cnt;
    localparam TIMEOUT_LIMIT = 50;
    localparam GLOBAL_LIMIT = 200;

    typedef enum integer {
        T_IDLE, T_WR_SETUP, T_WR_AW, T_WR_W, T_WR_WAIT_B, T_WR_B_ACK, T_WR_B_ACK2,
        T_RD_SETUP, T_RD_AR, T_RD_R, T_RD_ACK, T_CHECK, T_DONE
    } test_state_t;
    test_state_t test_state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            test_state     <= T_IDLE;
            timeout_cnt    <= 0;
            global_cnt     <= 0;
            s_axil_awaddr  <= 0; s_axil_awvalid <= 0;
            s_axil_wdata   <= 0; s_axil_wstrb   <= 0; s_axil_wvalid  <= 0;
            s_axil_bready  <= 0;
            s_axil_araddr  <= 0; s_axil_arvalid <= 0;
            s_axil_rready  <= 0;
        end else begin
            global_cnt <= global_cnt + 1;
            if (global_cnt > GLOBAL_LIMIT) begin
                $display("[TB_CSR_IF] GLOBAL TIMEOUT at state %0d", test_state);
                $finish;
            end

            case (test_state)
                T_IDLE: begin
                    $display("[TB_CSR_IF] Starting...");
                    test_state  <= T_WR_SETUP;
                    timeout_cnt <= 0;
                end
                T_WR_SETUP: begin
                    $display("  T_WR_SETUP");
                    s_axil_awaddr  <= 16'h0020;
                    s_axil_wdata   <= 32'd8;
                    s_axil_wstrb   <= 4'hF;
                    s_axil_awvalid <= 1;
                    s_axil_wvalid  <= 1;
                    test_state     <= T_WR_AW;
                    timeout_cnt    <= 0;
                end
                T_WR_AW: begin
                    timeout_cnt <= timeout_cnt + 1;
                    if (timeout_cnt > TIMEOUT_LIMIT) begin
                        $display("  T_WR_AW timeout, awready=%b", s_axil_awready);
                        test_state <= T_DONE;
                    end else if (s_axil_awready) begin
                        $display("  T_WR_AW: awready=1");
                        s_axil_awvalid <= 0;
                        test_state     <= T_WR_W;
                        timeout_cnt    <= 0;
                    end
                end
                T_WR_W: begin
                    timeout_cnt <= timeout_cnt + 1;
                    if (timeout_cnt > TIMEOUT_LIMIT) begin
                        $display("  T_WR_W timeout, wready=%b", s_axil_wready);
                        test_state <= T_DONE;
                    end else if (s_axil_wready) begin
                        $display("  T_WR_W: wready=1");
                        test_state    <= T_WR_WAIT_B;
                        timeout_cnt   <= 0;
                    end
                end
                T_WR_WAIT_B: begin
                    timeout_cnt <= timeout_cnt + 1;
                    if (timeout_cnt > TIMEOUT_LIMIT) begin
                        $display("  T_WR_WAIT_B timeout, bvalid=%b", s_axil_bvalid);
                        test_state <= T_DONE;
                    end else if (s_axil_bvalid) begin
                        $display("  T_WR_WAIT_B: bvalid=1");
                        s_axil_wvalid <= 0;
                        s_axil_bready <= 1;
                        test_state    <= T_WR_B_ACK;
                        timeout_cnt   <= 0;
                    end
                end
                T_WR_B_ACK: begin
                    s_axil_bready <= 0;
                    timeout_cnt   <= 0;
                    test_state    <= T_WR_B_ACK2;
                end
                T_WR_B_ACK2: begin
                    timeout_cnt <= timeout_cnt + 1;
                    if (timeout_cnt > 2) begin
                        test_state <= T_RD_SETUP;
                    end
                end
                T_RD_SETUP: begin
                    $display("  T_RD_SETUP");
                    s_axil_araddr  <= 16'h0020;
                    s_axil_arvalid <= 1;
                    test_state     <= T_RD_AR;
                    timeout_cnt    <= 0;
                end
                T_RD_AR: begin
                    timeout_cnt <= timeout_cnt + 1;
                    if (timeout_cnt > TIMEOUT_LIMIT) begin
                        $display("  T_RD_AR timeout, arready=%b", s_axil_arready);
                        test_state <= T_DONE;
                    end else if (s_axil_arready) begin
                        $display("  T_RD_AR: arready=1");
                        s_axil_arvalid <= 0;
                        test_state     <= T_RD_R;
                        timeout_cnt    <= 0;
                    end
                end
                T_RD_R: begin
                    timeout_cnt <= timeout_cnt + 1;
                    if (timeout_cnt > TIMEOUT_LIMIT) begin
                        $display("  T_RD_R timeout, rvalid=%b", s_axil_rvalid);
                        test_state <= T_DONE;
                    end else if (s_axil_rvalid) begin
                        $display("  T_RD_R: rvalid=1, rdata=%d", s_axil_rdata);
                        rdata <= s_axil_rdata;
                        s_axil_rready <= 1;
                        test_state    <= T_RD_ACK;
                        timeout_cnt   <= 0;
                    end
                end
                T_RD_ACK: begin
                    s_axil_rready <= 0;
                    test_state    <= T_CHECK;
                end
                T_CHECK: begin
                    if (rdata == 32'd8) begin
                        $display("  T1 PASS: write/read DIM_M=8");
                        pass_cnt = pass_cnt + 1;
                    end else begin
                        $display("  T1 FAIL: expected 8 got %d", rdata);
                        fail_cnt = fail_cnt + 1;
                    end
                    test_state <= T_DONE;
                end
                T_DONE: begin
                    $display("[TB_CSR_IF] Done. Pass=%0d Fail=%0d", pass_cnt, fail_cnt);
                    $finish;
                end
            endcase
        end
    end

endmodule
