//------------------------------------------------------------------------------
// pe_cell.sv
// GEMM Systolic Array - Processing Element (Output-Stationary)
//
// Description:
//   Single PE for a P_M x P_N systolic array. Implements output-stationary
//   MAC: acc += a_in * b_in. A propagates left-to-right, B propagates
//   top-to-bottom. Accumulator resides locally.
//
//   FP16 multiply with FP32 accumulate (default). FP16 accumulate mode
//   selectable via `acc_mode`.
//
//   The FP16 MAC (`fp16_mac_soft`) is a soft behavioral model for
//   simulation/verification. Replace with hardened FP16 multiplier IP
//   for synthesis.
//
// Parameters:
//   ELEM_W  - FP16 = 16
//   ACC_W   - FP32 = 32, FP16 = 16
//   ACC_FP32_DEFAULT - 1=FP32 accum (recommended), 0=FP16 accum
//
// Spec Reference: spec/systolic_compute_core_spec.md Section 4.2, 7.8
//------------------------------------------------------------------------------

`ifndef PE_CELL_SV
`define PE_CELL_SV

module pe_cell #(
    parameter int ELEM_W = 16,
    parameter int ACC_W  = 32,
    parameter bit ACC_FP32_DEFAULT = 1'b1
)(
    input  wire              clk,
    input  wire              rst_n,

    // Systolic data path ----------------------------------------------------
    input  wire [ELEM_W-1:0] a_in,      // A from left neighbor
    input  wire [ELEM_W-1:0] b_in,      // B from top neighbor
    output reg  [ELEM_W-1:0] a_out,     // A to right neighbor
    output reg  [ELEM_W-1:0] b_out,     // B to bottom neighbor

    // Control ---------------------------------------------------------------
    input  wire              valid_in,    // 1 = this PE should MAC this cycle
    input  wire              acc_clear,   // 1 = clear accumulator (k-chunk start)
    input  wire              acc_hold,    // 1 = freeze accumulator update
    input  wire              acc_mode,    // 0=FP16acc, 1=FP32acc (ignored if ACC_W=16)

    // Accumulator output ----------------------------------------------------
    output reg  [ACC_W-1:0]  acc_out,     // Local accumulator value
    output reg               valid_out,   // Delayed valid (propagated)
    output wire              sat_flag     // 1 = accumulator saturated (optional)
);

    // Local accumulator register
    reg [ACC_W-1:0] acc_reg;

    // MAC result wires
    wire [ACC_W-1:0] mac_result;
    wire             mac_valid;

    // Forwarding registers: A/B/valid propagate with 1-cycle delay
    // This creates the systolic wavefront
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out     <= '0;
            b_out     <= '0;
            valid_out <= 1'b0;
        end else begin
            a_out     <= a_in;
            b_out     <= b_in;
            valid_out <= valid_in;
        end
    end

    // Accumulator update ----------------------------------------------------
    // OS: accumulator stays in PE, updated when valid_in=1
    // acc_clear has priority over acc_hold
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_reg <= '0;
        end else if (acc_clear) begin
            acc_reg <= '0;
        end else if (!acc_hold && valid_in) begin
            acc_reg <= mac_result;
        end
        // else: hold current value
    end

    // Output assignment
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_out <= '0;
        end else begin
            acc_out <= acc_reg;
        end
    end

    // Soft FP16 MAC instantiation -------------------------------------------
    // Replace with hardened FP16 MAC IP for synthesis target
    fp16_mac_soft #(
        .ELEM_W (ELEM_W),
        .ACC_W  (ACC_W)
    ) u_mac (
        .clk     (clk),
        .rst_n   (rst_n),
        .a       (a_in),
        .b       (b_in),
        .acc_in  (acc_reg),
        .valid   (valid_in & !acc_clear),  // Don't MAC on clear cycle
        .mode    (acc_mode),
        .result  (mac_result),
        .sat     (sat_flag)
    );

endmodule : pe_cell


