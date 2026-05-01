//------------------------------------------------------------------------------
// tb_postproc.sv
// Testbench for postproc + fp_add_c + fp_round_sat
//
// Test Plan (from spec/postprocess_numeric_spec.md Section 10):
//   T1: bypass mode - acc passes through without C fusion
//   T2: add_c mode - acc + C tile fusion
//   T3: round modes (RNE/RTZ/RUP/RDN) with tie-breaking edge case
//   T4: NaN propagation
//   T5: Inf handling
//   T6: overflow with saturation (sat_en=1)
//   T7: overflow to Inf (sat_en=0)
//   T8: underflow flush to zero
//   T9: lane mask - partial lane disable
//   T10: backpressure - d_ready=0 stalls pipeline
//   T11: reset clears pipeline and counters
//   T12: DENORM input flush to zero
//------------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_postproc;

    localparam int P_M    = 2;
    localparam int P_N    = 2;
    localparam int ELEM_W = 16;
    localparam int ACC_W  = 32;
    localparam int LANES  = P_M * P_N;

    // DUT signals
    logic                  clk;
    logic                  rst_n;
    logic                  pp_start;
    logic                  pp_busy;
    logic                  pp_done;
    logic                  pp_err;
    logic                  add_c_en;
    logic [1:0]            round_mode;
    logic                  sat_en;
    logic [LANES-1:0]      tile_mask;
    logic                  acc_valid;
    logic [LANES*ACC_W-1:0] acc_data;
    logic                  acc_last;
    logic                  c_valid;
    logic                  c_ready;
    logic [LANES*ELEM_W-1:0] c_data;
    logic                  c_last;
    logic                  d_valid;
    logic                  d_ready;
    logic [LANES*ELEM_W-1:0] d_data;
    logic                  d_last;
    logic [LANES-1:0]      d_mask;
    logic [15:0]           exc_nan_cnt;
    logic [15:0]           exc_inf_cnt;
    logic [15:0]           exc_ovf_cnt;
    logic [15:0]           exc_udf_cnt;
    logic [15:0]           exc_denorm_cnt;

    // Clock
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // DUT
    postproc #(
        .P_M    (P_M),
        .P_N    (P_N),
        .ELEM_W (ELEM_W),
        .ACC_W  (ACC_W),
        .LANES  (LANES)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .pp_start       (pp_start),
        .pp_busy        (pp_busy),
        .pp_done        (pp_done),
        .pp_err         (pp_err),
        .add_c_en       (add_c_en),
        .round_mode     (round_mode),
        .sat_en         (sat_en),
        .tile_mask      (tile_mask),
        .acc_valid      (acc_valid),
        .acc_data       (acc_data),
        .acc_last       (acc_last),
        .c_valid        (c_valid),
        .c_ready        (c_ready),
        .c_data         (c_data),
        .c_last         (c_last),
        .d_valid        (d_valid),
        .d_ready        (d_ready),
        .d_data         (d_data),
        .d_last         (d_last),
        .d_mask         (d_mask),
        .exc_nan_cnt    (exc_nan_cnt),
        .exc_inf_cnt    (exc_inf_cnt),
        .exc_ovf_cnt    (exc_ovf_cnt),
        .exc_udf_cnt    (exc_udf_cnt),
        .exc_denorm_cnt (exc_denorm_cnt)
    );

    // Helper: construct FP32 from real
    function automatic logic [31:0] real_to_fp32(real val);
        logic [63:0] bits;
        logic sign;
        logic [10:0] exp64;
        logic [51:0] mant64;
        logic [7:0]  exp32;
        begin
            bits   = $realtobits(val);
            sign   = bits[63];
            exp64  = bits[62:52];
            mant64 = bits[51:0];
            if (exp64 == 11'h000) begin
                real_to_fp32 = {sign, 31'b0};
            end else if (exp64 == 11'h7FF) begin
                real_to_fp32 = {sign, 8'hFF, mant64[51:29]};
            end else begin
                if (exp64 < 11'd896) begin
                    real_to_fp32 = {sign, 31'b0};
                end else if (exp64 > 11'd1151) begin
                    real_to_fp32 = {sign, 8'hFF, 23'b0};
                end else begin
                    real_to_fp32 = {sign, exp64 - 11'd896, mant64[51:29]};
                end
            end
        end
    endfunction

    // Helper: construct FP16 from real
    function automatic logic [15:0] real_to_fp16(real val);
        logic [31:0] f32;
        logic sign;
        logic [7:0]  exp32;
        logic [22:0] mant32;
        logic [4:0]  exp16;
        logic [9:0]  mant16;
        begin
            f32 = real_to_fp32(val);
            sign   = f32[31];
            exp32  = f32[30:23];
            mant32 = f32[22:0];
            if (exp32 == 8'h00) begin
                real_to_fp16 = {sign, 15'b0};
            end else if (exp32 >= 8'hFF) begin
                real_to_fp16 = {sign, 5'b11111, mant32[22:13]};
            end else begin
                if (exp32 < 8'd112) begin
                    real_to_fp16 = {sign, 15'b0};
                end else if (exp32 > 8'd142) begin
                    real_to_fp16 = {sign, 5'b11111, 10'b0};
                end else begin
                    exp16  = exp32 - 8'd112;
                    mant16 = mant32[22:13];
                    real_to_fp16 = {sign, exp16[4:0], mant16};
                end
            end
        end
    endfunction

    // Task: send one tile beat
    task automatic send_beat(
        logic [LANES*ACC_W-1:0] acc,
        logic                   last,
        logic [LANES*ELEM_W-1:0] c = '0,
        logic                   c_last_in = 1'b0
    );
        acc_data <= acc;
        acc_valid <= 1'b1;
        acc_last <= last;
        if (add_c_en) begin
            c_data <= c;
            c_valid <= 1'b1;
            c_last <= c_last_in;
        end else begin
            c_valid <= 1'b0;
            c_last <= 1'b0;
        end
        @(posedge clk);
        acc_valid <= 1'b0;
        c_valid <= 1'b0;
    endtask

    // Task: wait for d_valid and check
    task automatic wait_output(
        input logic [LANES*ELEM_W-1:0] expected,
        input logic expected_last,
        input logic [LANES-1:0] expected_mask,
        ref int errors,
        input string test_name
    );
        // Wait up to 10 cycles for output
        int timeout;
        timeout = 0;
        while (!d_valid && timeout < 10) begin
            @(posedge clk);
            timeout++;
        end
        if (!d_valid) begin
            $error("  [%s] FAIL: d_valid never arrived", test_name);
            errors++;
            return;
        end
        @(negedge clk);
        if (d_data !== expected) begin
            $error("  [%s] FAIL: d_data mismatch. Expected 0x%04X, got 0x%04X", test_name, expected, d_data);
            errors++;
        end else begin
            $display("  [%s] PASS: d_data = 0x%04X", test_name, d_data);
        end
        if (d_last !== expected_last) begin
            $error("  [%s] FAIL: d_last mismatch. Expected %b, got %b", test_name, expected_last, d_last);
            errors++;
        end
        if (d_mask !== expected_mask) begin
            $error("  [%s] FAIL: d_mask mismatch. Expected %b, got %b", test_name, expected_mask, d_mask);
            errors++;
        end
    endtask

    // Stimulus
    int errors;
    logic [LANES*ACC_W-1:0] acc_vec;
    logic [LANES*ELEM_W-1:0] c_vec;
    logic [LANES*ELEM_W-1:0] expected_d;
    logic [LANES-1:0] expected_mask;

    initial begin
        errors = 0;

        $display("================================================");
        $display(" postproc Testbench Starting");
        $display("================================================");

        // Init
        rst_n      = 1'b0;
        pp_start   = 1'b0;
        add_c_en   = 1'b0;
        round_mode = 2'b00;
        sat_en     = 1'b1;
        tile_mask  = {LANES{1'b1}};
        acc_valid  = 1'b0;
        acc_data   = '0;
        acc_last   = 1'b0;
        c_valid    = 1'b0;
        c_data     = '0;
        c_last     = 1'b0;
        d_ready    = 1'b1;

        @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        //------------------------------------------------------------------
        // T1: bypass mode - acc passes straight through
        //------------------------------------------------------------------
        $display("\n[Test 1] Bypass mode...");
        add_c_en  = 1'b0;
        sat_en    = 1'b1;
        round_mode= 2'b00;  // RNE
        tile_mask = 4'b1111;
        acc_vec   = {4{real_to_fp32(1.0)}};  // all lanes = 1.0
        expected_d= {4{real_to_fp16(1.0)}};   // expect 0x3C00
        expected_mask = 4'b1111;

        pp_start = 1'b1;
        @(posedge clk);
        pp_start = 1'b0;
        @(posedge clk);

        send_beat(acc_vec, 1'b1);
        wait_output(expected_d, 1'b1, expected_mask, errors, "T1");

        // Wait for pp_done
        @(posedge clk);
        if (!pp_done) @(posedge clk);
        if (!pp_done) begin
            $error("  [T1] FAIL: pp_done not asserted");
            errors++;
        end else begin
            $display("  [T1] PASS: pp_done asserted");
        end

        // Check counters are zero
        if (exc_nan_cnt != 0 || exc_inf_cnt != 0 || exc_ovf_cnt != 0 ||
            exc_udf_cnt != 0 || exc_denorm_cnt != 0) begin
            $error("  [T1] FAIL: counters should be zero");
            errors++;
        end
        @(posedge clk);
        @(posedge clk);

        //------------------------------------------------------------------
        // T2: add_c mode - acc + C fusion
        //------------------------------------------------------------------
        $display("\n[Test 2] Add C fusion...");
        add_c_en  = 1'b1;
        sat_en    = 1'b1;
        round_mode= 2'b00;
        tile_mask = 4'b1111;
        acc_vec   = {4{real_to_fp32(1.0)}};  // acc = 1.0
        c_vec     = {4{real_to_fp16(2.0)}};  // C = 2.0
        expected_d= {4{real_to_fp16(3.0)}};   // expect 3.0

        pp_start = 1'b1;
        @(posedge clk);
        pp_start = 1'b0;
        @(posedge clk);

        send_beat(acc_vec, 1'b1, c_vec, 1'b1);
        wait_output(expected_d, 1'b1, expected_mask, errors, "T2");
        @(posedge clk);
        if (!pp_done) @(posedge clk);
        if (!pp_done) begin
            $error("  [T2] FAIL: pp_done not asserted");
            errors++;
        end else begin
            $display("  [T2] PASS: pp_done asserted");
        end
        @(posedge clk);
        @(posedge clk);

        //------------------------------------------------------------------
        // T3: round modes (RNE/RTZ/RUP/RDN)
        //------------------------------------------------------------------
        $display("\n[Test 3] Round modes...");
        add_c_en  = 1'b0;
        sat_en    = 1'b1;
        tile_mask = 4'b1111;

        // Test value: 0x3F803000 = 1.00146484375, exactly halfway between
        // 0x3C01 (1.0009765625) and 0x3C02 (1.001953125)
        // RNE: tie, base mant16=1 (odd) → round up → 0x3C02
        // RTZ: truncate → 0x3C01
        // RUP: positive, round up → 0x3C02
        // RDN: positive, round down → 0x3C01

        // Test RNE
        round_mode = 2'b00;
        acc_vec = {4{32'h3F803000}};
        expected_d = {4{16'h3C02}};
        pp_start = 1'b1;
        @(posedge clk);
        pp_start = 1'b0;
        @(posedge clk);
        send_beat(acc_vec, 1'b1);
        wait_output(expected_d, 1'b1, expected_mask, errors, "T3-RNE");
        @(posedge clk); @(posedge clk); @(posedge clk);

        // Test RTZ
        round_mode = 2'b01;
        expected_d = {4{16'h3C01}};
        pp_start = 1'b1;
        @(posedge clk);
        pp_start = 1'b0;
        @(posedge clk);
        send_beat(acc_vec, 1'b1);
        wait_output(expected_d, 1'b1, expected_mask, errors, "T3-RTZ");
        @(posedge clk); @(posedge clk); @(posedge clk);

        // Test RUP
        round_mode = 2'b10;
        expected_d = {4{16'h3C02}};
        pp_start = 1'b1;
        @(posedge clk);
        pp_start = 1'b0;
        @(posedge clk);
        send_beat(acc_vec, 1'b1);
        wait_output(expected_d, 1'b1, expected_mask, errors, "T3-RUP");
        @(posedge clk); @(posedge clk); @(posedge clk);

        // Test RDN
        round_mode = 2'b11;
        expected_d = {4{16'h3C01}};
        pp_start = 1'b1;
        @(posedge clk);
        pp_start = 1'b0;
        @(posedge clk);
        send_beat(acc_vec, 1'b1);
        wait_output(expected_d, 1'b1, expected_mask, errors, "T3-RDN");
        @(posedge clk); @(posedge clk); @(posedge clk);

        //------------------------------------------------------------------
        // T4: NaN propagation
        //------------------------------------------------------------------
        $display("\n[Test 4] NaN handling...");
        round_mode = 2'b00;
        add_c_en   = 1'b0;
        acc_vec    = {4{32'h7FC00000}};  // QNaN
        expected_d = {4{16'h7E00}};       // FP16 QNaN
        pp_start = 1'b1;
        @(posedge clk);
        pp_start = 1'b0;
        @(posedge clk);
        send_beat(acc_vec, 1'b1);
        wait_output(expected_d, 1'b1, expected_mask, errors, "T4");
        @(posedge clk);
        if (exc_nan_cnt != 1) begin
            $error("  [T4] FAIL: exc_nan_cnt=%d, expected 1", exc_nan_cnt);
            errors++;
        end else begin
            $display("  [T4] PASS: NaN counter = 1");
        end
        @(posedge clk); @(posedge clk); @(posedge clk);

        //------------------------------------------------------------------
        // T5: Inf handling
        //------------------------------------------------------------------
        $display("\n[Test 5] Inf handling...");
        acc_vec    = {4{32'h7F800000}};  // +Inf
        expected_d = {4{16'h7C00}};       // FP16 +Inf
        pp_start = 1'b1;
        @(posedge clk);
        pp_start = 1'b0;
        @(posedge clk);
        send_beat(acc_vec, 1'b1);
        wait_output(expected_d, 1'b1, expected_mask, errors, "T5");
        @(posedge clk);
        if (exc_inf_cnt != 1) begin
            $error("  [T5] FAIL: exc_inf_cnt=%d, expected 1", exc_inf_cnt);
            errors++;
        end else begin
            $display("  [T5] PASS: Inf counter = 1");
        end
        @(posedge clk); @(posedge clk); @(posedge clk);

        //------------------------------------------------------------------
        // T6: overflow with saturation
        //------------------------------------------------------------------
        $display("\n[Test 6] Overflow with saturation...");
        sat_en     = 1'b1;
        acc_vec    = {4{32'h47800000}};  // 65536, > FP16 max 65504
        expected_d = {4{16'h7BFF}};       // FP16 +max
        pp_start = 1'b1;
        @(posedge clk);
        pp_start = 1'b0;
        @(posedge clk);
        send_beat(acc_vec, 1'b1);
        wait_output(expected_d, 1'b1, expected_mask, errors, "T6");
        @(posedge clk);
        if (exc_ovf_cnt != 1) begin
            $error("  [T6] FAIL: exc_ovf_cnt=%d, expected 1", exc_ovf_cnt);
            errors++;
        end else begin
            $display("  [T6] PASS: OVF counter = 1");
        end
        @(posedge clk); @(posedge clk); @(posedge clk);

        //------------------------------------------------------------------
        // T7: overflow to Inf (sat_en=0)
        //------------------------------------------------------------------
        $display("\n[Test 7] Overflow to Inf (sat_en=0)...");
        sat_en     = 1'b0;
        acc_vec    = {4{32'h47800000}};  // 65536, > FP16 max 65504
        expected_d = {4{16'h7C00}};       // +Inf
        pp_start = 1'b1;
        @(posedge clk);
        pp_start = 1'b0;
        @(posedge clk);
        send_beat(acc_vec, 1'b1);
        wait_output(expected_d, 1'b1, expected_mask, errors, "T7");
        @(posedge clk);
        if (exc_ovf_cnt != 2 || exc_inf_cnt != 2) begin
            $error("  [T7] FAIL: counters wrong. ovf=%d inf=%d, expected 2,2", exc_ovf_cnt, exc_inf_cnt);
            errors++;
        end else begin
            $display("  [T7] PASS: OVF+Inf counters incremented");
        end
        @(posedge clk); @(posedge clk); @(posedge clk);

        //------------------------------------------------------------------
        // T8: underflow
        //------------------------------------------------------------------
        $display("\n[Test 8] Underflow flush to zero...");
        sat_en     = 1'b1;
        acc_vec    = {4{32'h33000000}};  // 2^-25, < 2^-24
        expected_d = {4{16'h0000}};       // zero
        pp_start = 1'b1;
        @(posedge clk);
        pp_start = 1'b0;
        @(posedge clk);
        send_beat(acc_vec, 1'b1);
        wait_output(expected_d, 1'b1, expected_mask, errors, "T8");
        @(posedge clk);
        if (exc_udf_cnt != 1) begin
            $error("  [T8] FAIL: exc_udf_cnt=%d, expected 1", exc_udf_cnt);
            errors++;
        end else begin
            $display("  [T8] PASS: UDF counter = 1");
        end
        @(posedge clk); @(posedge clk); @(posedge clk);

        //------------------------------------------------------------------
        // T9: lane mask
        //------------------------------------------------------------------
        $display("\n[Test 9] Lane mask (partial disable)...");
        tile_mask  = 4'b0011;  // only lanes 0,1 active
        expected_mask = 4'b0011;
        acc_vec    = {real_to_fp32(4.0), real_to_fp32(3.0), real_to_fp32(2.0), real_to_fp32(1.0)};
        expected_d = {16'h0000, 16'h0000, real_to_fp16(2.0), real_to_fp16(1.0)};
        pp_start = 1'b1;
        @(posedge clk);
        pp_start = 1'b0;
        @(posedge clk);
        send_beat(acc_vec, 1'b1);
        wait_output(expected_d, 1'b1, expected_mask, errors, "T9");
        @(posedge clk); @(posedge clk); @(posedge clk);

        //------------------------------------------------------------------
        // T10: backpressure
        //------------------------------------------------------------------
        $display("\n[Test 10] Backpressure (d_ready=0)...");
        tile_mask  = 4'b1111;
        expected_mask = 4'b1111;
        acc_vec    = {4{real_to_fp32(5.0)}};
        expected_d = {4{real_to_fp16(5.0)}};

        pp_start = 1'b1;
        @(posedge clk);
        pp_start = 1'b0;
        @(posedge clk);

        send_beat(acc_vec, 1'b1);

        // Wait 2 cycles, then deassert d_ready
        @(posedge clk);
        @(posedge clk);
        d_ready = 1'b0;

        // Wait a few cycles with d_ready=0
        @(posedge clk);
        @(posedge clk);
        @(posedge clk);

        // d_valid should be high, data should be stable
        @(negedge clk);
        if (!d_valid) begin
            $error("  [T10] FAIL: d_valid should be high during backpressure");
            errors++;
        end else if (d_data !== expected_d) begin
            $error("  [T10] FAIL: d_data changed during backpressure");
            errors++;
        end else begin
            $display("  [T10] PASS: d_valid held, data stable");
        end

        // Re-assert d_ready, allow consumption
        d_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        if (d_data !== expected_d) begin
            $error("  [T10] FAIL: d_data wrong after backpressure release");
            errors++;
        end else begin
            $display("  [T10] PASS: data correct after backpressure release");
        end
        @(posedge clk); @(posedge clk); @(posedge clk);

        //------------------------------------------------------------------
        // T11: reset clears pipeline and counters
        //------------------------------------------------------------------
        $display("\n[Test 11] Reset clears counters...");
        rst_n = 1'b0;
        @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        @(negedge clk);

        if (pp_busy || pp_done || pp_err || d_valid ||
            exc_nan_cnt != 0 || exc_inf_cnt != 0 || exc_ovf_cnt != 0 ||
            exc_udf_cnt != 0 || exc_denorm_cnt != 0) begin
            $error("  [T11] FAIL: state not cleared after reset");
            errors++;
        end else begin
            $display("  [T11] PASS: All cleared after reset");
        end
        @(posedge clk); @(posedge clk);

        //------------------------------------------------------------------
        // T12: DENORM input
        //------------------------------------------------------------------
        $display("\n[Test 12] DENORM input...");
        add_c_en   = 1'b0;
        sat_en     = 1'b1;
        round_mode = 2'b00;
        tile_mask  = 4'b1111;
        acc_vec    = {4{32'h00000001}};  // FP32 smallest subnormal
        expected_d = {4{16'h0000}};       // flush to zero
        pp_start = 1'b1;
        @(posedge clk);
        pp_start = 1'b0;
        @(posedge clk);
        send_beat(acc_vec, 1'b1);
        wait_output(expected_d, 1'b1, expected_mask, errors, "T12");
        @(posedge clk);
        if (exc_denorm_cnt != 1) begin
            $error("  [T12] FAIL: exc_denorm_cnt=%d, expected 1", exc_denorm_cnt);
            errors++;
        end else begin
            $display("  [T12] PASS: DENORM counter = 1");
        end

        //------------------------------------------------------------------
        // Summary
        //------------------------------------------------------------------
        $display("\n================================================");
        if (errors == 0) begin
            $display(" ALL TESTS PASSED (12/12)");
        end else begin
            $display(" TEST FAILED: %d error(s)", errors);
        end
        $display("================================================");

        $finish;
    end

endmodule : tb_postproc
