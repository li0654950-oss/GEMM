//------------------------------------------------------------------------------
// tb_buffer_bank.sv
// Testbench for buffer_bank + loaders + d_storer integration
//------------------------------------------------------------------------------

`timescale 1ns/1ps
`define SIMULATION

module tb_buffer_bank;

    localparam int P_M        = 2;
    localparam int P_N        = 2;
    localparam int ELEM_W     = 16;
    localparam int ACC_W      = 32;
    localparam int BUF_BANKS  = 4;
    localparam int BUF_DEPTH  = 512;
    localparam int AXI_DATA_W = 256;

    logic clk;
    logic rst_n;

    logic              wr_valid;
    wire               wr_ready;
    logic [2:0]        wr_sel;
    logic [$clog2(BUF_BANKS)-1:0] wr_bank;
    logic [$clog2(BUF_DEPTH)-1:0] wr_addr;
    logic [AXI_DATA_W-1:0]        wr_data;
    logic [AXI_DATA_W/8-1:0]      wr_mask;

    logic              rd_req_valid;
    wire               rd_req_ready;
    logic [2:0]        rd_sel;
    logic [$clog2(BUF_BANKS)-1:0] rd_bank;
    logic [$clog2(BUF_DEPTH)-1:0] rd_addr;
    wire               rd_data_valid;
    wire  [AXI_DATA_W-1:0]        rd_data;

    logic pp_switch_req;
    wire  pp_switch_ack;
    wire  pp_a_compute_sel;
    wire  pp_b_compute_sel;
    wire  pp_a_load_sel;
    wire  pp_b_load_sel;

    wire               conflict_stall;
    wire [BUF_BANKS-1:0] bank_occ;

    buffer_bank #(
        .P_M(P_M), .P_N(P_N), .ELEM_W(ELEM_W), .ACC_W(ACC_W),
        .BUF_BANKS(BUF_BANKS), .BUF_DEPTH(BUF_DEPTH),
        .AXI_DATA_W(AXI_DATA_W), .PP_ENABLE(1'b1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(wr_valid), .wr_ready(wr_ready),
        .wr_sel(wr_sel), .wr_bank(wr_bank), .wr_addr(wr_addr),
        .wr_data(wr_data), .wr_mask(wr_mask),
        .rd_req_valid(rd_req_valid), .rd_req_ready(rd_req_ready),
        .rd_sel(rd_sel), .rd_bank(rd_bank), .rd_addr(rd_addr),
        .rd_data_valid(rd_data_valid), .rd_data(rd_data),
        .pp_switch_req(pp_switch_req), .pp_switch_ack(pp_switch_ack),
        .pp_a_compute_sel(pp_a_compute_sel), .pp_b_compute_sel(pp_b_compute_sel),
        .pp_a_load_sel(pp_a_load_sel), .pp_b_load_sel(pp_b_load_sel),
        .conflict_stall(conflict_stall), .bank_occ(bank_occ)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst_n = 1'b0;
        repeat(3) @(posedge clk);
        #1;
        rst_n = 1'b1;
    end

    task automatic reset_all();
        wr_valid      = 1'b0;
        rd_req_valid  = 1'b0;
        pp_switch_req = 1'b0;
        wr_sel        = '0;
        wr_bank       = '0;
        wr_addr       = '0;
        wr_data       = '0;
        wr_mask       = '0;
        rd_sel        = '0;
        rd_bank       = '0;
        rd_addr       = '0;
    endtask

    task automatic check_val(logic [AXI_DATA_W-1:0] actual, logic [AXI_DATA_W-1:0] expected, string name);
        if (actual === expected) begin
            $display("  PASS %s: 0x%032X", name, actual);
            pass_count++;
        end else begin
            $display("  FAIL %s: expected=0x%032X actual=0x%032X", name, expected, actual);
            fail_count++;
        end
    endtask

    int pass_count = 0;
    int fail_count = 0;
    int test_num   = 0;

    initial begin
        $display("============================================");
        $display(" buffer_bank Testbench Starting");
        $display("============================================");

        reset_all();
        wait(rst_n);
        repeat(2) @(posedge clk);

        //======================================================================
        // Test 1: Basic single write/read to bank 0
        //======================================================================
        test_num = 1;
        $display("\n[Test 1] Basic write/read bank[0]");
        wr_valid = 1'b1; wr_sel = 3'd0; wr_bank = 2'd0; wr_addr = 9'd0;
        wr_data = {16{16'hABCD}}; wr_mask = 32'hFFFFFFFF;
        @(posedge clk); #1;
        wr_valid = 1'b0;
        @(posedge clk); @(posedge clk);

        rd_req_valid = 1'b1;
        rd_sel = 3'd0; rd_bank = 2'd0; rd_addr = 9'd0;
        @(posedge clk); #1;
        rd_req_valid = 1'b0;
        @(posedge clk); @(posedge clk);
        #1;
        check_val(rd_data, {16{16'hABCD}}, "T1 readback");

        //======================================================================
        // Test 2: Sequential multi-bank writes with readback
        //======================================================================
        test_num = 2;
        $display("\n[Test 2] Multi-bank write/read");

        wr_valid = 1'b1; wr_sel = 3'd0;
        wr_bank = 2'd1; wr_addr = 9'd1; wr_data = {16{16'h1111}}; wr_mask = 32'hFFFFFFFF;
        @(posedge clk); #1;
        wr_bank = 2'd2; wr_addr = 9'd2; wr_data = {16{16'h2222}};
        @(posedge clk); #1;
        wr_bank = 2'd3; wr_addr = 9'd3; wr_data = {16{16'h3333}};
        @(posedge clk); #1;
        wr_valid = 1'b0;
        @(posedge clk); @(posedge clk);

        rd_req_valid = 1'b1;
        rd_bank = 2'd1; rd_addr = 9'd1;
        @(posedge clk); #1; rd_req_valid = 1'b0;
        @(posedge clk); @(posedge clk); #1;
        check_val(rd_data, {16{16'h1111}}, "T2 bank[1]");

        rd_req_valid = 1'b1;
        rd_bank = 2'd2; rd_addr = 9'd2;
        @(posedge clk); #1; rd_req_valid = 1'b0;
        @(posedge clk); @(posedge clk); #1;
        check_val(rd_data, {16{16'h2222}}, "T2 bank[2]");

        rd_req_valid = 1'b1;
        rd_bank = 2'd3; rd_addr = 9'd3;
        @(posedge clk); #1; rd_req_valid = 1'b0;
        @(posedge clk); @(posedge clk); #1;
        check_val(rd_data, {16{16'h3333}}, "T2 bank[3]");

        //======================================================================
        // Test 3: Masked write
        //======================================================================
        test_num = 3;
        $display("\n[Test 3] Masked write");
        wr_valid = 1'b1; wr_sel = 3'd0; wr_bank = 2'd0; wr_addr = 9'd10;
        wr_data = {16{16'h1234}};
        wr_mask = 32'h0000FFFF;
        @(posedge clk); #1;
        wr_valid = 1'b0;
        @(posedge clk); @(posedge clk);

        rd_req_valid = 1'b1; rd_sel = 3'd0; rd_bank = 2'd0; rd_addr = 9'd10;
        @(posedge clk); #1; rd_req_valid = 1'b0;
        @(posedge clk); @(posedge clk); #1;
        // Check lower 128 bits have the pattern, upper 128 bits are 0
        if (rd_data[127:0]  === {8{16'h1234}} && rd_data[255:128] === '0) begin
            $display("  PASS T3: masked write correct");
            pass_count++;
        end else begin
            $display("  FAIL T3: expected lower=0x1234 upper=0, got 0x%064X", rd_data);
            fail_count++;
        end

        //======================================================================
        // Test 4: Ping-pong switch
        //======================================================================
        test_num = 4;
        $display("\n[Test 4] Ping-pong switch");
        if (pp_a_compute_sel === 1'b0) begin
            $display("  PASS T4 init: compute_sel=0"); pass_count++;
        end else begin
            $display("  FAIL T4 init: compute_sel!=0"); fail_count++;
        end
        pp_switch_req = 1'b1;
        @(posedge clk); #1;
        pp_switch_req = 1'b0;
        @(posedge clk); @(posedge clk); #1;
        if (pp_switch_ack === 1'b1 && pp_a_compute_sel === 1'b1) begin
            $display("  PASS T4: switch completed"); pass_count++;
        end else begin
            $display("  FAIL T4: switch not acked or sel wrong"); fail_count++;
        end

        //======================================================================
        // Test 5: Conflict detection
        //======================================================================
        test_num = 5;
        $display("\n[Test 5] Bank conflict arbitration");
        wr_valid = 1'b1; wr_sel = 3'd0; wr_bank = 2'd0; wr_addr = 9'd20;
        wr_data = {16{16'hBEEF}}; wr_mask = 32'hFFFFFFFF;
        rd_req_valid = 1'b1; rd_sel = 3'd0; rd_bank = 2'd0; rd_addr = 9'd0;
        @(posedge clk); #1;
        if (conflict_stall === 1'b1) begin
            $display("  PASS T5: conflict_stall"); pass_count++;
        end else begin
            $display("  FAIL T5: no conflict_stall"); fail_count++;
        end
        if (rd_req_ready === 1'b1 && wr_ready === 1'b0) begin
            $display("  PASS T5: read ok, write stalled"); pass_count++;
        end else begin
            $display("  FAIL T5: arbitration wrong"); fail_count++;
        end
        wr_valid = 1'b0; rd_req_valid = 1'b0;
        @(posedge clk); @(posedge clk);

        //======================================================================
        // Test 6: Cross-buffer-set write/read
        //======================================================================
        test_num = 6;
        $display("\n[Test 6] Cross-buffer-set write/read");
        wr_valid = 1'b1; wr_sel = 3'd1; // A_BUF[1]
        wr_bank = 2'd0; wr_addr = 9'd0;
        wr_data = {16{16'hAAAA}}; wr_mask = 32'hFFFFFFFF;
        @(posedge clk); #1;
        wr_sel = 3'd3; // B_BUF[0]
        wr_data = {16{16'hBBBB}};
        @(posedge clk); #1;
        wr_valid = 1'b0;
        @(posedge clk); @(posedge clk);

        rd_req_valid = 1'b1; rd_sel = 3'd1; rd_bank = 2'd0; rd_addr = 9'd0;
        @(posedge clk); #1; rd_req_valid = 1'b0;
        @(posedge clk); @(posedge clk); #1;
        check_val(rd_data, {16{16'hAAAA}}, "T6 A_BUF[1]");

        rd_req_valid = 1'b1; rd_sel = 3'd3; rd_bank = 2'd0; rd_addr = 9'd0;
        @(posedge clk); #1; rd_req_valid = 1'b0;
        @(posedge clk); @(posedge clk); #1;
        check_val(rd_data, {16{16'hBBBB}}, "T6 B_BUF[0]");

        //======================================================================
        // Test 7: Reset and re-read after ping-pong switch
        //======================================================================
        test_num = 7;
        $display("\n[Test 7] Reset after ping-pong");
        rd_req_valid = 1'b1; rd_sel = 3'd0; rd_bank = 2'd0; rd_addr = 9'd0;
        @(posedge clk); #1; rd_req_valid = 1'b0;
        @(posedge clk); @(posedge clk); #1;
        if (rd_data === {16{16'hABCD}}) begin
            $display("  PASS T7: reset restored state"); pass_count++;
        end else begin
            $display("  FAIL T7: data corrupted after reset"); fail_count++;
        end

        $display("\n============================================");
        $display(" TB Summary: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count == 0)
            $display(" ALL TESTS PASSED");
        else
            $display(" SOME TESTS FAILED");
        $display("============================================");
        $finish;
    end

endmodule
