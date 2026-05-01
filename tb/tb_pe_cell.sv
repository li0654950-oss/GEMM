//------------------------------------------------------------------------------
// tb_pe_cell.sv
// Testbench for pe_cell
//
// Test plan (from spec/systolic_compute_core_spec.md Section 10):
//   1. Basic MAC: multiple cycles of valid a/b, check accumulator
//   2. Acc clear: assert acc_clear, verify accumulator resets
//   3. Acc hold: assert acc_hold, verify accumulator freezes
//   4. Valid propagation: valid_in -> valid_out after 1 cycle
//   5. A/B propagation: a_in -> a_out, b_in -> b_out after 1 cycle
//   6. FP16 pattern: simple known values
//------------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_pe_cell;

    // Parameters
    localparam int ELEM_W = 16;
    localparam int ACC_W  = 32;

    // DUT signals
    logic              clk;
    logic              rst_n;
    logic [ELEM_W-1:0] a_in;
    logic [ELEM_W-1:0] b_in;
    logic [ELEM_W-1:0] a_out;
    logic [ELEM_W-1:0] b_out;
    logic              valid_in;
    logic              acc_clear;
    logic              acc_hold;
    logic              acc_mode;
    logic [ACC_W-1:0]  acc_out;
    logic              valid_out;
    logic              sat_flag;

    // Clock generation
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;  // 100MHz
    end

    // DUT instance
    pe_cell #(
        .ELEM_W (ELEM_W),
        .ACC_W  (ACC_W)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .a_in      (a_in),
        .b_in      (b_in),
        .a_out     (a_out),
        .b_out     (b_out),
        .valid_in  (valid_in),
        .acc_clear (acc_clear),
        .acc_hold  (acc_hold),
        .acc_mode  (acc_mode),
        .acc_out   (acc_out),
        .valid_out (valid_out),
        .sat_flag  (sat_flag)
    );

    // FP16 helpers: pack simple integer-like FP16 values
    // FP16: 1 sign, 5 exp (bias 15), 10 mant
    // For small integers, we can just set exp = 15 (bias) + floor(log2(val))
    function automatic logic [15:0] fp16_from_real(real val);
        automatic logic [63:0] val_bits;
        automatic logic [31:0] f32;
        automatic logic sign;
        automatic logic [7:0] exp32;
        automatic logic [22:0] mant32;
        automatic logic [4:0] exp16;
        automatic logic [9:0] mant16;
        val_bits = $realtobits(val);
        f32 = val_bits[31:0];
        sign = f32[31];
        exp32 = f32[30:23];
        mant32 = f32[22:0];

        if (val == 0.0) return 16'b0;

        // Convert exp: 127 (FP32 bias) -> 15 (FP16 bias)
        exp16 = exp32 - 8'd112;
        mant16 = mant32[22:13];

        // Rounding: add 1 if next bit is 1 (simple round)
        if (mant32[12] && exp16 != 5'b11111) begin
            mant16 = mant16 + 1'b1;
            if (mant16 == 10'b0) begin
                exp16 = exp16 + 1'b1;
            end
        end

        fp16_from_real = {sign, exp16[4:0], mant16};
    endfunction

    function automatic real fp16_to_real(logic [15:0] h);
        // Simple conversion using fp16_to_fp32 then to real
        automatic logic [31:0] f32;
        automatic logic sign = h[15];
        automatic logic [4:0] exp = h[14:10];
        automatic logic [9:0] mant = h[9:0];
        automatic logic [7:0] exp32;
        automatic logic [22:0] mant32;

        if (exp == 5'b0 && mant == 10'b0) return 0.0;
        if (exp == 5'b11111) begin
            if (mant == 10'b0) return sign ? 32'hFF800000 : 32'h7F800000;
            return 32'h7FC00000;  // NaN
        end

        if (exp == 5'b0) begin
            // Subnormal
            exp32 = 8'd127 - 8'd14;
            mant32 = {mant, 13'b0};
        end else begin
            exp32 = {3'b0, exp} + 8'd112;
            mant32 = {mant, 13'b0};
        end

        f32 = {sign, exp32, mant32};
        fp16_to_real = $bitstoreal(f32);
    endfunction

    // Test stimulus
    initial begin
        automatic int errors = 0;
        automatic real expected_acc;
        automatic real got_acc;
        automatic logic [ACC_W-1:0] expected_acc_bits;

        $display("================================================");
        $display(" pe_cell Testbench Starting");
        $display("================================================");

        // Init
        rst_n     = 1'b0;
        a_in      = '0;
        b_in      = '0;
        valid_in  = 1'b0;
        acc_clear = 1'b0;
        acc_hold  = 1'b0;
        acc_mode  = 1'b1;  // FP32 accumulate

        // Reset
        @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        //----------------------------------------------------------------------
        // Test 1: A/B/Valid propagation (systolic forwarding)
        //   Tool NBA scheduling differs from standard simulators.
        //   We check at negedge immediately after the driving posedge.
        //----------------------------------------------------------------------
        $display("\n[Test 1] Systolic propagation check...");
        a_in     <= 16'h3C00;  // FP16(1.0)
        b_in     <= 16'h4000;  // FP16(2.0)
        valid_in <= 1'b1;
        @(posedge clk);
        @(negedge clk);

        // Check: a_out/b_out should reflect the value driven at the previous posedge
        if (a_out !== 16'h3C00) begin
            $error("  FAIL: a_out mismatch. Expected 0x3C00, got 0x%04X", a_out);
            errors++;
        end else begin
            $display("  PASS: a_out propagated correctly");
        end
        if (b_out !== 16'h4000) begin
            $error("  FAIL: b_out mismatch. Expected 0x4000, got 0x%04X", b_out);
            errors++;
        end else begin
            $display("  PASS: b_out propagated correctly");
        end
        if (valid_out !== 1'b1) begin
            $error("  FAIL: valid_out should be high");
            errors++;
        end else begin
            $display("  PASS: valid_out propagated correctly");
        end

        valid_in <= 1'b0;
        @(posedge clk);
        @(posedge clk);

        //----------------------------------------------------------------------
        // Test 2: Basic MAC accumulation (FP32 mode)
        //   1.0 * 2.0 = 2.0
        //   3.0 * 4.0 = 12.0
        //   total = 14.0
        //----------------------------------------------------------------------
        $display("\n[Test 2] Basic MAC accumulation (FP32 mode)...");
        acc_clear <= 1'b1;
        @(posedge clk);
        acc_clear <= 1'b0;

        // Cycle 1: 1.0 * 2.0
        a_in     <= 16'h3C00;  // 1.0
        b_in     <= 16'h4000;  // 2.0
        valid_in <= 1'b1;
        @(posedge clk);

        // Cycle 2: 3.0 * 4.0
        a_in     <= 16'h4200;  // 3.0
        b_in     <= 16'h4400;  // 4.0
        @(posedge clk);

        valid_in <= 1'b0;
        @(posedge clk);  // wait for mac_result to propagate to acc_reg
        @(posedge clk);
        @(negedge clk);

        // 14.0 in FP32 = 0x41600000
        $display("  acc_out = 0x%08X", acc_out);
        if (acc_out !== 32'h41600000) begin
            $error("  FAIL: acc_out mismatch. Expected 0x41600000, got 0x%08X", acc_out);
            errors++;
        end else begin
            $display("  PASS: Accumulator = 14.0 (0x41600000)");
        end

        //----------------------------------------------------------------------
        // Test 3: acc_clear clears accumulator
        //----------------------------------------------------------------------
        $display("\n[Test 3] Accumulator clear...");
        force acc_clear = 1'b1;
        @(posedge clk);
        release acc_clear;
        @(posedge clk);

        acc_clear <= 1'b0;
        @(posedge clk);
        @(negedge clk);
        @(negedge clk);

        if (acc_out !== '0) begin
            $error("  FAIL: acc_clear did not zero accumulator");
            errors++;
        end else begin
            $display("  PASS: Accumulator cleared to zero");
        end

        @(negedge clk);  // wait for NBA to finish

        //----------------------------------------------------------------------
        // Test 4: acc_hold freezes accumulator
        //----------------------------------------------------------------------
        $display("\n[Test 4] Accumulator hold...");
        // First do one MAC
        a_in     <= 16'h3C00;  // 1.0
        b_in     <= 16'h4000;  // 2.0
        valid_in <= 1'b1;
        @(posedge clk);
        @(negedge clk);  // wait for NBA to finish

        valid_in <= 1'b0;
        @(posedge clk);
        @(negedge clk);
        @(posedge clk);

        // Now assert hold and try another MAC (should not update)
        a_in     <= 16'h4200;  // 3.0
        b_in     <= 16'h4400;  // 4.0
        valid_in <= 1'b1;
        acc_hold <= 1'b1;
        @(posedge clk);
        valid_in <= 1'b0;
        acc_hold <= 1'b0;
        @(posedge clk);
        @(posedge clk);
        @(negedge clk);

        // acc should still be 2.0 (not 14.0)
        // 2.0 in FP32 = 0x40000000
        $display("  acc_out = 0x%08X", acc_out);
        if (acc_out !== 32'h40000000) begin
            $error("  FAIL: acc_hold did not freeze accumulator. Got 0x%08X", acc_out);
            errors++;
        end else begin
            $display("  PASS: Accumulator held at 2.0 (0x40000000)");
        end

        //----------------------------------------------------------------------
        // Test 5: Mask / invalid lane (valid_in=0 should not MAC)
        //----------------------------------------------------------------------
        $display("\n[Test 5] Invalid lane (valid_in=0)...");
        acc_clear <= 1'b1;
        @(posedge clk);
        acc_clear <= 1'b0;
        @(posedge clk);
        @(negedge clk);

        // First clear accumulator
        force acc_clear = 1'b1;
        @(posedge clk);
        release acc_clear;
        @(posedge clk);
        acc_clear <= 1'b0;
        @(posedge clk);
        @(negedge clk);

        // valid=0, but a/b present
        a_in     <= 16'h7C00;  // large value (inf)
        b_in     <= 16'h7C00;
        valid_in <= 1'b0;
        repeat(3) @(posedge clk);  // wait for pipeline to settle
        @(negedge clk);

        $display("  acc_out = 0x%08X", acc_out);
        if (acc_out !== '0) begin
            $error("  FAIL: valid_in=0 should not update accumulator");
            errors++;
        end else begin
            $display("  PASS: No update when valid_in=0");
        end

        //----------------------------------------------------------------------
        // Summary
        //----------------------------------------------------------------------
        $display("\n================================================");
        if (errors == 0) begin
            $display(" ALL TESTS PASSED");
        end else begin
            $display(" TEST FAILED: %0d error(s)", errors);
        end
        $display("================================================");

        $finish;
    end

    // Optional: waveform dump
    initial begin
        $dumpfile("tb_pe_cell.vcd");
        $dumpvars(0, tb_pe_cell);
    end

endmodule : tb_pe_cell
