`default_nettype none
// 改版履歴:
//   rev7 2026-06-02  LED: LD3をTCP_ESTABLISHED→mac_tx_tvalid stickyに変更(tcp_hdr_gen診断用)
//   rev6 2026-06-01  LED: LD2をCRC正常RX→SYN_SENT到達に変更(tcp_busy修正後のSYN送信確認用)
//   rev5 2026-06-01  LEDをTX/RX正常/ARP解決/TCP確立の診断フローに再設計
//   rev4 2026-06-01  clk_50をBUFG明示インスタンスに変更: カスタムIPではVivado自動挿入が効かずタイミング違反の原因になっていた
//   rev3 2026-05-31  LEDデバッグ再設計: 全LED sticky化、LED1=crs_dv、LED2=mac_rx
//   rev2 2026-05-31  toe_engine: TXアービタのtreadyゲーティング修正
//   rev1 2026-05-31  frame_mux: rx_tlastを常時転送してrx_idxデシンクを防止
//
// TOEトップモジュール (ZYBO Z7-20 + Waveshare LAN8720 ETH ボード)
//
// クロック構成:
//   LAN8720の発振器 → REF_CLK (50MHz) → FPGAピン T12 (非CCIO) → BUFG → clk_50
//   PSからs_axi_aclk (50MHz, 独立クロックドメイン)
//
// パワーオンリセット:
//   ps_resetn (PSから) を clk_50 で4段シフトレジスタ同期 → rst_50_n 生成
//
// MDIO:
//   MDCはclk_50÷50=1MHz で生成。MDIOはHi-Z固定。PHYはストラップピンで自動設定。

module toe_top #(
    parameter WIN_SIZE = 16'd4096,   // TCPウィンドウサイズ (バイト)
    parameter CLK_HZ   = 50_000_000  // clk_50 周波数
)(
    // ---- RMII (LAN8720, PMOD JC+JB) ----------------------------------------
    input  wire        ref_clk,       // LAN8720からの50MHz基準クロック (T12)
    output logic [1:0] rmii_txd,      // RMII送信データ (2bit)
    output logic       rmii_tx_en,    // RMII送信イネーブル
    input  wire  [1:0] rmii_rxd,      // RMII受信データ (2bit)
    input  wire        rmii_crs_dv,   // キャリアセンス/データバリッド
    output logic       mdc,           // MII管理クロック (1MHz)
    inout  wire        mdio,          // MII管理データ (Hi-Z固定)

    // ---- PSリセット (PS7 FCLKRESETN, Active-Low) ----------------------------
    input  wire        ps_resetn,

    // ---- AXI4-Lite スレーブ (PS7から) ----------------------------------------
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,
    input  wire [5:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output logic       s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output logic       s_axi_wready,
    output logic [1:0] s_axi_bresp,
    output logic       s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [5:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output logic       s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  wire        s_axi_rready,

    // ---- PSへの割り込み -------------------------------------------------------
    output logic       irq_o,

    // ---- デバッグLED (ZYBO LD0-LD3, 全てstickyラッチ) -----------------------
    // LD0 = TX送信あり    (rmii_tx_enが一度でもHigh → FPGAがフレームを送信した)
    // LD1 = PHY受信あり   (rmii_crs_dvが一度でもHigh → LAN8720がリンクUP+受信)
    // LD2 = MAC RX有効    (CRC正常なバイトを受信)
    // LD3 = ARP解決済み   (arp_mac_validが一度でもHigh)
    output logic [3:0] led_tri_o
);

// ---------------------------------------------------------------------------
// クロック: ref_clk → BUFG → clk_50
// カスタムIPではVivadoがBUFGを自動挿入しないため明示的にインスタンス化する
// ---------------------------------------------------------------------------
logic clk_50;
BUFG u_clk_buf (.I(ref_clk), .O(clk_50));

// ---------------------------------------------------------------------------
// パワーオンリセット同期回路 (clk_50ドメイン)
// ps_resetn=0でシフトレジスタをクリア、ps_resetn=1で4クロック後にrst_50_n=1
// ---------------------------------------------------------------------------
logic [3:0] rst_sr = '0;
logic       rst_50_n;

always_ff @(posedge clk_50 or negedge ps_resetn) begin
    if (!ps_resetn) rst_sr <= '0;              // PSリセット中は全ビット0
    else            rst_sr <= {rst_sr[2:0], 1'b1}; // 毎クロック1をシフトイン
end
assign rst_50_n = rst_sr[3]; // 4段遅延後にリセット解除

// ---------------------------------------------------------------------------
// MDCクロック生成: 50MHz ÷ 50 = 1MHz
// カウンタが24になるたびにMDCをトグル → 周期50クロック = 1MHz
// ---------------------------------------------------------------------------
logic [5:0] mdc_cnt = '0;
always_ff @(posedge clk_50 or negedge rst_50_n) begin
    if (!rst_50_n) begin
        mdc_cnt <= '0;
        mdc     <= 1'b0;
    end else begin
        if (mdc_cnt == 6'd24) begin
            mdc_cnt <= '0;
            mdc     <= ~mdc;  // MDCトグル
        end else
            mdc_cnt <= mdc_cnt + 1'b1;
    end
end
assign mdio = 1'bz; // MDIOはHi-Z固定 (PHYはストラップで自動設定)

// ---------------------------------------------------------------------------
// RMII MACインターフェース
// RX: rmii_rxd/crs_dv → AXI-Stream (mac_rx_*)
// TX: AXI-Stream (mac_tx_*) → rmii_txd/tx_en
// ---------------------------------------------------------------------------
logic [7:0] mac_rx_tdata;
logic       mac_rx_tvalid, mac_rx_tlast, mac_rx_tuser; // tuser=1はCRCエラー
logic [7:0] mac_tx_tdata;
logic       mac_tx_tvalid, mac_tx_tready, mac_tx_tlast;

rmii_mac #(
    .USE_RMII (1)
) u_mac (
    .clk         (clk_50),
    .rst_n       (rst_50_n),
    .rmii_rxd    (rmii_rxd),
    .rmii_crs_dv (rmii_crs_dv),
    .rmii_txd    (rmii_txd),
    .rmii_tx_en  (rmii_tx_en),
    .rx_tdata    (mac_rx_tdata),
    .rx_tvalid   (mac_rx_tvalid),
    .rx_tlast    (mac_rx_tlast),
    .rx_tuser    (mac_rx_tuser),
    .tx_tdata    (mac_tx_tdata),
    .tx_tvalid   (mac_tx_tvalid),
    .tx_tready   (mac_tx_tready),
    .tx_tlast    (mac_tx_tlast)
);

// ---------------------------------------------------------------------------
// AXI4-Liteレジスタ + クロックドメイン変換 (CDC)
// PSドメイン(s_axi_aclk) ↔ clk_50ドメイン間のデータ橋渡し
// ---------------------------------------------------------------------------
logic [47:0] local_mac,  remote_mac;  // MACアドレス (clk_50ドメイン)
logic [31:0] local_ip,   remote_ip;   // IPアドレス
logic [15:0] local_port, remote_port; // TCPポート番号
logic        addr_valid;              // 全アドレスレジスタが非ゼロのとき1
logic        connect_req, disconnect_req, arp_send_req; // PS→FPGAの制御信号
logic [7:0]  tx_wr_data;
logic        tx_wr_en, tx_wr_full;    // TXデータFIFO書き込み
logic [7:0]  rx_rd_data;
logic        rx_rd_en, rx_rd_empty;   // RXデータFIFO読み出し
logic [11:0] rx_rd_count;             // RXバッファ残バイト数
logic [3:0]  tcp_state;               // TCP FSM状態 (clk_50ドメイン)
logic        irq_50;                  // 割り込み要求
logic        arp_mac_valid;           // ARP解決済みフラグ

axi4lite_regs u_regs (
    .s_axi_aclk     (s_axi_aclk),
    .s_axi_aresetn  (s_axi_aresetn),
    .s_axi_awaddr   (s_axi_awaddr),   .s_axi_awvalid  (s_axi_awvalid),
    .s_axi_awready  (s_axi_awready),  .s_axi_wdata    (s_axi_wdata),
    .s_axi_wstrb    (s_axi_wstrb),    .s_axi_wvalid   (s_axi_wvalid),
    .s_axi_wready   (s_axi_wready),   .s_axi_bresp    (s_axi_bresp),
    .s_axi_bvalid   (s_axi_bvalid),   .s_axi_bready   (s_axi_bready),
    .s_axi_araddr   (s_axi_araddr),   .s_axi_arvalid  (s_axi_arvalid),
    .s_axi_arready  (s_axi_arready),  .s_axi_rdata    (s_axi_rdata),
    .s_axi_rresp    (s_axi_rresp),    .s_axi_rvalid   (s_axi_rvalid),
    .s_axi_rready   (s_axi_rready),
    .clk_50         (clk_50),         .rst_50_n        (rst_50_n),
    .local_mac      (local_mac),      .remote_mac      (remote_mac),
    .local_ip       (local_ip),       .remote_ip       (remote_ip),
    .local_port     (local_port),     .remote_port     (remote_port),
    .addr_valid     (addr_valid),
    .connect_req    (connect_req),    .disconnect_req  (disconnect_req),
    .arp_send_req   (arp_send_req),
    .tx_wr_data     (tx_wr_data),     .tx_wr_en        (tx_wr_en),
    .tx_wr_full     (tx_wr_full),
    .rx_rd_data     (rx_rd_data),     .rx_rd_en_out    (),
    .rx_rd_en       (rx_rd_en),       .rx_rd_empty     (rx_rd_empty),
    .rx_rd_count    (rx_rd_count),
    .tcp_state_50       (tcp_state),
    .irq_50             (irq_50),
    .arp_mac_valid_50   (arp_mac_valid)
);

// ---------------------------------------------------------------------------
// TOEエンジン: ARP解決 + TCP Full-Stack
// ---------------------------------------------------------------------------
toe_engine #(
    .WIN_SIZE (WIN_SIZE),
    .CLK_HZ   (CLK_HZ)
) u_engine (
    .clk             (clk_50),
    .rst_n           (rst_50_n),
    .local_mac       (local_mac),      .remote_mac      (remote_mac),
    .local_ip        (local_ip),       .remote_ip       (remote_ip),
    .local_port      (local_port),     .remote_port     (remote_port),
    .addr_valid      (addr_valid),
    .connect_req     (connect_req),    .disconnect_req  (disconnect_req),
    .arp_send_req    (arp_send_req),
    .arp_mac_valid   (arp_mac_valid),  .arp_mac_o       (), // 解決MACはSW不要のため未接続
    .tx_wr_data      (tx_wr_data),     .tx_wr_en        (tx_wr_en),
    .tx_wr_full      (tx_wr_full),
    .rx_rd_data      (rx_rd_data),     .rx_rd_en        (rx_rd_en),
    .rx_rd_empty     (rx_rd_empty),    .rx_rd_count     (rx_rd_count),
    .mac_rx_tdata    (mac_rx_tdata),   .mac_rx_tvalid   (mac_rx_tvalid),
    .mac_rx_tlast    (mac_rx_tlast),   .mac_rx_tuser    (mac_rx_tuser),
    .mac_tx_tdata    (mac_tx_tdata),   .mac_tx_tvalid   (mac_tx_tvalid),
    .mac_tx_tready   (mac_tx_tready),  .mac_tx_tlast    (mac_tx_tlast),
    .tcp_state       (tcp_state),
    .irq             (irq_50)
);

assign irq_o = irq_50; // 割り込みをPSへ出力

// ---------------------------------------------------------------------------
// デバッグLED (全てstickyラッチ: 一度でも条件が成立したらリセットまで保持)
//
// 診断フロー (rev7診断ビルド):
//   LED0=×             → TX パス壊れ (rmii_tx_en未アサート)
//   LED0=○, LED1=×     → ARP 解決失敗
//   LED2=×             → tcp_state_ctrlが SYN_SENT に遷移せず (connect_req CDC異常)
//   LED3=×, LED2=○     → tcp_hdr_genがmac_tx_tvalidを出せていない (tcp_hdr_gen不動作)
//   LED3=○, LED0=×     → mac_tx_tvalidは出たがrmii_tx_enが上がらない (MAC TXパス異常)
//   LED0=○, LED3=○     → TCP SYN は送出されている → PC/RXパス問題
// ---------------------------------------------------------------------------
logic tx_en_sticky;        // LD0: rmii_tx_en sticky (物理TX確認)
logic arp_mac_sticky;      // LD1: ARP解決済み
logic syn_sent_sticky;     // LD2: SYN_SENT到達 (tcp_state_ctrl動作確認)
logic mac_tx_valid_sticky; // LD3: mac_tx_tvalid sticky (tcp_hdr_gen→MAC到達確認)

always_ff @(posedge clk_50 or negedge rst_50_n) begin
    if (!rst_50_n) begin
        tx_en_sticky        <= 1'b0;
        arp_mac_sticky      <= 1'b0;
        syn_sent_sticky     <= 1'b0;
        mac_tx_valid_sticky <= 1'b0;
    end else begin
        if (rmii_tx_en)          tx_en_sticky        <= 1'b1;
        if (arp_mac_valid)       arp_mac_sticky      <= 1'b1;
        if (tcp_state == 4'd1)   syn_sent_sticky     <= 1'b1;
        if (mac_tx_tvalid)       mac_tx_valid_sticky <= 1'b1; // TCP or ARP どちらでも
    end
end

assign led_tri_o[0] = tx_en_sticky;
assign led_tri_o[1] = arp_mac_sticky;
assign led_tri_o[2] = syn_sent_sticky;
assign led_tri_o[3] = mac_tx_valid_sticky;

endmodule
`default_nettype wire
