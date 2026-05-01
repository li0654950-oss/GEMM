//------------------------------------------------------------------------------
// fp_round_sat.sv
// FP32 to FP16 Rounding and Saturation Unit
//
// Description:
//   Per-lane FP32 accumulator to FP16 output conversion.
//   Supports 4 rounding modes (RNE/RTZ/RUP/RDN), saturation, NaN/Inf handling.
//   1-cycle latency (input register stage).
//
// Spec Reference: spec/postprocess_numeric_spec.md Section 4.4
//------------------------------------------------------------------------------

`ifndef FP_ROUND_SAT_SV
`define FP_ROUND_SAT_SV

module fp_round_sat #(
    parameter int ACC_W  = 32,
    parameter int ELEM_W = 16,
    parameter int LANES  = 4
)(
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire [1:0]            round_mode,   // 00=RNE, 01=RTZ, 10=RUP, 11=RDN
    input  wire                  sat_en,       // 1=saturate on overflow
    input  wire [LANES-1:0]      lane_mask,    // 1=valid lane

    input  wire                  out_ready,
    output wire                  in_ready,

    input  wire                  in_valid,
    input  wire [LANES*ACC_W-1:0] in_data,
    input  wire                  in_last,

    output reg                   out_valid,
    output reg  [LANES*ELEM_W-1:0] out_data,
    output reg                   out_last,
    output reg  [LANES*5-1:0]    exc_flags
);

    // FP16 constants
    localparam logic [15:0] FP16_POS_MAX = 16'h7BFF;  // +65504
    localparam logic [15:0] FP16_NEG_MAX = 16'hFBFF;  // -65504
    localparam logic [15:0] FP16_POS_INF = 16'h7C00;
    localparam logic [15:0] FP16_NEG_INF = 16'hFC00;
    localparam logic [15:0] FP16_QNAN    = 16'h7E00;

    // Round mode encoding
    localparam logic [1:0] MODE_RNE = 2'b00;
    localparam logic [1:0] MODE_RTZ = 2'b01;
    localparam logic [1:0] MODE_RUP = 2'b10;
    localparam logic [1:0] MODE_RDN = 2'b11;

    // Input registers
    reg [LANES*ACC_W-1:0] in_data_r;
    reg                     in_valid_r;

    // Internal arrays
    logic [ACC_W-1:0] fp32_in [0:LANES-1];
    logic [ELEM_W-1:0] fp16_out [0:LANES-1];
    logic [4:0] exc_out [0:LANES-1];

    // Unpack input
    genvar gi;
    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : g_unpack
            always_comb begin
                fp32_in[gi] = in_data_r[(gi+1)*ACC_W-1 : gi*ACC_W];
            end
        end
    endgenerate

    // Input register stage (with backpressure)
    reg in_last_r;
    assign in_ready = !in_valid_r || out_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_data_r <= '0;
            in_valid_r <= 1'b0;
            in_last_r <= 1'b0;
        end else if (in_ready) begin
            in_data_r <= in_data;
            in_valid_r <= in_valid;
            in_last_r <= in_last;
        end
    end

    // Per-lane FP32 to FP16 conversion (combinational)
    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : g_lane

            logic sign;
            logic [7:0] exp32;
            logic [22:0] mant32;
            logic [4:0] exp16;
            logic [9:0] mant16;
            logic [4:0] exc;

            // Rounding bits: 13 bits below the truncation point
            // We keep mant32[22:13] (10 bits), round on mant32[12:0]
            logic [12:0] round_bits;
            logic round_up;
            logic half_way;
            logic tie_even_up;

            always_comb begin
                // Defaults to prevent latch inference
                sign       = 1'b0;
                exp32      = 8'b0;
                mant32     = 23'b0;
                exc        = 5'b0;
                exp16      = 5'b0;
                mant16     = 10'b0;
                round_bits = 13'b0;
                half_way   = 1'b0;
                tie_even_up= 1'b0;
                round_up   = 1'b0;
                fp16_out[gi] = 16'h0000;
                exc_out[gi]  = 5'b00000;

                if (!lane_mask[gi]) begin
                    // Masked lane: output 0, no exception
                    fp16_out[gi] = 16'h0000;
                    exc_out[gi]  = 5'b00000;
                end else begin
                    sign   = fp32_in[gi][31];
                    exp32  = fp32_in[gi][30:23];
                    mant32 = fp32_in[gi][22:0];
                    exc    = 5'b00000;

                    // Special cases
                    if (exp32 == 8'h00) begin
                        if (mant32 == 23'b0) begin
                            // Zero
                            fp16_out[gi] = {sign, 15'b0};
                        end else begin
                            // FP32 subnormal (DENORM input)
                            fp16_out[gi] = {sign, 15'b0};
                            exc[0] = 1'b1;  // DENORM
                        end
                    end else if (exp32 == 8'hFF) begin
                        // Inf or NaN
                        if (mant32 == 23'b0) begin
                            // Inf
                            fp16_out[gi] = {sign, 5'b11111, 10'b0};
                            exc[3] = 1'b1;  // Inf
                        end else begin
                            // NaN
                            fp16_out[gi] = FP16_QNAN;
                            exc[4] = 1'b1;  // NaN
                        end
                    end else begin
                        // Normal FP32 number

                        // Check exponent range for FP16
                        // FP16 normal biased exp range: [1, 30]
                        // FP32 biased exp mapping: exp16 = exp32 - 112
                        // So valid FP32 exp for normal FP16: [113, 142]

                        if (exp32 < 8'd113) begin
                            // Underflow: too small for normal FP16
                            fp16_out[gi] = {sign, 15'b0};
                            exc[1] = 1'b1;  // UDF
                        end else if (exp32 > 8'd142) begin
                            // Overflow
                            exc[2] = 1'b1;  // OVF
                            if (sat_en) begin
                                fp16_out[gi] = sign ? FP16_NEG_MAX : FP16_POS_MAX;
                            end else begin
                                fp16_out[gi] = sign ? FP16_NEG_INF : FP16_POS_INF;
                                exc[3] = 1'b1;  // Inf
                            end
                        end else begin
                            // exp32 in [113, 142]: normal conversion
                            exp16 = exp32 - 8'd112;  // 127-15 = 112 bias delta

                            // Mantissa: keep top 10 bits, round on remaining 13
                            // Full significand: {1, mant32[22:0]} = 24 bits
                            // Keep: {1, mant32[22:13]} = 11 bits (but we drop the implicit 1)
                            // So mant16 = mant32[22:13], round on mant32[12:0]

                            round_bits = mant32[12:0];
                            half_way = (round_bits == 13'b1000000000000);
                            tie_even_up = mant32[13];  // LSB of mant16 base

                            // Determine round_up based on mode
                            case (round_mode)
                                MODE_RNE: begin
                                    if (half_way) begin
                                        round_up = tie_even_up;
                                    end else begin
                                        round_up = round_bits[12];  // guard bit
                                    end
                                end
                                MODE_RTZ: round_up = 1'b0;
                                MODE_RUP: round_up = !sign && (round_bits != 13'b0);
                                MODE_RDN: round_up = sign && (round_bits != 13'b0);
                                default:  round_up = 1'b0;
                            endcase

                            mant16 = mant32[22:13];
                            if (round_up) begin
                                mant16 = mant16 + 10'b1;
                                if (mant16 == 10'b0000000000) begin
                                    // Mantissa overflow: carry into exponent
                                    exp16 = exp16 + 5'b1;
                                    if (exp16 == 5'b11111) begin
                                        // Overflow to Inf
                                        exc[2] = 1'b1;
                                        if (sat_en) begin
                                            fp16_out[gi] = sign ? FP16_NEG_MAX : FP16_POS_MAX;
                                        end else begin
                                            fp16_out[gi] = sign ? FP16_NEG_INF : FP16_POS_INF;
                                            exc[3] = 1'b1;
                                        end
                                    end else begin
                                        fp16_out[gi] = {sign, exp16[4:0], mant16};
                                    end
                                end else begin
                                    fp16_out[gi] = {sign, exp16[4:0], mant16};
                                end
                            end else begin
                                fp16_out[gi] = {sign, exp16[4:0], mant16};
                            end
                        end
                    end

                    exc_out[gi] = exc;
                end
            end
        end
    endgenerate

    // Output register stage
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid  <= 1'b0;
            out_data   <= '0;
            out_last   <= 1'b0;
            exc_flags  <= '0;
        end else begin
            out_valid <= in_valid_r;
            out_last  <= in_last_r;
            for (int i = 0; i < LANES; i = i + 1) begin
                out_data[i*ELEM_W +: ELEM_W] <= fp16_out[i];
                exc_flags[i*5 +: 5] <= exc_out[i];
            end
        end
    end

endmodule : fp_round_sat

`endif // FP_ROUND_SAT_SV
