//------------------------------------------------------------------------------
// tb_gemm_top.sv
// GEMM Top-Level Smoke Testbench
//
// AXI-Lite master uses single always_ff block like tb_csr_if to avoid
// cross-always scheduling ambiguity with Verilator --timing.
//------------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_gemm_top;
    import gemm_pkg::*;

    localparam int SIM_CYCLES = 5000;
    localparam int ADDR_W     = 64;
    localparam int AXIL_ADDR_W= 16;
    localparam int AXI_DATA_W = 256;
    localparam int AXI_ID_W   = 4;
    localparam int AXI_STRB_W = AXI_DATA_W / 8;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // AXI4-Lite: TB drives Master -> DUT Slave
    reg  [AXIL_ADDR_W-1:0] s_axil_awaddr;
    reg              s_axil_awvalid;
    wire             s_axil_awready;
    reg  [31:0]      s_axil_wdata;
    reg  [3:0]       s_axil_wstrb;
    reg              s_axil_wvalid;
    wire             s_axil_wready;
    wire [1:0]       s_axil_bresp;
    wire             s_axil_bvalid;
    reg              s_axil_bready;

    reg  [AXIL_ADDR_W-1:0] s_axil_araddr;
    reg              s_axil_arvalid;
    wire             s_axil_arready;
    wire [31:0]      s_axil_rdata;
    wire [1:0]       s_axil_rresp;
    wire             s_axil_rvalid;
    reg              s_axil_rready;

    // AXI4: DUT Master -> TB Slave (memory model)
    wire             m_axi_arvalid;
    reg              m_axi_arready;
    wire [AXI_ID_W-1:0]  m_axi_arid;
    wire [ADDR_W-1:0] m_axi_araddr;
    wire [7:0]       m_axi_arlen;
    wire [2:0]       m_axi_arsize;
    wire [1:0]       m_axi_arburst;

    reg              m_axi_rvalid;
    wire             m_axi_rready;
    reg  [AXI_ID_W-1:0]  m_axi_rid;
    reg  [AXI_DATA_W-1:0] m_axi_rdata;
    reg  [1:0]       m_axi_rresp;
    reg              m_axi_rlast;

    wire             m_axi_awvalid;
    reg              m_axi_awready;
    wire [AXI_ID_W-1:0]  m_axi_awid;
    wire [ADDR_W-1:0] m_axi_awaddr;
    wire [7:0]       m_axi_awlen;
    wire [2:0]       m_axi_awsize;
    wire [1:0]       m_axi_awburst;

    wire             m_axi_wvalid;
    reg              m_axi_wready;
    wire [AXI_DATA_W-1:0] m_axi_wdata;
    wire [AXI_STRB_W-1:0] m_axi_wstrb;
    wire             m_axi_wlast;

    reg              m_axi_bvalid;
    wire             m_axi_bready;
    reg  [AXI_ID_W-1:0]  m_axi_bid;
    reg  [1:0]       m_axi_bresp;

    wire             irq_o;

    // DUT
    gemm_top #(
        .P_M(4), .P_N(4), .ELEM_W(16), .ACC_W(32),
        .ADDR_W(ADDR_W), .AXIL_ADDR_W(AXIL_ADDR_W),
        .AXI_DATA_W(AXI_DATA_W), .AXI_ID_W(AXI_ID_W)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb), .s_axil_wvalid(s_axil_wvalid), .s_axil_wready(s_axil_wready),
        .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid), .s_axil_bready(s_axil_bready),
        .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready),
        .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp), .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
        .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
        .irq_o(irq_o)
    );

    // AXI4 memory model (simple slave)
    reg [AXI_DATA_W-1:0] mem [0:1023];
    initial begin
        integer i;
        for (i=0; i<1024; i=i+1) mem[i] = {8{32'hDEADBEEF + i}};
    end

    // AR/R channel slave
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            m_axi_arready <= 1'b0;
            m_axi_rvalid  <= 1'b0;
            m_axi_rlast   <= 1'b0;
        end else begin
            m_axi_arready <= 1'b1;
            if (m_axi_arvalid && m_axi_arready) begin
                m_axi_rvalid <= 1'b1;
                m_axi_rlast  <= 1'b1;
                m_axi_rdata  <= mem[m_axi_araddr[15:0]];
                m_axi_rid    <= m_axi_arid;
                m_axi_rresp  <= 2'b00;
            end else if (m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid <= 1'b0;
                m_axi_rlast  <= 1'b0;
            end
        end
    end

    // AW/W/B channel slave
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            m_axi_awready <= 1'b0;
            m_axi_wready  <= 1'b0;
            m_axi_bvalid  <= 1'b0;
        end else begin
            m_axi_awready <= 1'b1;
            m_axi_wready  <= 1'b1;
            if (m_axi_wvalid && m_axi_wready) begin
                m_axi_bvalid <= 1'b1;
                m_axi_bid    <= m_axi_awid;
                m_axi_bresp  <= 2'b00;
            end else if (m_axi_bvalid && m_axi_bready) begin
                m_axi_bvalid <= 1'b0;
            end
        end
    end

    // AXI4-Lite master FSM (single always_ff like tb_csr_if)
    typedef enum integer {
        L_IDLE, L_SETUP, L_AW, L_W, L_WAIT_B, L_DONE
    } lite_state_t;
    lite_state_t lite_state;

    reg [15:0] lite_addr_r;
    reg [31:0] lite_wdata_r;
    reg [3:0]  lite_wstrb_r;
    reg        lite_start_p;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lite_state     <= L_IDLE;
            lite_addr_r    <= 0;
            lite_wdata_r   <= 0;
            lite_wstrb_r   <= 0;
            lite_start_p   <= 0;
            s_axil_awaddr  <= 0;
            s_axil_awvalid <= 0;
            s_axil_wdata   <= 0;
            s_axil_wstrb   <= 0;
            s_axil_wvalid  <= 0;
            s_axil_bready  <= 0;
        end else begin
            case (lite_state)
                L_IDLE: begin
                    s_axil_awvalid <= 1'b0;
                    s_axil_wvalid  <= 1'b0;
                    s_axil_bready  <= 1'b0;
                    if (lite_start_p) begin
                        lite_addr_r  <= lite_addr_r;
                        lite_wdata_r <= lite_wdata_r;
                        lite_wstrb_r <= lite_wstrb_r;
                        lite_state   <= L_SETUP;
                    end
                end
                L_SETUP: begin
                    s_axil_awaddr  <= lite_addr_r;
                    s_axil_wdata   <= lite_wdata_r;
                    s_axil_wstrb   <= lite_wstrb_r;
                    s_axil_awvalid <= 1'b1;
                    s_axil_wvalid  <= 1'b1;
                    lite_state     <= L_AW;
                end
                L_AW: begin
                    if (s_axil_awready) begin
                        s_axil_awvalid <= 1'b0;
                        lite_state     <= L_W;
                    end
                end
                L_W: begin
                    if (s_axil_wready) begin
                        // wvalid stays 1 until bvalid (like tb_csr_if)
                        lite_state <= L_WAIT_B;
                    end
                end
                L_WAIT_B: begin
                    if (s_axil_bvalid) begin
                        s_axil_wvalid <= 1'b0;
                        s_axil_bready <= 1'b1;
                        lite_state    <= L_DONE;
                    end
                end
                L_DONE: begin
                    s_axil_bready <= 1'b0;
                    lite_start_p  <= 1'b0;
                    lite_state    <= L_IDLE;
                end
            endcase
        end
    end

    // Timeout watchdog
    integer cycle_cnt;
    always_ff @(posedge clk) begin
        if (!rst_n) cycle_cnt <= 0;
        else cycle_cnt <= cycle_cnt + 1;
    end

    always_ff @(posedge clk) begin
        if (rst_n && cycle_cnt >= SIM_CYCLES) begin
            $display("TB: TIMEOUT watchdog at cycle %0d, lite_state=%0d irq_o=%b", cycle_cnt, lite_state, irq_o);
            $finish;
        end
    end

    // Test sequence
    reg test_pass;

    task automatic csr_write(input [15:0] addr, input [31:0] data);
        begin
            lite_addr_r  = addr;
            lite_wdata_r = data;
            lite_wstrb_r = 4'hF;
            lite_start_p = 1;
            $display("TB: CSR write 0x%04X = 0x%08X started", addr, data);
            while (lite_state != L_DONE) begin
                @(posedge clk);
            end
            @(posedge clk);
            $display("TB: CSR write 0x%04X done at cycle %0d", addr, cycle_cnt);
        end
    endtask

    initial begin
        $display("TB: ===== GEMM Top Smoke Test Start =====");
        rst_n = 0;
        test_pass = 0;
        repeat(4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        $display("TB: Reset released at cycle %0d", cycle_cnt);

        // Write configuration
        csr_write(16'h020, 32'd4);  // CFG_M = 4
        csr_write(16'h024, 32'd4);  // CFG_N = 4
        csr_write(16'h028, 32'd4);  // CFG_K = 4
        csr_write(16'h030, 32'h00001000); // ADDR_A_LO
        csr_write(16'h038, 32'h00002000); // ADDR_B_LO
        csr_write(16'h048, 32'h00003000); // ADDR_D_LO
        csr_write(16'h050, 32'd8);  // STRIDE_A
        csr_write(16'h054, 32'd8);  // STRIDE_B
        csr_write(16'h05C, 32'd8);  // STRIDE_D
        csr_write(16'h060, 32'h00000004); // TILE_M = 4
        csr_write(16'h064, 32'h00000004); // TILE_N = 4
        csr_write(16'h068, 32'd4);  // TILE_K

        // Write CMD_START (bit0=start, bit2=irq_en)
        csr_write(16'h000, 32'h5);
        $display("TB: All CSR writes done. Waiting for irq_o...");

        while (!irq_o) @(posedge clk);

        $display("TB: PASS: irq_o asserted after %0d cycles", cycle_cnt);
        test_pass = 1;
        $display("TB: GEMM Top Smoke Test %s", test_pass ? "PASS" : "FAIL");
        $finish;
    end

endmodule
