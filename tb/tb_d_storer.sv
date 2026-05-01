//------------------------------------------------------------------------------
// tb_d_storer.sv
// Testbench for d_storer + buffer_bank integration
//------------------------------------------------------------------------------

`timescale 1ns/1ps
`define SIMULATION

module tb_d_storer;

    localparam int P_M        = 2;
    localparam int P_N        = 2;
    localparam int ELEM_W     = 16;
    localparam int BUF_BANKS  = 4;
    localparam int BUF_DEPTH  = 512;
    localparam int AXI_DATA_W = 256;
    localparam int ELEM_PER_BEAT = AXI_DATA_W / ELEM_W;

    logic clk;
    logic rst_n;

    // Postproc interface
    logic              post_valid;
    wire               post_ready;
    logic [P_M*P_N*ELEM_W-1:0] post_data;
    logic              post_last;

    // Tile config
    logic [15:0]       tile_rows;
    logic [15:0]       tile_cols;
    logic [31:0]       tile_stride;
    logic [31:0]       base_addr;

    // Storer -> buffer_bank
    wire               buf_wr_valid;
    wire               buf_wr_ready;
    wire [2:0]         buf_wr_sel;
    wire [$clog2(BUF_BANKS)-1:0] buf_wr_bank;
    wire [$clog2(BUF_DEPTH)-1:0] buf_wr_addr;
    wire [AXI_DATA_W-1:0]        buf_wr_data;
    wire [AXI_DATA_W/8-1:0]      buf_wr_mask;

    // buffer_bank read interface
    logic              rd_req_valid;
    wire               rd_req_ready;
    logic [2:0]        rd_sel;
    logic [$clog2(BUF_BANKS)-1:0] rd_bank;
    logic [$clog2(BUF_DEPTH)-1:0] rd_addr;
    wire               rd_data_valid;
    wire [AXI_DATA_W-1:0]        rd_data;

    // Status
    wire               store_done;
    wire               store_err;

    d_storer #(
        .P_M(P_M), .P_N(P_N), .ELEM_W(ELEM_W),
        .BUF_BANKS(BUF_BANKS), .BUF_DEPTH(BUF_DEPTH), .AXI_DATA_W(AXI_DATA_W)
    ) u_storer (
        .clk(clk), .rst_n(rst_n),
        .post_valid(post_valid), .post_ready(post_ready),
        .post_data(post_data), .post_last(post_last),
        .tile_rows(tile_rows), .tile_cols(tile_cols),
        .tile_stride(tile_stride), .base_addr(base_addr),
        .buf_wr_valid(buf_wr_valid), .buf_wr_ready(buf_wr_ready),
        .buf_wr_sel(buf_wr_sel), .buf_wr_bank(buf_wr_bank),
        .buf_wr_addr(buf_wr_addr), .buf_wr_data(buf_wr_data), .buf_wr_mask(buf_wr_mask),
        .store_done(store_done), .store_err(store_err)
    );

    buffer_bank #(
        .P_M(P_M), .P_N(P_N), .ELEM_W(ELEM_W), .ACC_W(32),
        .BUF_BANKS(BUF_BANKS), .BUF_DEPTH(BUF_DEPTH),
        .AXI_DATA_W(AXI_DATA_W), .PP_ENABLE(1'b1)
    ) u_buf (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(buf_wr_valid), .wr_ready(buf_wr_ready),
        .wr_sel(buf_wr_sel), .wr_bank(buf_wr_bank), .wr_addr(buf_wr_addr),
        .wr_data(buf_wr_data), .wr_mask(buf_wr_mask),
        .rd_req_valid(rd_req_valid), .rd_req_ready(rd_req_ready),
        .rd_sel(rd_sel), .rd_bank(rd_bank), .rd_addr(rd_addr),
        .rd_data_valid(rd_data_valid), .rd_data(rd_data),
        .pp_switch_req(1'b0), .pp_switch_ack(),
        .pp_a_compute_sel(), .pp_b_compute_sel(),
        .pp_a_load_sel(), .pp_b_load_sel(),
        .conflict_stall(), .bank_occ()
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

    int pass_count = 0;
    int fail_count = 0;
    reg store_done_seen;

    always @(posedge clk) begin
        if (rst_n && store_done) store_done_seen <= 1'b1;
    end

    task automatic check_val(logic [AXI_DATA_W-1:0] actual, logic [AXI_DATA_W-1:0] expected, string name);
        if (actual === expected) begin
            $display("  PASS %s", name);
            pass_count++;
        end else begin
            $display("  FAIL %s: expected=0x%032X actual=0x%032X", name, expected, actual);
            fail_count++;
        end
    endtask

    // Helper: pack P_M*P_N elements into post_data (LSB-first order)
    function automatic [P_M*P_N*ELEM_W-1:0] pack_post(input int base);
        reg [P_M*P_N*ELEM_W-1:0] result;
        begin
            result = '0;
            for (int r = 0; r < P_M; r++) begin
                for (int c = 0; c < P_N; c++) begin
                    int elem_idx = r * P_N + c;
                    int val = base + elem_idx;
                    result[elem_idx * ELEM_W +: ELEM_W] = val[15:0];
                end
            end
            pack_post = result;
        end
    endfunction

    initial begin
        $display("============================================");
        $display(" d_storer + buffer_bank Testbench");
        $display("============================================");

        tile_rows   = 16'd2;
        tile_cols   = 16'd16;
        tile_stride = 32'd32;
        base_addr   = 32'd0;

        post_valid  = 1'b0;
        post_data   = '0;
        post_last   = 1'b0;
        rd_req_valid= 1'b0;
        rd_sel      = 3'd4;
        rd_bank     = '0;
        rd_addr     = '0;

        wait(rst_n);
        repeat(2) @(posedge clk);

        //======================================================================
        // Test 1: Basic 2x16 tile, row-major
        // P_M=2, P_N=2 means 4 elements per postproc cycle.
        // tile_rows=2, tile_cols=16: 2 rows, 16 cols.
        // Each row = 16 elements = 1 beat (16 elements per beat).
        // Total postproc cycles = (2/2) * (16/2) = 8 cycles.
        //======================================================================
        $display("\n[Test 1] Basic 2x16 tile row-major (8 post cycles)");
        store_done_seen = 1'b0;

        // Send 8 postproc beats
        for (int i = 0; i < 8; i++) begin
            @(negedge clk);
            post_valid = 1'b1;
            post_data  = pack_post(i * 4);
            post_last  = (i == 7) ? 1'b1 : 1'b0;
            @(posedge clk); #1;
            post_valid = 1'b0;
            if (i == 7) post_last = 1'b0;
            @(posedge clk); @(posedge clk);
        end

        if (store_done_seen === 1'b1) begin
            $display("  PASS T1: store_done asserted"); pass_count++;
        end else begin
            $display("  FAIL T1: store_done missing"); fail_count++;
        end

        // Read back row 0: bank 0 addr 0
        // Row 0 elements (only even columns from each cycle): 0,1,4,5,8,9,12,13,16,17,20,21,24,25,28,29
        @(negedge clk);
        rd_req_valid = 1'b1; rd_sel = 3'd4; rd_bank = 2'd0; rd_addr = 9'd0;
        @(posedge clk); #1; rd_req_valid = 1'b0;
        @(posedge clk); @(posedge clk); #1;
        check_val(rd_data, {16'h001D,16'h001C,16'h0019,16'h0018,16'h0015,16'h0014,16'h0011,16'h0010,
                            16'h000D,16'h000C,16'h0009,16'h0008,16'h0005,16'h0004,16'h0001,16'h0000}, "T1 row0");

        // Read back row 1: bank 1 addr 0
        // Row 1 elements (odd columns from each cycle): 2,3,6,7,10,11,14,15,18,19,22,23,26,27,30,31
        @(negedge clk);
        rd_req_valid = 1'b1; rd_sel = 3'd4; rd_bank = 2'd1; rd_addr = 9'd0;
        @(posedge clk); #1; rd_req_valid = 1'b0;
        @(posedge clk); @(posedge clk); #1;
        check_val(rd_data, {16'h001F,16'h001E,16'h001B,16'h001A,16'h0017,16'h0016,16'h0013,16'h0012,
                            16'h000F,16'h000E,16'h000B,16'h000A,16'h0007,16'h0006,16'h0003,16'h0002}, "T1 row1");

        //======================================================================
        // Test 2: Boundary tile (1 row, 2 cols)
        //======================================================================
        $display("\n[Test 2] Boundary tile 1x2");
        tile_rows   = 16'd1;
        tile_cols   = 16'd2;
        tile_stride = 32'd4;
        base_addr   = 32'd64;  // Different address to avoid T1 data

        @(negedge clk);
        post_valid = 1'b1;
        // Only 2 elements valid: r=0 gets elem0=EF01, elem1=ABCD
        post_data = {48'h0, 16'hABCD, 16'hEF01};  // elem order: {r1c1, r1c0, r0c1, r0c0}
        post_last = 1'b1;
        @(posedge clk); #1;
        post_valid = 1'b0;
        post_last = 1'b0;
        @(posedge clk); @(posedge clk);

        // Read back: base_addr=64, beat_idx=64/32=2, bank=2 addr=0
        @(negedge clk);
        rd_req_valid = 1'b1; rd_sel = 3'd4; rd_bank = 2'd2; rd_addr = 9'd0;
        @(posedge clk); #1; rd_req_valid = 1'b0;
        @(posedge clk); @(posedge clk); #1;

        if (rd_data[15:0] === 16'hEF01 && rd_data[31:16] === 16'hABCD && rd_data[255:32] === '0) begin
            $display("  PASS T2: boundary mask correct"); pass_count++;
        end else begin
            $display("  FAIL T2: boundary mask wrong, got 0x%064X", rd_data);
            fail_count++;
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
