`default_nettype none
// TOE top-level for ZYBO Z7-20 + Waveshare LAN8720 ETH Board.
//
// Clock plan:
//   LAN8720 OSC → REF_CLK (50 MHz) → FPGA pin T11 (MRCC_P) → IBUFG →
//   BUFG → clk_50.  PS provides s_axi_aclk (50 MHz, independent domain).
//
// Power-on reset:
//   ps_resetn (from PS) synchronised through 4-stage shift register on
//   clk_50 to generate rst_50_n.
//
// MDIO:
//   MDC driven as clk_50 / 50 = 1 MHz.
//   MDIO is left undriven (tri-state); PHY auto-negotiates via strap pins.

module toe_top #(
    parameter WIN_SIZE = 16'd4096,
    parameter CLK_HZ   = 50_000_000
)(
    // ---- RMII (LAN8720 via PMOD JC+JD) ------------------------------------
    input  logic        ref_clk,      // 50 MHz from LAN8720 OSC (T11)
    output logic [1:0]  rmii_txd,
    output logic        rmii_tx_en,
    input  logic [1:0]  rmii_rxd,
    input  logic        rmii_crs_dv,
    output logic        mdc,
    inout  wire         mdio,

    // ---- PS reset (active-low, from PS7 FCLKRESETN) ----------------------
    input  logic        ps_resetn,

    // ---- AXI4-Lite slave (from PS7) --------------------------------------
    input  logic        s_axi_aclk,
    input  logic        s_axi_aresetn,

    input  logic [5:0]  s_axi_awaddr,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,
    input  logic [5:0]  s_axi_araddr,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    // ---- IRQ to PS -------------------------------------------------------
    output logic        irq_o
);

// ---------------------------------------------------------------------------
// Clock: ref_clk is used directly as clk_50.
// IBUFG/BUFG are inserted automatically by Vivado at the block design
// wrapper level when ref_clk is declared as an external clock port.
// ---------------------------------------------------------------------------
logic clk_50;
assign clk_50 = ref_clk;

// ---------------------------------------------------------------------------
// Power-on reset synchroniser (clk_50 domain)
// ---------------------------------------------------------------------------
logic [3:0] rst_sr = '0;
logic       rst_50_n;

always_ff @(posedge clk_50 or negedge ps_resetn) begin
    if (!ps_resetn) rst_sr <= '0;
    else            rst_sr <= {rst_sr[2:0], 1'b1};
end
assign rst_50_n = rst_sr[3];

// ---------------------------------------------------------------------------
// MDC generation: clk_50 / 50 = 1 MHz
// ---------------------------------------------------------------------------
logic [5:0] mdc_cnt = '0;
always_ff @(posedge clk_50 or negedge rst_50_n) begin
    if (!rst_50_n) begin
        mdc_cnt <= '0;
        mdc     <= 1'b0;
    end else begin
        if (mdc_cnt == 6'd24) begin
            mdc_cnt <= '0;
            mdc     <= ~mdc;
        end else
            mdc_cnt <= mdc_cnt + 1'b1;
    end
end
assign mdio = 1'bz;   // leave MDIO tristated; PHY uses straps

// ---------------------------------------------------------------------------
// RMII MAC
// ---------------------------------------------------------------------------
logic [7:0]  mac_rx_tdata;
logic        mac_rx_tvalid, mac_rx_tlast, mac_rx_tuser;
logic [7:0]  mac_tx_tdata;
logic        mac_tx_tvalid, mac_tx_tready, mac_tx_tlast;

rmii_mac #(
    .USE_RMII (1)
) u_mac (
    .clk        (clk_50),
    .rst_n      (rst_50_n),
    // RMII PHY pins
    .rmii_rxd   (rmii_rxd),
    .rmii_crs_dv(rmii_crs_dv),
    .rmii_txd   (rmii_txd),
    .rmii_tx_en (rmii_tx_en),
    // RX AXI-Stream output
    .rx_tdata   (mac_rx_tdata),
    .rx_tvalid  (mac_rx_tvalid),
    .rx_tlast   (mac_rx_tlast),
    .rx_tuser   (mac_rx_tuser),
    // TX AXI-Stream input
    .tx_tdata   (mac_tx_tdata),
    .tx_tvalid  (mac_tx_tvalid),
    .tx_tready  (mac_tx_tready),
    .tx_tlast   (mac_tx_tlast)
);

// ---------------------------------------------------------------------------
// AXI4-Lite registers + CDC
// ---------------------------------------------------------------------------
logic [47:0] local_mac,  remote_mac;
logic [31:0] local_ip,   remote_ip;
logic [15:0] local_port, remote_port;
logic        addr_valid;
logic        connect_req, disconnect_req, arp_send_req;
logic [7:0]  tx_wr_data;
logic        tx_wr_en, tx_wr_full;
logic [7:0]  rx_rd_data;
logic        rx_rd_en, rx_rd_empty;
logic [11:0] rx_rd_count;
logic [3:0]  tcp_state;
logic        irq_50;

axi4lite_regs u_regs (
    .s_axi_aclk    (s_axi_aclk),
    .s_axi_aresetn (s_axi_aresetn),
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),
    .clk_50        (clk_50),
    .rst_50_n      (rst_50_n),
    .local_mac     (local_mac),
    .remote_mac    (remote_mac),
    .local_ip      (local_ip),
    .remote_ip     (remote_ip),
    .local_port    (local_port),
    .remote_port   (remote_port),
    .addr_valid    (addr_valid),
    .connect_req   (connect_req),
    .disconnect_req(disconnect_req),
    .arp_send_req  (arp_send_req),
    .tx_wr_data    (tx_wr_data),
    .tx_wr_en      (tx_wr_en),
    .tx_wr_full    (tx_wr_full),
    .rx_rd_data    (rx_rd_data),
    .rx_rd_en_out  (),
    .rx_rd_en      (rx_rd_en),
    .rx_rd_empty   (rx_rd_empty),
    .rx_rd_count   (rx_rd_count),
    .tcp_state_50  (tcp_state),
    .irq_50        (irq_50)
);

// ---------------------------------------------------------------------------
// TOE engine
// ---------------------------------------------------------------------------
toe_engine #(
    .WIN_SIZE (WIN_SIZE),
    .CLK_HZ   (CLK_HZ)
) u_engine (
    .clk            (clk_50),
    .rst_n          (rst_50_n),
    .local_mac      (local_mac),
    .remote_mac     (remote_mac),
    .local_ip       (local_ip),
    .remote_ip      (remote_ip),
    .local_port     (local_port),
    .remote_port    (remote_port),
    .addr_valid     (addr_valid),
    .connect_req    (connect_req),
    .disconnect_req (disconnect_req),
    .arp_send_req   (arp_send_req),
    .arp_mac_valid  (),
    .arp_mac_o      (),
    .tx_wr_data     (tx_wr_data),
    .tx_wr_en       (tx_wr_en),
    .tx_wr_full     (tx_wr_full),
    .rx_rd_data     (rx_rd_data),
    .rx_rd_en       (rx_rd_en),
    .rx_rd_empty    (rx_rd_empty),
    .rx_rd_count    (rx_rd_count),
    .mac_rx_tdata   (mac_rx_tdata),
    .mac_rx_tvalid  (mac_rx_tvalid),
    .mac_rx_tlast   (mac_rx_tlast),
    .mac_rx_tuser   (mac_rx_tuser),
    .mac_tx_tdata   (mac_tx_tdata),
    .mac_tx_tvalid  (mac_tx_tvalid),
    .mac_tx_tready  (mac_tx_tready),
    .mac_tx_tlast   (mac_tx_tlast),
    .tcp_state      (tcp_state),
    .irq            (irq_50)
);

assign irq_o = irq_50;

endmodule
`default_nettype wire
