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
    parameter WIN_SIZE = 16'd4096,  // unused (kept for block design compatibility)
    parameter CLK_HZ   = 50_000_000
)(
    // ---- RMII (LAN8720 via PMOD JC+JD) ------------------------------------
    input  wire        ref_clk,      // 50 MHz from LAN8720 OSC (T11)
    output logic [1:0]  rmii_txd,
    output logic        rmii_tx_en,
    input  wire [1:0]  rmii_rxd,
    input  wire        rmii_crs_dv,
    output logic        mdc,
    inout  wire         mdio,

    // ---- PS reset (active-low, from PS7 FCLKRESETN) ----------------------
    input  wire        ps_resetn,

    // ---- AXI4-Lite slave (from PS7) --------------------------------------
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,

    input  wire [5:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output logic        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output logic        s_axi_wready,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [5:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output logic        s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  wire        s_axi_rready,

    // ---- IRQ to PS -------------------------------------------------------
    output logic        irq_o,

    // ---- LED (kept for block design compatibility) -----------------------
    output logic [3:0]  led_tri_o
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
// ---------------------------------------------------------------------------
// MDIO初期化: LAN8720を100Mbps Full-duplexに強制設定
// ★元に戻す場合: 次の1行をコメントアウトする
//`define MDIO_FORCE_100FD
// ---------------------------------------------------------------------------
`ifdef MDIO_FORCE_100FD
// PHYアドレス: Waveshare LAN8720ボードは通常1 (RXER/PHYAD0ストラップ依存)
// 動作しない場合は 5'd0 に変更して試すこと
localparam [4:0]  MDIO_PHY_ADDR  = 5'd1;
localparam [4:0]  MDIO_REG_BASIC = 5'd0;      // Basic Control Register
// 0x2100: bit13=100Mbps, bit12=0(AutoNeg OFF), bit8=Full-duplex
localparam [15:0] MDIO_CTRL_VAL  = 16'h2100;

// 64ビットMDIOライトフレーム (MSBファースト送出)
// [PRE×32(1)][ST=01][OP=01][PHYAD×5][REGAD×5][TA=10][DATA×16]
localparam [63:0] MDIO_FRAME = {
    32'hFFFF_FFFF,  // Preamble (32×1)
    2'b01,          // ST (start of frame)
    2'b01,          // OP (write)
    MDIO_PHY_ADDR,  // PHYAD [4:0]
    MDIO_REG_BASIC, // REGAD [4:0]
    2'b10,          // TA (turnaround)
    MDIO_CTRL_VAL   // DATA [15:0]
};

logic [5:0] mdio_bit       = 6'd63; // 63→0 の順に送出
logic       mdio_init_done = 1'b0;
logic       mdio_drv       = 1'b1;  // 1=ドライブ中, 0=Hi-Z解放
logic       mdio_val       = 1'b1;  // MDIO出力値 (初期値=1: プリアンブル相当)

// MDC立下り (mdc_cnt==24 かつ mdc==1 → 次サイクルで mdc が0) のタイミングで
// MDIOビットを更新する。LAN8720はMDC立上りでサンプリングするため、
// 立下り直後に変更すれば25クロック(=1μs)のセットアップ時間を確保できる。
always_ff @(posedge clk_50 or negedge rst_50_n) begin
    if (!rst_50_n) begin
        mdio_bit       <= 6'd63;
        mdio_init_done <= 1'b0;
        mdio_drv       <= 1'b1;
        mdio_val       <= 1'b1;
    end else if (!mdio_init_done) begin
        if (mdc_cnt == 6'd24 && mdc == 1'b1) begin  // MDC立下りエッジ
            mdio_val <= MDIO_FRAME[mdio_bit];
            if (mdio_bit == 6'd0) begin
                mdio_init_done <= 1'b1;
                mdio_drv       <= 1'b0;  // 完了後はHi-Zに解放
            end else
                mdio_bit <= mdio_bit - 1'b1;
        end
    end
end

// 初期化中はMDIO出力ドライブ、完了後はHi-Z
assign mdio = mdio_drv ? mdio_val : 1'bz;
`else
// MDIO Hi-Z: PHYはストラップ設定(AutoNeg)で動作
assign mdio = 1'bz;
`endif

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
logic        send_req, arp_send_req;
logic        tx_busy, arp_mac_valid;
logic [7:0]  tx_wr_data;
logic        tx_wr_en, tx_wr_full;
logic [7:0]  rx_rd_data;
logic        rx_rd_en, rx_rd_empty;
logic [11:0] rx_rd_count;

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
    .addr_valid       (addr_valid),
    .send_req         (send_req),
    .arp_send_req     (arp_send_req),
    .tx_wr_data       (tx_wr_data),
    .tx_wr_en         (tx_wr_en),
    .tx_wr_full       (tx_wr_full),
    .rx_rd_data       (rx_rd_data),
    .rx_rd_en_out     (),
    .rx_rd_en         (rx_rd_en),
    .rx_rd_empty      (rx_rd_empty),
    .rx_rd_count      (rx_rd_count),
    .tx_busy_50       (tx_busy),
    .arp_mac_valid_50 (arp_mac_valid)
);

// ---------------------------------------------------------------------------
// TOE engine
// ---------------------------------------------------------------------------
toe_engine #(
    .PAYLOAD_BYTES (64),
    .CLK_HZ        (CLK_HZ)
) u_engine (
    .clk           (clk_50),
    .rst_n         (rst_50_n),
    .local_mac     (local_mac),
    .remote_mac    (remote_mac),
    .local_ip      (local_ip),
    .remote_ip     (remote_ip),
    .local_port    (local_port),
    .remote_port   (remote_port),
    .addr_valid    (addr_valid),
    .send_req      (send_req),
    .arp_send_req  (arp_send_req),
    .arp_mac_valid (arp_mac_valid),
    .arp_mac_o     (),
    .tx_wr_data    (tx_wr_data),
    .tx_wr_en      (tx_wr_en),
    .tx_wr_full    (tx_wr_full),
    .rx_rd_data    (rx_rd_data),
    .rx_rd_en      (rx_rd_en),
    .rx_rd_empty   (rx_rd_empty),
    .rx_rd_count   (rx_rd_count),
    .mac_rx_tdata  (mac_rx_tdata),
    .mac_rx_tvalid (mac_rx_tvalid),
    .mac_rx_tlast  (mac_rx_tlast),
    .mac_rx_tuser  (mac_rx_tuser),
    .mac_tx_tdata  (mac_tx_tdata),
    .mac_tx_tvalid (mac_tx_tvalid),
    .mac_tx_tready (mac_tx_tready),
    .mac_tx_tlast  (mac_tx_tlast),
    .tx_busy       (tx_busy)
);

assign irq_o     = 1'b0;
assign led_tri_o = {rst_50_n, ~rx_rd_empty, arp_mac_valid, tx_busy};

endmodule
`default_nettype wire