//------------------------------------------------------------------------------
// fp16_mac_soft.sv
// Soft behavioral FP16 MAC for simulation / functional verification.
//
// NOTE: This is a simulation-only model using IEEE 754 float conversions.
// For ASIC/FPGA synthesis, replace this module with a hardened FP16
// multiplier + FP32 adder (e.g., Xilinx FP16 DSP58, or custom RTL).
//------------------------------------------------------------------------------

module fp16_mac_soft #(
    parameter int ELEM_W = 16,
    parameter int ACC_W  = 32
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire [ELEM_W-1:0] a,
    input  wire [ELEM_W-1:0] b,
    input  wire [ACC_W-1:0]  acc_in,
    input  wire              valid,
    input  wire              mode,      // 0=FP16acc, 1=FP32acc
    output reg  [ACC_W-1:0]  result,
    output reg               sat
);

    // FP32 to FP64 bit conversion (for Verilator $bitstoreal compatibility)
    function automatic logic [63:0] fp32_to_fp64(logic [31:0] f);
        automatic logic sign;
        automatic logic [7:0]  exp32;
        automatic logic [22:0] mant32;
        begin
            sign   = f[31];
            exp32  = f[30:23];
            mant32 = f[22:0];
            if (exp32 == 8'h00) begin
                // Zero or subnormal -> zero (simplified)
                fp32_to_fp64 = {sign, 63'b0};
            end else if (exp32 == 8'hFF) begin
                // Inf/NaN
                fp32_to_fp64 = {sign, 11'h7FF, mant32, 29'b0};
            end else begin
                // Normal: exp64 = exp32 + 896 (1023-127)
                fp32_to_fp64 = {sign, {3'b0, exp32} + 11'd896, mant32, 29'b0};
            end
        end
    endfunction

    // FP64 to FP32 bit conversion
    function automatic logic [31:0] fp64_to_fp32(logic [63:0] f);
        automatic logic sign;
        automatic logic [10:0] exp64;
        automatic logic [51:0] mant64;
        automatic logic [7:0]  exp32;
        begin
            sign   = f[63];
            exp64  = f[62:52];
            mant64 = f[51:0];
            if (exp64 == 11'h000) begin
                fp64_to_fp32 = {sign, 31'b0};
            end else if (exp64 == 11'h7FF) begin
                fp64_to_fp32 = {sign, 8'hFF, mant64[51:29]};
            end else begin
                // Normal: clamp to FP32 range
                if (exp64 < 11'd896) begin
                    fp64_to_fp32 = {sign, 31'b0};  // Underflow
                end else if (exp64 > 11'd1151) begin
                    fp64_to_fp32 = {sign, 8'hFF, 23'b0};  // Overflow
                end else begin
                    exp32 = exp64[7:0] - 8'd128;  // 896 = 128 + 768, but exp64[7:0] - 128
                    // Actually: exp32 = exp64 - 896
                    // exp64 is 11-bit, we need lower 8 bits after subtracting 896
                    // 896 = 01110000000, so exp64 - 896
                    fp64_to_fp32 = {sign, exp64 - 11'd896, mant64[51:29]};
                end
            end
        end
    endfunction

    // Tool promotes shortreal to real; use real directly
    real a_f, b_f, acc_f, mul_f, sum_f;

    // Convert FP16 bits to shortreal
    // Uses IEEE 754 implicit conversion via $bitstoshortreal after promoting to 32-bit
    // This is simulation-only; synthesis target needs hardened FP16 unit
    always_comb begin
        automatic logic [31:0] a_fp32, b_fp32;

        // Zero-extend / promote FP16 to FP32 for conversion
        // Proper FP16-to-FP32 conversion would unpack sign/exp/mantissa.
        // For MVP verification, we use the built-in float cast which handles
        // this when the tool supports it (VCS/Questa/XSIM).
        a_fp32 = {16'b0, a};  // placeholder: should be real fp16_to_fp32
        b_fp32 = {16'b0, b};

        // In a proper implementation, do bit-level FP16->FP32 conversion:
        // sign = a[15], exp = a[14:10], mant = a[9:0]
        // Then construct FP32 and cast.

        a_f   = $bitstoreal(fp32_to_fp64(fp16_to_fp32(a)));
        b_f   = $bitstoreal(fp32_to_fp64(fp16_to_fp32(b)));
        acc_f = (ACC_W == 32) ? $bitstoreal(fp32_to_fp64(acc_in)) : $bitstoreal(fp32_to_fp64(fp16_to_fp32(acc_in[ELEM_W-1:0])));

        mul_f = a_f * b_f;
        sum_f = acc_f + mul_f;
    end

    // Combinational output (no pipeline delay in soft model)
    always_comb begin
        automatic logic [63:0] sum_bits;
        if (!valid) begin
            result   = acc_in;
            sat      = 1'b0;
            sum_bits = 64'b0;
        end else begin
            sum_bits = $realtobits(sum_f);
            if (ACC_W == 32 || mode == 1'b1) begin
                result = fp64_to_fp32(sum_bits);
            end else begin
                result = {16'b0, fp32_to_fp16(fp64_to_fp32(sum_bits))};
            end
            sat = (sum_f > 3.4028235e38) || (sum_f != sum_f);
        end
    end

    //------------------------------------------------------------------------------
    // FP16 <-> FP32 conversion helpers (bit-accurate, simulation only)
    //------------------------------------------------------------------------------
    function automatic logic [31:0] fp16_to_fp32(logic [15:0] h);
        automatic logic sign;
        automatic logic [4:0]  exp;
        automatic logic [9:0]  mant;
        automatic logic [7:0]  exp32;
        automatic logic [22:0] mant32;
        begin
            sign  = h[15];
            exp   = h[14:10];
            mant  = h[9:0];

            if (exp == 5'b00000) begin
                // Zero or subnormal
                if (mant == 10'b0) begin
                    fp16_to_fp32 = {sign, 31'b0};  // Zero
                end else begin
                    // Subnormal: normalize it
                    automatic logic [9:0] m = mant;
                    automatic int shift = 0;
                    while (m[9] == 1'b0 && shift < 10) begin
                        m = m << 1;
                        shift++;
                    end
                    exp32  = 8'd127 - 8'd14 - shift;
                    mant32 = {m[8:0], 14'b0};
                    fp16_to_fp32 = {sign, exp32, mant32};
                end
            end else if (exp == 5'b11111) begin
                // Inf or NaN
                exp32  = 8'hFF;
                mant32 = {mant, 13'b0};
                fp16_to_fp32 = {sign, exp32, mant32};
            end else begin
                // Normal
                exp32  = {3'b0, exp} + 8'd112;  // 127 - 15 = 112 bias delta
                mant32 = {mant, 13'b0};
                fp16_to_fp32 = {sign, exp32, mant32};
            end
        end
    endfunction

    function automatic logic [15:0] fp32_to_fp16(logic [31:0] f);
        automatic logic sign;
        automatic logic [7:0]  exp32;
        automatic logic [22:0] mant32;
        automatic logic [4:0]  exp16;
        automatic logic [9:0]  mant16;
        begin
            sign   = f[31];
            exp32  = f[30:23];
            mant32 = f[22:0];

            if (exp32 == 8'h00) begin
                fp32_to_fp16 = {sign, 15'b0};  // Zero
            end else if (exp32 >= 8'hFF) begin
                // Inf/NaN
                fp32_to_fp16 = {sign, 5'b11111, mant32[22:13]};
            end else begin
                // Bias: 127 (FP32) -> 15 (FP16) = subtract 112
                if (exp32 < 8'd112) begin
                    fp32_to_fp16 = {sign, 15'b0};  // Underflow to zero
                end else if (exp32 > 8'd142) begin
                    fp32_to_fp16 = {sign, 5'b11111, 10'b0};  // Overflow to inf
                end else begin
                    exp16  = exp32[4:0] - 5'd15;  // 127-15=112, but we need 5-bit
                    // Wait, simpler: exp16 = exp32 - 112
                    // 112 = 01110000
                    // We need to handle this carefully
                    exp16  = exp32 - 8'd112;
                    mant16 = mant32[22:13];
                    fp32_to_fp16 = {sign, exp16[4:0], mant16};
                end
            end
        end
    endfunction

endmodule : fp16_mac_soft

`endif // PE_CELL_SV
