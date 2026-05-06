//------------------------------------------------------------------------------
// perf_counter.sv
// GEMM Performance Counter Unit
//
// Description:
//   64-bit cycle/byte/stall counters. Start/stop/freeze/snapshot control.
//   Feeds csr_if for software visibility.
//------------------------------------------------------------------------------
`ifndef PERF_COUNTER_SV
`define PERF_COUNTER_SV

module perf_counter #(
    parameter int PERF_CNT_W       = 64,
    parameter int NUM_STALL_REASONS = 8,
    parameter int AXI_DATA_W       = 256
)(
    input  wire              clk,
    input  wire              rst_n,

    input  wire              cnt_start,
    input  wire              cnt_stop,
    input  wire              cnt_clear,
    input  wire              cnt_freeze,
    input  wire              snap_req,

    input  wire              core_busy,
    input  wire              core_active,
    input  wire              dma_rd_wait,
    input  wire              dma_wr_wait,
    input  wire              axi_rd_beat,
    input  wire              axi_wr_beat,
    input  wire [NUM_STALL_REASONS-1:0] stall_reason,

    output reg  [PERF_CNT_W-1:0] cycle_total,
    output reg  [PERF_CNT_W-1:0] cycle_compute,
    output reg  [PERF_CNT_W-1:0] cycle_dma_wait,
    output reg  [PERF_CNT_W-1:0] axi_rd_bytes,
    output reg  [PERF_CNT_W-1:0] axi_wr_bytes,
    output reg  [NUM_STALL_REASONS*PERF_CNT_W-1:0] stall_reason_cnt,
    output reg               snap_valid
);

    reg running;
    reg [PERF_CNT_W-1:0] stall_cnt_array [0:NUM_STALL_REASONS-1];

    // Running flag
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 1'b0;
        end else begin
            if (cnt_start)   running <= 1'b1;
            else if (cnt_stop) running <= 1'b0;
        end
    end

    // Counters
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_total      <= '0;
            cycle_compute    <= '0;
            cycle_dma_wait   <= '0;
            axi_rd_bytes     <= '0;
            axi_wr_bytes     <= '0;
            snap_valid       <= 1'b0;
        end else begin
            snap_valid <= 1'b0;
            if (cnt_clear) begin
                cycle_total    <= '0;
                cycle_compute  <= '0;
                cycle_dma_wait <= '0;
                axi_rd_bytes   <= '0;
                axi_wr_bytes   <= '0;
            end else if (running && !cnt_freeze) begin
                cycle_total <= cycle_total + 1'b1;
                if (core_active)       cycle_compute  <= cycle_compute  + 1'b1;
                if (dma_rd_wait || dma_wr_wait) cycle_dma_wait <= cycle_dma_wait + 1'b1;
                if (axi_rd_beat)       axi_rd_bytes   <= axi_rd_bytes + (AXI_DATA_W/8);
                if (axi_wr_beat)       axi_wr_bytes   <= axi_wr_bytes + (AXI_DATA_W/8);
            end
            if (snap_req) snap_valid <= 1'b1;
        end
    end

    // Stall reason counters
    genvar i;
    generate
        for (i = 0; i < NUM_STALL_REASONS; i = i + 1) begin : g_stall_cnt
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    stall_cnt_array[i] <= '0;
                end else if (cnt_clear) begin
                    stall_cnt_array[i] <= '0;
                end else if (running && !cnt_freeze && stall_reason[i]) begin
                    stall_cnt_array[i] <= stall_cnt_array[i] + 1'b1;
                end
            end
            always_comb begin
                stall_reason_cnt[i*PERF_CNT_W +: PERF_CNT_W] = stall_cnt_array[i];
            end
        end
    endgenerate

endmodule : perf_counter
`endif // PERF_COUNTER_SV
