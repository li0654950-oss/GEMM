//------------------------------------------------------------------------------
// tb_a_loader.sv
// Testbench for a_loader + buffer_bank integration
//------------------------------------------------------------------------------

`timescale 1ns/1ps
`define SIMULATION

module tb_a_loader;

    localparam int P_M        = 2;
    localparam int P_N        = 2;
    localparam int ELEM_W     = 16;
    localparam int BUF_BANKS  = 4;
    localparam int BUF_DEPTH  = 512;
    localparam int AXI_DATA_W = 256;
    localparam int ELEM_PER_BEAT = AXI_DATA_W / ELEM_W;
    localparam int ELEM_BYTES = ELEM_W / 8;

    logic clk;
    logic rst_n;

    // DMA interface
    logic              dma_valid;
    wire               dma_ready;
    logic [AXI_DATA_W-1:0] dma_data;
    logic              dma_last;

    // Tile config
    logic [15:0]       tile_rows;
    logic [15:0]       tile_cols;
    logic [31:0]       tile_stride;
    logic [31:0]       base_addr;
    logic              pp_sel;

    // Loader -> buffer_bank
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
    wire               load_done;
    wire               load_err;

    a_loader #(
        .P_M(P_M), .P_N(P_N), .ELEM_W(ELEM_W),
        .BUF_BANKS(BUF_BANKS), .BUF_DEPTH(BUF_DEPTH), .AXI_DATA_W(AXI_DATA_W)
    ) u_loader (
        .clk(clk), .rst_n(rst_n),
        .dma_valid(dma_valid), .dma_ready(dma_ready),
        .dma_data(dma_data), .dma_last(dma_last),
        .tile_rows(tile_rows), .tile_cols(tile_cols),
        .tile_stride(tile_stride), .base_addr(base_addr), .pp_sel(pp_sel),
        .buf_wr_valid(buf_wr_valid), .buf_wr_ready(buf_wr_ready),
        .buf_wr_sel(buf_wr_sel), .buf_wr_bank(buf_wr_bank),
        .buf_wr_addr(buf_wr_addr), .buf_wr_data(buf_wr_data), .buf_wr_mask(buf_wr_mask),
        .load_done(load_done), .load_err(load_err)
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
    reg load_done_seen;

    always @(posedge clk) begin
        if (rst_n && load_done) load_done_seen <= 1'b1;
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

    initial begin
        $display("============================================");
        $display(" a_loader + buffer_bank Testbench");
        $display("============================================");

        // Default config: small tile for quick test
        tile_rows   = 16'd2;   // 2 rows
        tile_cols   = 16'd16;  // 16 cols = 1 beat per row
        tile_stride = 32'd32;  // 16 cols * 2 bytes = 32 bytes per row
        base_addr   = 32'd0;
        pp_sel      = 1'b0;    // A_BUF[0]

        dma_valid   = 1'b0;
        dma_data    = '0;
        dma_last    = 1'b0;
        rd_req_valid= 1'b0;
        rd_sel      = 3'd0;
        rd_bank     = '0;
        rd_addr     = '0;

        wait(rst_n);
        repeat(2) @(posedge clk);

        //======================================================================
        // Test 1: Basic 2-row tile, each row = 1 beat (16 elements)
        //======================================================================
        $display("\n[Test 1] Basic 2x16 tile row-major");
        load_done_seen = 1'b0;

        // Row 0: all 0x1111
        @(negedge clk);
        dma_valid = 1'b1;
        dma_data  = {16{16'h1111}};
        dma_last  = 1'b0;
        @(posedge clk); #1;
        dma_valid = 1'b0;
        @(posedge clk); @(posedge clk); // wait for write to complete

        // Row 1: all 0x2222
        @(negedge clk);
        dma_valid = 1'b1;
        dma_data  = {16{16'h2222}};
        dma_last  = 1'b1;
        @(posedge clk); #1;
        dma_valid = 1'b0;
        dma_last  = 1'b0;
        @(posedge clk); @(posedge clk);

        // Check load_done pulse
        if (load_done_seen === 1'b1) begin
            $display("  PASS T1: load_done asserted"); pass_count++;
        end else begin
            $display("  FAIL T1: load_done missing"); fail_count++;
        end

        // Read back row 0 from bank 0 addr 0
        @(negedge clk);
        rd_req_valid = 1'b1; rd_sel = 3'd0; rd_bank = 2'd0; rd_addr = 9'd0;
        @(posedge clk); #1; rd_req_valid = 1'b0;
        @(posedge clk); @(posedge clk); #1;
        check_val(rd_data, {16{16'h1111}}, "T1 row0 readback");

        // Read back row 1 from bank 1 addr 0
        @(negedge clk);
        rd_req_valid = 1'b1; rd_sel = 3'd0; rd_bank = 2'd1; rd_addr = 9'd0;
        @(posedge clk); #1; rd_req_valid = 1'b0;
        @(posedge clk); @(posedge clk); #1;
        check_val(rd_data, {16{16'h2222}}, "T1 row1 readback");

        //======================================================================
        // Test 2: Boundary tile (1 row, 2 elements)
        //======================================================================
        $display("\n[Test 2] Boundary tile 1x2");
        tile_rows   = 16'd1;
        tile_cols   = 16'd2;
        tile_stride = 32'd4;
        base_addr   = 32'd0;

        // 1 beat with only first 2 elements valid
        @(negedge clk);
        dma_valid = 1'b1;
        dma_data  = {224'h0, 16'hABCD, 16'hEF01};
        dma_last  = 1'b1;
        @(posedge clk); #1;
        dma_valid = 1'b0;
        dma_last  = 1'b0;
        @(posedge clk); @(posedge clk);

        @(negedge clk);
        rd_req_valid = 1'b1; rd_sel = 3'd0; rd_bank = 2'd0; rd_addr = 9'd0;
        @(posedge clk); #1; rd_req_valid = 1'b0;
        @(posedge clk); @(posedge clk); #1;

        if (rd_data[15:0] === 16'hEF01) begin
            $display("  PASS T2: boundary mask correct"); pass_count++;
        end else begin
            $display("  FAIL T2: boundary mask wrong, got 0x%064X", rd_data);
            fail_count++;
        end

        //======================================================================
        // Test 3: Multi-beat row (tile_cols=32 = 2 beats per row)
        //======================================================================
        $display("\n[Test 3] Multi-beat row tile 1x32");
        tile_rows   = 16'd1;
        tile_cols   = 16'd32;
        tile_stride = 32'd64;
        base_addr   = 32'd0;

        // Beat 0
        @(negedge clk);
        dma_valid = 1'b1;
        dma_data  = {16{16'h3333}};
        dma_last  = 1'b0;
        @(posedge clk); #1;
        dma_valid = 1'b0;
        @(posedge clk); @(posedge clk);

        // Beat 1 (last)
        @(negedge clk);
        dma_valid = 1'b1;
        dma_data  = {16{16'h4444}};
        dma_last  = 1'b1;
        @(posedge clk); #1;
        dma_valid = 1'b0;
        dma_last  = 1'b0;
        @(posedge clk); @(posedge clk);

        // Read back addr 0 and addr 1
        @(negedge clk);
        rd_req_valid = 1'b1; rd_sel = 3'd0; rd_bank = 2'd0; rd_addr = 9'd0;
        @(posedge clk); #1; rd_req_valid = 1'b0;
        @(posedge clk); @(posedge clk); #1;
        check_val(rd_data, {16{16'h3333}}, "T3 beat0");

        @(negedge clk);
        rd_req_valid = 1'b1; rd_sel = 3'd0; rd_bank = 2'd1; rd_addr = 9'd0;
        @(posedge clk); #1; rd_req_valid = 1'b0;
        @(posedge clk); @(posedge clk); #1;
        check_val(rd_data, {16{16'h4444}}, "T3 beat1");

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
