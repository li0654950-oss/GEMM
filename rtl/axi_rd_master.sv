//------------------------------------------------------------------------------
// axi_rd_master.sv
// GEMM AXI4 Read Master Protocol Layer
//
// Description:
//   Handles AR/R channel handshake, outstanding credit management,
//   error response detection. Supports configurable MAX_BURST_LEN and
//   OUTSTANDING_RD.
//------------------------------------------------------------------------------
`ifndef AXI_RD_MASTER_SV
`define AXI_RD_MASTER_SV

module axi_rd_master #(
    parameter int ADDR_W       = 64,
    parameter int AXI_DATA_W   = 256,
    parameter int AXI_ID_W     = 4,
    parameter int MAX_BURST_LEN= 16,
    parameter int OUTSTANDING_RD = 8
)(
    input  wire              clk,
    input  wire              rst_n,

    // AXI4 AR Channel -------------------------------------------------------
    output reg               m_axi_arvalid,
    input  wire              m_axi_arready,
    output reg  [AXI_ID_W-1:0] m_axi_arid,
    output reg  [ADDR_W-1:0] m_axi_araddr,
    output reg  [7:0]        m_axi_arlen,
    output reg  [2:0]        m_axi_arsize,
    output reg  [1:0]        m_axi_arburst,
    output reg  [3:0]        m_axi_arcache,
    output reg  [2:0]        m_axi_arprot,

    // AXI4 R Channel --------------------------------------------------------
    input  wire              m_axi_rvalid,
    output reg               m_axi_rready,
    input  wire [AXI_ID_W-1:0] m_axi_rid,
    input  wire [AXI_DATA_W-1:0] m_axi_rdata,
    input  wire [1:0]        m_axi_rresp,
    input  wire              m_axi_rlast,

    // Internal command interface --------------------------------------------
    input  wire              cmd_valid,
    output wire              cmd_ready,
    input  wire [ADDR_W-1:0] cmd_addr,
    input  wire [7:0]        cmd_len,
    input  wire [2:0]        cmd_size,

    // Internal data return interface ----------------------------------------
    output reg               data_valid,
    input  wire              data_ready,
    output reg  [AXI_DATA_W-1:0] data_payload,
    output reg               data_last,
    output reg               resp_err
);

    localparam int OS_CNT_W = $clog2(OUTSTANDING_RD+1);

    // Outstanding credit
    reg [OS_CNT_W-1:0] os_cnt;
    wire os_credit = (os_cnt < OUTSTANDING_RD);

    // AR FSM
    typedef enum logic [1:0] { AR_IDLE, AR_VALID } ar_state_t;
    ar_state_t ar_state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_state       <= AR_IDLE;
            m_axi_arvalid  <= 1'b0;
            os_cnt         <= '0;
            resp_err       <= 1'b0;
            m_axi_rready   <= 1'b1;
            data_valid     <= 1'b0;
            data_last      <= 1'b0;
        end else begin
            case (ar_state)
                AR_IDLE: begin
                    if (cmd_valid && os_credit) begin
                        ar_state      <= AR_VALID;
                        m_axi_arvalid <= 1'b1;
                        m_axi_arid    <= {AXI_ID_W{1'b0}};
                        m_axi_araddr  <= cmd_addr;
                        m_axi_arlen   <= cmd_len;
                        m_axi_arsize  <= cmd_size;
                        m_axi_arburst <= 2'b01; // INCR
                        m_axi_arcache <= 4'b0011;
                        m_axi_arprot  <= 3'b000;
                    end
                end
                AR_VALID: begin
                    if (m_axi_arready) begin
                        ar_state      <= AR_IDLE;
                        m_axi_arvalid <= 1'b0;
                        os_cnt        <= os_cnt + 1'b1;
                    end
                end
            endcase

            // R channel: decrement os_cnt on RLAST
            if (m_axi_rvalid && m_axi_rready && m_axi_rlast) begin
                os_cnt <= os_cnt - 1'b1;
            end

            // Error latch
            if (m_axi_rvalid && m_axi_rready && (m_axi_rresp != 2'b00)) begin
                resp_err <= 1'b1;
            end

            // R channel backpressure
            m_axi_rready <= !data_valid || data_ready;

            data_valid <= 1'b0;
            if (m_axi_rvalid && m_axi_rready) begin
                data_valid   <= 1'b1;
                data_payload <= m_axi_rdata;
                data_last    <= m_axi_rlast;
            end
        end
    end

    assign cmd_ready = (ar_state == AR_IDLE) && os_credit;

endmodule : axi_rd_master
`endif // AXI_RD_MASTER_SV
