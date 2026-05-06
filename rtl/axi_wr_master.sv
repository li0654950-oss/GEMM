//------------------------------------------------------------------------------
// axi_wr_master.sv
// GEMM AXI4 Write Master Protocol Layer
//
// Description:
//   Handles AW/W/B channel handshake, outstanding credit management.
//   W channel data is forwarded from dma_wr.
//------------------------------------------------------------------------------
`ifndef AXI_WR_MASTER_SV
`define AXI_WR_MASTER_SV

module axi_wr_master #(
    parameter int ADDR_W       = 64,
    parameter int AXI_DATA_W   = 256,
    parameter int AXI_ID_W     = 4,
    parameter int MAX_BURST_LEN= 16,
    parameter int OUTSTANDING_WR = 8
)(
    input  wire              clk,
    input  wire              rst_n,

    // AXI4 AW Channel -------------------------------------------------------
    output reg               m_axi_awvalid,
    input  wire              m_axi_awready,
    output reg  [AXI_ID_W-1:0] m_axi_awid,
    output reg  [ADDR_W-1:0] m_axi_awaddr,
    output reg  [7:0]        m_axi_awlen,
    output reg  [2:0]        m_axi_awsize,
    output reg  [1:0]        m_axi_awburst,
    output reg  [3:0]        m_axi_awcache,
    output reg  [2:0]        m_axi_awprot,

    // AXI4 W Channel --------------------------------------------------------
    output reg               m_axi_wvalid,
    input  wire              m_axi_wready,
    output reg  [AXI_DATA_W-1:0] m_axi_wdata,
    output reg  [AXI_DATA_W/8-1:0] m_axi_wstrb,
    output reg               m_axi_wlast,

    // AXI4 B Channel --------------------------------------------------------
    input  wire              m_axi_bvalid,
    output reg               m_axi_bready,
    input  wire [AXI_ID_W-1:0] m_axi_bid,
    input  wire [1:0]        m_axi_bresp,

    // Internal command interface --------------------------------------------
    input  wire              cmd_valid,
    output wire              cmd_ready,
    input  wire [ADDR_W-1:0] cmd_addr,
    input  wire [7:0]        cmd_len,
    input  wire [2:0]        cmd_size,

    // Internal data interface -----------------------------------------------
    input  wire              data_valid,
    output reg               data_ready,
    input  wire [AXI_DATA_W-1:0] data_payload,
    input  wire              data_last,
    input  wire [AXI_DATA_W/8-1:0] data_strb,

    // Response error --------------------------------------------------------
    output reg               resp_err
);

    localparam int OS_CNT_W = $clog2(OUTSTANDING_WR+1);
    localparam int WBEATS_W = $clog2(MAX_BURST_LEN+1);

    reg [OS_CNT_W-1:0] os_cnt;
    wire os_credit = (os_cnt < OUTSTANDING_WR);

    // AW FSM
    typedef enum logic [1:0] { AW_IDLE, AW_VALID } aw_state_t;
    aw_state_t aw_state;

    // W channel tracking
    reg [WBEATS_W-1:0] wbeat_cnt;
    reg                w_active;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_state      <= AW_IDLE;
            m_axi_awvalid <= 1'b0;
            os_cnt        <= '0;
            resp_err      <= 1'b0;
            w_active      <= 1'b0;
            wbeat_cnt     <= '0;
            m_axi_wvalid  <= 1'b0;
            m_axi_wlast   <= 1'b0;
        end else begin
            // AW channel
            case (aw_state)
                AW_IDLE: begin
                    if (cmd_valid && os_credit && !w_active) begin
                        aw_state      <= AW_VALID;
                        m_axi_awvalid <= 1'b1;
                        m_axi_awid    <= {AXI_ID_W{1'b0}};
                        m_axi_awaddr  <= cmd_addr;
                        m_axi_awlen   <= cmd_len;
                        m_axi_awsize  <= cmd_size;
                        m_axi_awburst <= 2'b01;
                        m_axi_awcache <= 4'b0011;
                        m_axi_awprot  <= 3'b000;
                        wbeat_cnt     <= '0;
                    end
                end
                AW_VALID: begin
                    if (m_axi_awready) begin
                        aw_state      <= AW_IDLE;
                        m_axi_awvalid <= 1'b0;
                        os_cnt        <= os_cnt + 1'b1;
                    end
                end
            endcase

            // B response: decrement os_cnt
            if (m_axi_bvalid && m_axi_bready) begin
                os_cnt <= os_cnt - 1'b1;
                if (m_axi_bresp != 2'b00) resp_err <= 1'b1;
            end

            // W channel beat counting
            if (w_active) begin
                if (data_valid && data_ready) begin
                    if (!w_active) w_active <= 1'b1;
                    m_axi_wdata  <= data_payload;
                    m_axi_wstrb  <= data_strb;
                    m_axi_wvalid <= 1'b1;
                    wbeat_cnt    <= wbeat_cnt + 1'b1;
                    if (wbeat_cnt == cmd_len[WBEATS_W-1:0]) begin
                        m_axi_wlast <= 1'b1;
                    end
                    if (data_last) begin
                        w_active    <= 1'b0;
                        m_axi_wlast <= 1'b1;
                    end
                end
                if (m_axi_wvalid && m_axi_wready) begin
                    m_axi_wvalid <= 1'b0;
                    if (m_axi_wlast) m_axi_wlast <= 1'b0;
                end
            end
        end
    end

    assign cmd_ready = (aw_state == AW_IDLE) && os_credit && !w_active;

    // B channel always ready
    always_comb begin
        m_axi_bready = 1'b1;
    end

    // Data ready when W channel can accept
    always_comb begin
        data_ready = !m_axi_wvalid;
    end

endmodule : axi_wr_master
`endif // AXI_WR_MASTER_SV
