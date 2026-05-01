//------------------------------------------------------------------------------
// buffer_bank.sv
// Unified On-Chip Buffer with Bank Arbitration and Ping-Pong Control
// Byte-level mask support: split SRAM into 32 independent byte arrays
//------------------------------------------------------------------------------

`ifndef BUFFER_BANK_SV
`define BUFFER_BANK_SV

module buffer_bank #(
    parameter int P_M         = 2,
    parameter int P_N         = 2,
    parameter int ELEM_W      = 16,
    parameter int ACC_W       = 32,
    parameter int BUF_BANKS   = 4,
    parameter int BUF_DEPTH   = 512,
    parameter int AXI_DATA_W  = 256,
    parameter bit PP_ENABLE   = 1'b1
)(
    input  wire              clk,
    input  wire              rst_n,

    input  wire              wr_valid,
    output reg               wr_ready,
    input  wire [2:0]        wr_sel,
    input  wire [$clog2(BUF_BANKS)-1:0] wr_bank,
    input  wire [$clog2(BUF_DEPTH)-1:0] wr_addr,
    input  wire [AXI_DATA_W-1:0]        wr_data,
    input  wire [AXI_DATA_W/8-1:0]      wr_mask,

    input  wire              rd_req_valid,
    output reg               rd_req_ready,
    input  wire [2:0]        rd_sel,
    input  wire [$clog2(BUF_BANKS)-1:0] rd_bank,
    input  wire [$clog2(BUF_DEPTH)-1:0] rd_addr,
    output reg               rd_data_valid,
    output reg  [AXI_DATA_W-1:0]        rd_data,

    input  wire              pp_switch_req,
    output reg               pp_switch_ack,
    output reg               pp_a_compute_sel,
    output reg               pp_b_compute_sel,
    output reg               pp_a_load_sel,
    output reg               pp_b_load_sel,

    output reg               conflict_stall,
    output reg  [BUF_BANKS-1:0] bank_occ
);

    localparam int NUM_BUF_SETS = 5;
    localparam int BYTES_PER_BEAT = AXI_DATA_W / 8;
    localparam int TOTAL_ENTRIES = NUM_BUF_SETS * BUF_BANKS * BUF_DEPTH;

    function automatic int sram_idx(int set, int bank, int addr);
        sram_idx = set * BUF_BANKS * BUF_DEPTH + bank * BUF_DEPTH + addr;
    endfunction

    // Ping-pong control
    reg pp_switch_req_d;
    wire pp_switch_posedge = pp_switch_req && !pp_switch_req_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pp_a_compute_sel <= 1'b0;
            pp_b_compute_sel <= 1'b0;
            pp_a_load_sel    <= 1'b1;
            pp_b_load_sel    <= 1'b1;
            pp_switch_ack    <= 1'b0;
            pp_switch_req_d  <= 1'b0;
        end else begin
            pp_switch_req_d <= pp_switch_req;
            if (pp_switch_posedge) begin
                pp_a_compute_sel <= ~pp_a_compute_sel;
                pp_b_compute_sel <= ~pp_b_compute_sel;
                pp_a_load_sel    <= ~pp_a_load_sel;
                pp_b_load_sel    <= ~pp_b_load_sel;
                pp_switch_ack    <= 1'b1;
            end
        end
    end

    // Write ready
    always_comb begin
        wr_ready = !(rd_req_valid && (rd_bank == wr_bank));
    end

    // Split SRAM into 32 independent byte arrays for per-byte mask support
    genvar gi;
    generate
        for (gi = 0; gi < BYTES_PER_BEAT; gi = gi + 1) begin : g_sram_byte
            reg [7:0] sram_byte [0:TOTAL_ENTRIES-1];

            initial begin
                for (int i = 0; i < TOTAL_ENTRIES; i++)
                    sram_byte[i] = 8'h00;
                $display("INIT2: byte array %0d initialized", gi);
            end

            always_ff @(posedge clk) begin
                if (wr_valid && wr_ready && wr_mask[gi])
                    sram_byte[sram_idx(wr_sel, wr_bank, wr_addr)] <= wr_data[gi*8 +: 8];
            end

            assign rd_data[gi*8 +: 8] = sram_byte[sram_idx(rd_sel, rd_bank, rd_addr)];
        end
    endgenerate

    // Read valid signal (1-cycle latency)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_data_valid <= 1'b0;
            rd_req_ready  <= 1'b1;
        end else begin
            rd_data_valid <= rd_req_valid;
            rd_req_ready  <= 1'b1;
        end
    end

    // Conflict detection
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            conflict_stall <= 1'b0;
        else
            conflict_stall <= rd_req_valid && wr_valid && (rd_bank == wr_bank);
    end

    // Bank occupancy
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_occ <= '0;
        end else begin
            for (int b = 0; b < BUF_BANKS; b++) begin
                bank_occ[b] <= (rd_req_valid && rd_bank == b) ||
                               (wr_valid && wr_ready && wr_bank == b);
            end
        end
    end

`ifdef SIMULATION
    generate
        for (gi = 0; gi < BYTES_PER_BEAT; gi = gi + 1) begin : g_init
            initial begin
                for (int i = 0; i < TOTAL_ENTRIES; i++)
                    g_sram_byte[gi].sram_byte[i] = 8'h00;
            end
        end
    endgenerate
`endif

endmodule
`endif
