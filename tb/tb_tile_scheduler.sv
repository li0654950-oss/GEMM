//------------------------------------------------------------------------------
// tb_tile_scheduler.sv
// GEMM Tile Scheduler Testbench - FSM-driven for Verilator compatibility
//------------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_tile_scheduler;
    localparam int P_M      = 4;
    localparam int P_N      = 4;
    localparam int DIM_W    = 16;
    localparam int ADDR_W   = 64;
    localparam int STRIDE_W = 32;
    localparam int TILE_W   = 16;
    localparam int ELEM_W   = 16;
    localparam int ERR_CODE_W = 16;

    reg  clk = 0;
    reg  rst_n = 0;

    reg  [DIM_W-1:0]  cfg_m = 8;
    reg  [DIM_W-1:0]  cfg_n = 8;
    reg  [DIM_W-1:0]  cfg_k = 4;
    reg  [TILE_W-1:0] cfg_tile_m = 4;
    reg  [TILE_W-1:0] cfg_tile_n = 4;
    reg  [TILE_W-1:0] cfg_tile_k = 4;
    reg  [ADDR_W-1:0] cfg_addr_a = 64'h1000;
    reg  [ADDR_W-1:0] cfg_addr_b = 64'h2000;
    reg  [ADDR_W-1:0] cfg_addr_c = 64'h3000;
    reg  [ADDR_W-1:0] cfg_addr_d = 64'h4000;
    reg  [STRIDE_W-1:0] cfg_stride_a = 32'd16;
    reg  [STRIDE_W-1:0] cfg_stride_b = 32'd16;
    reg  [STRIDE_W-1:0] cfg_stride_c = 32'd16;
    reg  [STRIDE_W-1:0] cfg_stride_d = 32'd16;
    reg              cfg_add_c_en = 0;
    reg              cfg_start = 0;

    wire             sch_busy, sch_done, sch_err;
    wire [ERR_CODE_W-1:0] sch_err_code;
    wire [TILE_W-1:0] sch_tile_m_idx, sch_tile_n_idx, sch_tile_k_idx;
    wire [P_M*P_N-1:0] tile_mask;

    wire             rd_req_valid;
    reg              rd_req_ready = 1;
    wire [1:0]       rd_req_type;
    wire [ADDR_W-1:0] rd_req_base_addr;
    wire [TILE_W-1:0] rd_req_rows, rd_req_cols;
    wire [STRIDE_W-1:0] rd_req_stride;
    wire             rd_req_last;
    reg              rd_done = 0;
    reg              rd_err = 0;

    wire             wr_req_valid;
    reg              wr_req_ready = 1;
    wire [ADDR_W-1:0] wr_req_base_addr;
    wire [TILE_W-1:0] wr_req_rows, wr_req_cols;
    wire [STRIDE_W-1:0] wr_req_stride;
    wire             wr_req_last;
    reg              wr_done = 0;
    reg              wr_err = 0;

    wire             core_start;
    reg              core_done = 0;
    reg              core_busy = 0;
    reg              core_err = 0;
    wire             pp_start;
    reg              pp_done = 0;
    reg              pp_busy = 0;
    wire             pp_switch_req;
    reg              pp_switch_ack = 1;

    tile_scheduler #(
        .P_M(P_M), .P_N(P_N), .DIM_W(DIM_W), .ADDR_W(ADDR_W),
        .STRIDE_W(STRIDE_W), .TILE_W(TILE_W), .ELEM_W(ELEM_W), .ERR_CODE_W(ERR_CODE_W)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_m(cfg_m), .cfg_n(cfg_n), .cfg_k(cfg_k),
        .cfg_tile_m(cfg_tile_m), .cfg_tile_n(cfg_tile_n), .cfg_tile_k(cfg_tile_k),
        .cfg_addr_a(cfg_addr_a), .cfg_addr_b(cfg_addr_b), .cfg_addr_c(cfg_addr_c), .cfg_addr_d(cfg_addr_d),
        .cfg_stride_a(cfg_stride_a), .cfg_stride_b(cfg_stride_b), .cfg_stride_c(cfg_stride_c), .cfg_stride_d(cfg_stride_d),
        .cfg_add_c_en(cfg_add_c_en), .cfg_start(cfg_start),
        .sch_busy(sch_busy), .sch_done(sch_done), .sch_err(sch_err), .sch_err_code(sch_err_code),
        .sch_tile_m_idx(sch_tile_m_idx), .sch_tile_n_idx(sch_tile_n_idx), .sch_tile_k_idx(sch_tile_k_idx),
        .tile_mask(tile_mask),
        .rd_req_valid(rd_req_valid), .rd_req_ready(rd_req_ready), .rd_req_type(rd_req_type),
        .rd_req_base_addr(rd_req_base_addr), .rd_req_rows(rd_req_rows), .rd_req_cols(rd_req_cols),
        .rd_req_stride(rd_req_stride), .rd_req_last(rd_req_last),
        .rd_done(rd_done), .rd_err(rd_err),
        .wr_req_valid(wr_req_valid), .wr_req_ready(wr_req_ready),
        .wr_req_base_addr(wr_req_base_addr), .wr_req_rows(wr_req_rows), .wr_req_cols(wr_req_cols),
        .wr_req_stride(wr_req_stride), .wr_req_last(wr_req_last),
        .wr_done(wr_done), .wr_err(wr_err),
        .core_start(core_start), .core_done(core_done), .core_busy(core_busy), .core_err(core_err),
        .pp_start(pp_start), .pp_done(pp_done), .pp_busy(pp_busy),
        .pp_switch_req(pp_switch_req), .pp_switch_ack(pp_switch_ack),
        .cnt_start(), .cnt_stop()
    );

    always #5 clk = ~clk;

    initial begin
        rst_n = 0;
        repeat(5) @(posedge clk);
        rst_n = 1;
    end

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    reg [15:0] timeout_cnt;
    localparam TIMEOUT_LIMIT = 50000;

    // Auto-response state machines for external interfaces
    reg [2:0] rd_ack_cnt, wr_ack_cnt, core_ack_cnt, pp_ack_cnt;
    reg rd_pending, wr_pending, core_pending, pp_pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_done <= 0; rd_err <= 0; rd_pending <= 0; rd_ack_cnt <= 0;
            wr_done <= 0; wr_err <= 0; wr_pending <= 0; wr_ack_cnt <= 0;
            core_done <= 0; core_busy <= 0; core_pending <= 0; core_ack_cnt <= 0;
            pp_done <= 0; pp_busy <= 0; pp_pending <= 0; pp_ack_cnt <= 0;
        end else begin
            // Read request auto-ack (2 cycle delay)
            if (rd_req_valid && rd_req_ready && !rd_pending) begin
                rd_pending <= 1;
                rd_ack_cnt <= 0;
            end else if (rd_pending) begin
                rd_ack_cnt <= rd_ack_cnt + 1;
                if (rd_ack_cnt == 2) begin
                    rd_done <= 1;
                end else if (rd_ack_cnt == 3) begin
                    rd_done <= 0;
                    rd_pending <= 0;
                end
            end

            // Write request auto-ack (2 cycle delay)
            if (wr_req_valid && wr_req_ready && !wr_pending) begin
                wr_pending <= 1;
                wr_ack_cnt <= 0;
            end else if (wr_pending) begin
                wr_ack_cnt <= wr_ack_cnt + 1;
                if (wr_ack_cnt == 2) begin
                    wr_done <= 1;
                end else if (wr_ack_cnt == 3) begin
                    wr_done <= 0;
                    wr_pending <= 0;
                end
            end

            // Core auto-ack (4 cycle delay)
            if (core_start && !core_pending) begin
                core_pending <= 1;
                core_ack_cnt <= 0;
                core_busy <= 1;
            end else if (core_pending) begin
                core_ack_cnt <= core_ack_cnt + 1;
                if (core_ack_cnt == 4) begin
                    core_busy <= 0;
                    core_done <= 1;
                end else if (core_ack_cnt == 5) begin
                    core_done <= 0;
                    core_pending <= 0;
                end
            end

            // Post-proc auto-ack (2 cycle delay)
            if (pp_start && !pp_pending) begin
                pp_pending <= 1;
                pp_ack_cnt <= 0;
                pp_busy <= 1;
            end else if (pp_pending) begin
                pp_ack_cnt <= pp_ack_cnt + 1;
                if (pp_ack_cnt == 2) begin
                    pp_busy <= 0;
                    pp_done <= 1;
                end else if (pp_ack_cnt == 3) begin
                    pp_done <= 0;
                    pp_pending <= 0;
                end
            end
        end
    end

    // Main test FSM
    typedef enum integer {
        T_IDLE, T_START, T_WAIT_BUSY, T_RUN, T_CHECK_DONE,
        T_ZERO_DIM, T_CHECK_ERR, T_DONE
    } test_state_t;
    test_state_t test_state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            test_state <= T_IDLE;
            timeout_cnt <= 0;
            cfg_start <= 0;
            cfg_m <= 8; cfg_n <= 8; cfg_k <= 4;
        end else begin
            timeout_cnt <= timeout_cnt + 1;
            if (timeout_cnt > TIMEOUT_LIMIT) begin
                $display("[TB_TILE_SCH] TIMEOUT at state %0d", test_state);
                $finish;
            end

            case (test_state)
                T_IDLE: begin
                    $display("[TB_TILE_SCH] Starting...");
                    test_state <= T_START;
                    timeout_cnt <= 0;
                end
                T_START: begin
                    $display("  T_START: asserting cfg_start");
                    cfg_start <= 1;
                    test_state <= T_WAIT_BUSY;
                    timeout_cnt <= 0;
                end
                T_WAIT_BUSY: begin
                    cfg_start <= 0;
                    if (sch_busy) begin
                        $display("  T1 PASS: sch_busy asserted");
                        pass_cnt <= pass_cnt + 1;
                        test_state <= T_RUN;
                        timeout_cnt <= 0;
                    end
                end
                T_RUN: begin
                    if (sch_done) begin
                        $display("  T2 PASS: sch_done asserted after tile loop");
                        pass_cnt <= pass_cnt + 1;
                        $display("  T3 INFO: Tile indices m=%0d n=%0d k=%0d", sch_tile_m_idx, sch_tile_n_idx, sch_tile_k_idx);
                        test_state <= T_ZERO_DIM;
                        timeout_cnt <= 0;
                    end
                end
                T_ZERO_DIM: begin
                    cfg_m <= 0;
                    cfg_start <= 1;
                    test_state <= T_CHECK_ERR;
                    timeout_cnt <= 0;
                end
                T_CHECK_ERR: begin
                    cfg_start <= 0;
                    if (sch_err) begin
                        $display("  T4 PASS: sch_err on zero M");
                        pass_cnt <= pass_cnt + 1;
                        test_state <= T_DONE;
                    end
                end
                T_DONE: begin
                    $display("[TB_TILE_SCH] Done. Pass=%0d Fail=%0d", pass_cnt, fail_cnt);
                    $finish;
                end
            endcase
        end
    end

endmodule
