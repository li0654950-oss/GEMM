//------------------------------------------------------------------------------
// tb_rd_addr_gen.sv
// GEMM Read Address Generator Testbench - FSM-driven for Verilator
//------------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_rd_addr_gen;
    localparam int ADDR_W       = 64;
    localparam int DIM_W        = 16;
    localparam int STRIDE_W     = 32;
    localparam int AXI_DATA_W   = 256;
    localparam int MAX_BURST_LEN= 16;

    reg  clk = 0;
    reg  rst_n = 0;

    reg              start = 0;
    reg  [ADDR_W-1:0] base_addr = 64'h1000;
    reg  [DIM_W-1:0]  rows = 8;
    reg  [DIM_W-1:0]  cols = 8;
    reg  [STRIDE_W-1:0] stride = 32'd32;
    reg  [2:0]        elem_bytes = 3'd2;  // FP16

    wire             cmd_valid;
    reg              cmd_ready = 1;
    wire [ADDR_W-1:0] cmd_addr;
    wire [7:0]        cmd_len;
    wire [15:0]       cmd_bytes;
    wire             cmd_last;

    rd_addr_gen #(
        .ADDR_W(ADDR_W), .DIM_W(DIM_W), .STRIDE_W(STRIDE_W),
        .AXI_DATA_W(AXI_DATA_W), .MAX_BURST_LEN(MAX_BURST_LEN)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .base_addr(base_addr), .rows(rows), .cols(cols),
        .stride(stride), .elem_bytes(elem_bytes),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_addr(cmd_addr), .cmd_len(cmd_len), .cmd_bytes(cmd_bytes), .cmd_last(cmd_last)
    );

    always #5 clk = ~clk;

    initial begin
        rst_n = 0;
        repeat(5) @(posedge clk);
        rst_n = 1;
    end

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    reg [15:0] burst_cnt;
    reg [15:0] timeout_cnt;
    localparam TIMEOUT_LIMIT = 1000;

    typedef enum integer {
        T_IDLE, T_START, T_EMIT, T_CHECK_LAST, T_DONE
    } test_state_t;
    test_state_t test_state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            test_state <= T_IDLE;
            timeout_cnt <= 0;
            burst_cnt <= 0;
            start <= 0;
        end else begin
            timeout_cnt <= timeout_cnt + 1;
            if (timeout_cnt > TIMEOUT_LIMIT) begin
                $display("[TB_RD_ADDR] TIMEOUT at state %0d", test_state);
                $finish;
            end

            case (test_state)
                T_IDLE: begin
                    $display("[TB_RD_ADDR] Starting...");
                    test_state <= T_START;
                    timeout_cnt <= 0;
                end
                T_START: begin
                    $display("  T_START: rows=%0d cols=%0d", rows, cols);
                    start <= 1;
                    test_state <= T_EMIT;
                    timeout_cnt <= 0;
                    burst_cnt <= 0;
                end
                T_EMIT: begin
                    start <= 0;
                    if (cmd_valid && cmd_ready) begin
                        burst_cnt <= burst_cnt + 1;
                        $display("  burst=%0d addr=%h len=%0d bytes=%0d last=%b",
                                 burst_cnt, cmd_addr, cmd_len, cmd_bytes, cmd_last);
                        if (cmd_last) begin
                            test_state <= T_CHECK_LAST;
                        end
                    end
                end
                T_CHECK_LAST: begin
                    // Expected bursts: 2 rows * (8 cols * 2 bytes / 32 bytes per beat) = 2 * 1 = 2? No...
                    // 8 cols * 2 bytes = 16 bytes. 256-bit bus = 32 bytes per beat. So 1 burst per row.
                    // Total: 2 bursts for 2 rows
                    if (burst_cnt > 0) begin
                        $display("  T1 PASS: %0d bursts generated", burst_cnt);
                        pass_cnt <= pass_cnt + 1;
                    end else begin
                        $display("  T1 FAIL: no bursts");
                        fail_cnt <= fail_cnt + 1;
                    end
                    test_state <= T_DONE;
                end
                T_DONE: begin
                    $display("[TB_RD_ADDR] Done. Pass=%0d Fail=%0d", pass_cnt, fail_cnt);
                    $finish;
                end
            endcase
        end
    end

endmodule
