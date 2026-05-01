//------------------------------------------------------------------------------
// fp_add_c.sv
// FP32 Accumulator + FP16 C Tile Fusion Adder
//
// Description:
//   Per-lane FP32 accumulator addition with optional FP16 C tile input.
//   FP16 C is zero-extended to FP32 before addition.
//   Supports bypass mode (add_en=0) and lane masking.
//   Simplified behavioral FP32 adder (MVP stage, replaces with hardened IP
//   for synthesis target).
//
//   1-cycle latency (input register stage).
//
// Spec Reference: spec/postprocess_numeric_spec.md Section 4.3
//------------------------------------------------------------------------------

`ifndef FP_ADD_C_SV
`define FP_ADD_C_SV

module fp_add_c #(
    parameter int ACC_W  = 32,
    parameter int ELEM_W = 16,
    parameter int LANES  = 4
)(
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  add_en,       // 1=acc+C, 0=bypass acc
    input  wire [LANES-1:0]      lane_mask,    // 1=valid lane

    input  wire                  out_ready,
    output wire                  in_ready,

    input  wire                  x_valid,
    input  wire [LANES*ACC_W-1:0] x_data,
    input  wire                  x_last,

    input  wire                  c_valid,
    input  wire [LANES*ELEM_W-1:0] c_data,

    output reg                   y_valid,
    output reg  [LANES*ACC_W-1:0] y_data,
    output reg                   y_last,
    output reg  [LANES-1:0]      add_exc
);

    // Input registers
    reg [LANES*ACC_W-1:0] x_data_r;
    reg                   x_valid_r;
    reg [LANES*ELEM_W-1:0] c_data_r;
    reg                    c_valid_r;
    reg                    add_en_r;
    reg [LANES-1:0]        lane_mask_r;

    // Internal arrays
    logic [ACC_W-1:0] x_in [0:LANES-1];
    logic [ELEM_W-1:0] c_in [0:LANES-1];
    logic [ACC_W-1:0] y_out [0:LANES-1];
    logic [LANES-1:0] exc_out;

    // FP16 to FP32 conversion (combinational)
    function automatic logic [31:0] fp16_to_fp32(logic [15:0] h);
        logic sign;
        logic [4:0]  exp;
        logic [9:0]  mant;
        logic [7:0]  exp32;
        logic [22:0] mant32;
        begin
            sign  = h[15];
            exp   = h[14:10];
            mant  = h[9:0];

            if (exp == 5'b00000) begin
                // Zero or subnormal
                if (mant == 10'b0) begin
                    fp16_to_fp32 = {sign, 31'b0};
                end else begin
                    // Subnormal: normalize it
                    logic [9:0] m;
                    int shift;
                    m = mant;
                    shift = 0;
                    while (m[9] == 1'b0 && shift < 10) begin
                        m = m << 1;
                        shift = shift + 1;
                    end
                    exp32  = 8'd127 - 8'd14 - shift[7:0];
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
                exp32  = {3'b0, exp} + 8'd112;
                mant32 = {mant, 13'b0};
                fp16_to_fp32 = {sign, exp32, mant32};
            end
        end
    endfunction

    // FP32 to real conversion helper (for behavioral add)
    function automatic real fp32_to_real(logic [31:0] f);
        logic sign;
        logic [7:0]  exp32;
        logic [22:0] mant32;
        logic [63:0] fp64;
        begin
            sign   = f[31];
            exp32  = f[30:23];
            mant32 = f[22:0];
            if (exp32 == 8'h00) begin
                fp64 = {sign, 63'b0};
            end else if (exp32 == 8'hFF) begin
                fp64 = {sign, 11'h7FF, mant32, 29'b0};
            end else begin
                fp64 = {sign, {3'b0, exp32} + 11'd896, mant32, 29'b0};
            end
            fp32_to_real = $bitstoreal(fp64);
        end
    endfunction

    // Real to FP32 conversion helper
    function automatic logic [31:0] real_to_fp32(real r);
        logic [63:0] bits;
        logic sign;
        logic [10:0] exp64;
        logic [51:0] mant64;
        logic [7:0]  exp32;
        begin
            bits   = $realtobits(r);
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
                    exp32 = exp64[7:0] - 8'd128;
                    real_to_fp32 = {sign, exp64 - 11'd896, mant64[51:29]};
                end
            end
        end
    endfunction

    // Unpack inputs
    genvar gi;
    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : g_unpack
            always_comb begin
                x_in[gi] = x_data_r[(gi+1)*ACC_W-1 : gi*ACC_W];
                c_in[gi] = c_data_r[(gi+1)*ELEM_W-1 : gi*ELEM_W];
            end
        end
    endgenerate

    // Input register stage (with backpressure)
    reg x_last_r;
    assign in_ready = !x_valid_r || out_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_data_r   <= '0;
            x_valid_r  <= 1'b0;
            x_last_r   <= 1'b0;
            c_data_r   <= '0;
            c_valid_r  <= 1'b0;
            add_en_r   <= 1'b0;
            lane_mask_r<= '0;
        end else if (in_ready) begin
            x_data_r    <= x_data;
            x_valid_r   <= x_valid;
            x_last_r    <= x_last;
            c_data_r    <= c_data;
            c_valid_r   <= c_valid;
            add_en_r    <= add_en;
            lane_mask_r <= lane_mask;
        end
    end

    // Per-lane combinational add / bypass
    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : g_lane

            logic [31:0] c_ext;
            logic [31:0] x_val;
            real x_real, c_real, y_real;
            logic x_is_nan, x_is_inf, c_is_nan, c_is_inf;
            logic x_sign, c_sign;

            always_comb begin
                // Defaults to prevent latch inference
                x_val    = 32'b0;
                c_ext    = 32'b0;
                x_is_nan = 1'b0;
                x_is_inf = 1'b0;
                c_is_nan = 1'b0;
                c_is_inf = 1'b0;
                x_sign   = 1'b0;
                c_sign   = 1'b0;
                x_real   = 0.0;
                c_real   = 0.0;
                y_real   = 0.0;
                y_out[gi]  = '0;
                exc_out[gi]= 1'b0;

                if (!lane_mask_r[gi]) begin
                    y_out[gi]   = '0;
                    exc_out[gi] = 1'b0;
                end else if (!add_en_r) begin
                    // Bypass mode
                    y_out[gi]   = x_in[gi];
                    exc_out[gi] = 1'b0;
                end else begin
                    x_val = x_in[gi];
                    c_ext = fp16_to_fp32(c_in[gi]);

                    // Check special cases
                    x_is_nan = (x_val[30:23] == 8'hFF && x_val[22:0] != 23'b0);
                    x_is_inf = (x_val[30:23] == 8'hFF && x_val[22:0] == 23'b0);
                    c_is_nan = (c_ext[30:23] == 8'hFF && c_ext[22:0] != 23'b0);
                    c_is_inf = (c_ext[30:23] == 8'hFF && c_ext[22:0] == 23'b0);
                    x_sign   = x_val[31];
                    c_sign   = c_ext[31];

                    if (x_is_nan || c_is_nan) begin
                        // NaN propagation
                        y_out[gi]   = {1'b0, 8'hFF, 23'h400000};  // QNaN
                        exc_out[gi] = 1'b1;
                    end else if (x_is_inf && c_is_inf && (x_sign != c_sign)) begin
                        // Inf - Inf = NaN
                        y_out[gi]   = {1'b0, 8'hFF, 23'h400000};  // QNaN
                        exc_out[gi] = 1'b1;
                    end else if (x_is_inf) begin
                        y_out[gi]   = x_val;
                        exc_out[gi] = 1'b0;
                    end else if (c_is_inf) begin
                        y_out[gi]   = c_ext;
                        exc_out[gi] = 1'b0;
                    end else begin
                        // Normal addition using real arithmetic
                        x_real = fp32_to_real(x_val);
                        c_real = fp32_to_real(c_ext);
                        y_real = x_real + c_real;
                        y_out[gi] = real_to_fp32(y_real);
                        exc_out[gi] = 1'b0;
                    end
                end
            end
        end
    endgenerate

    // Output register stage
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_valid  <= 1'b0;
            y_data   <= '0;
            y_last   <= 1'b0;
            add_exc  <= '0;
        end else begin
            y_valid <= x_valid_r;
            y_last  <= x_last_r;
            for (int i = 0; i < LANES; i = i + 1) begin
                y_data[i*ACC_W +: ACC_W] <= y_out[i];
            end
            add_exc <= exc_out;
        end
    end

endmodule : fp_add_c

`endif // FP_ADD_C_SV
