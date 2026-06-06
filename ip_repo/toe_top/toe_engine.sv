`default_nettype none
// 改版履歴:
//   rev2 2026-06-03  ARP解決MACをTCP宛先MACに使用: arp_mac_valid=1時はarp_mac_oをeffective_remote_macとしてtcp_layerに渡す
//   rev1 2026-05-31  TXアービタ: 非アクティブパスへのtreadyを遮断
//
// TOEエンジン トップ
// サブモジュール: frame_mux, arp_engine, tcp_layer, TXアービタ
//
// TXアービタ方針:
//   ARPが最優先。ARP送信中(arp_tx_tvalid=1)はTCPのtreadyを0にして
//   TCPポインタが誤って進むのを防ぐ。

module toe_engine #(
    parameter WIN_SIZE = 16'd4096,
    parameter CLK_HZ   = 50_000_000
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- アドレス設定 (clk_50ドメイン) ----------------------------------------
    input  wire [47:0] local_mac,
    input  wire [47:0] remote_mac,
    input  wire [31:0] local_ip,
    input  wire [31:0] remote_ip,
    input  wire [15:0] local_port,
    input  wire [15:0] remote_port,
    input  wire        addr_valid,    // 全アドレスレジスタ非ゼロ

    // ---- PS制御信号 (2FF同期済み) ---------------------------------------------
    input  wire        connect_req,
    input  wire        disconnect_req,

    // ---- ARP制御 ---------------------------------------------------------------
    input  wire        arp_send_req,  // ARPリクエスト送信トリガ
    output logic       arp_mac_valid, // ARP解決済みフラグ
    output logic [47:0] arp_mac_o,    // 解決したMACアドレス

    // ---- TX/RXデータFIFO (clk_50ドメイン) ------------------------------------
    input  wire [7:0]  tx_wr_data,
    input  wire        tx_wr_en,
    output logic       tx_wr_full,
    output logic [7:0]  rx_rd_data,
    input  wire        rx_rd_en,
    output logic       rx_rd_empty,
    output logic [11:0] rx_rd_count,

    // ---- MAC RX (バックプレッシャなし) ----------------------------------------
    input  wire [7:0]  mac_rx_tdata,
    input  wire        mac_rx_tvalid,
    input  wire        mac_rx_tlast,
    input  wire        mac_rx_tuser,

    // ---- MAC TX (バックプレッシャあり) ----------------------------------------
    output logic [7:0] mac_tx_tdata,
    output logic       mac_tx_tvalid,
    input  wire        mac_tx_tready,
    output logic       mac_tx_tlast,

    // ---- ステータス ------------------------------------------------------------
    output logic [3:0] tcp_state,
    output logic       irq
);

// ---- RXフレーム振り分け -------------------------------------------------------
logic [7:0] arp_rx_tdata,  tcp_rx_tdata;
logic       arp_rx_tvalid, tcp_rx_tvalid;
logic       arp_rx_tlast,  tcp_rx_tlast;
logic       arp_rx_tuser,  tcp_rx_tuser;

frame_mux u_mux (
    .clk        (clk),
    .rst_n      (rst_n),
    .rx_tdata   (mac_rx_tdata),
    .rx_tvalid  (mac_rx_tvalid),
    .rx_tlast   (mac_rx_tlast),
    .rx_tuser   (mac_rx_tuser),
    .arp_tdata  (arp_rx_tdata),  .arp_tvalid (arp_rx_tvalid),
    .arp_tlast  (arp_rx_tlast),  .arp_tuser  (arp_rx_tuser),
    .tcp_tdata  (tcp_rx_tdata),  .tcp_tvalid (tcp_rx_tvalid),
    .tcp_tlast  (tcp_rx_tlast),  .tcp_tuser  (tcp_rx_tuser)
);

// ---- ARPエンジン ---------------------------------------------------------------
logic [7:0] arp_tx_tdata;
logic       arp_tx_tvalid, arp_tx_tlast;

arp_engine #(
    .CLK_HZ (CLK_HZ)
) u_arp (
    .clk              (clk),
    .rst_n            (rst_n),
    .local_mac        (local_mac),
    .local_ip         (local_ip),
    .target_ip        (remote_ip),         // 解決したいIPアドレス
    .send_req         (arp_send_req),
    .target_mac_valid (arp_mac_valid),
    .target_mac_o     (arp_mac_o),
    .rx_tdata         (arp_rx_tdata),   .rx_tvalid  (arp_rx_tvalid),
    .rx_tlast         (arp_rx_tlast),   .rx_tuser   (arp_rx_tuser),
    .tx_tdata         (arp_tx_tdata),   .tx_tvalid  (arp_tx_tvalid),
    // ARP送信中(tvalid=1)のときだけtreadyを渡す → 送信完了後は0
    .tx_tready        (arp_tx_tvalid ? mac_tx_tready : 1'b0),
    .tx_tlast         (arp_tx_tlast)
);

// ---- ARP解決MAC → TCP宛先MAC切り替え -------------------------------------------
// ARP解決済み(arp_mac_valid=1)の場合はarp_mac_oを使用し、
// 未解決時はaxi4lite_regsから来るremote_mac（SW設定値）を使用する
logic [47:0] effective_remote_mac;
assign effective_remote_mac = arp_mac_valid ? arp_mac_o : remote_mac;

// ---- TCPレイヤー ---------------------------------------------------------------
logic [7:0] tcp_tx_tdata;
logic       tcp_tx_tvalid, tcp_tx_tlast;

tcp_layer #(
    .WIN_SIZE (WIN_SIZE),
    .CLK_HZ   (CLK_HZ)
) u_tcp (
    .clk            (clk),
    .rst_n          (rst_n),
    .local_mac      (local_mac),    .remote_mac     (effective_remote_mac),
    .local_ip       (local_ip),     .remote_ip      (remote_ip),
    .local_port     (local_port),   .remote_port    (remote_port),
    .addr_valid     (addr_valid),
    .connect_req    (connect_req),  .disconnect_req (disconnect_req),
    .tx_wr_data     (tx_wr_data),   .tx_wr_en       (tx_wr_en),
    .tx_wr_full     (tx_wr_full),
    .rx_rd_data     (rx_rd_data),   .rx_rd_en       (rx_rd_en),
    .rx_rd_empty    (rx_rd_empty),  .rx_rd_count    (rx_rd_count),
    .rx_tdata       (tcp_rx_tdata), .rx_tvalid      (tcp_rx_tvalid),
    .rx_tlast       (tcp_rx_tlast), .rx_tuser       (tcp_rx_tuser),
    .tx_tdata       (tcp_tx_tdata), .tx_tvalid      (tcp_tx_tvalid),
    // ARP非送信中のときだけTCPにtreadyを渡す
    .tx_tready      (arp_tx_tvalid ? 1'b0 : mac_tx_tready),
    .tx_tlast       (tcp_tx_tlast),
    .tcp_state      (tcp_state),
    .irq            (irq)
);

// ---- TXアービタ (ARPが最優先) -------------------------------------------------
// ARPのtvalid=1ならARP、そうでなければTCPのデータをMACへ送る
always_comb begin
    if (arp_tx_tvalid) begin
        mac_tx_tdata  = arp_tx_tdata;
        mac_tx_tvalid = arp_tx_tvalid;
        mac_tx_tlast  = arp_tx_tlast;
    end else begin
        mac_tx_tdata  = tcp_tx_tdata;
        mac_tx_tvalid = tcp_tx_tvalid;
        mac_tx_tlast  = tcp_tx_tlast;
    end
end

endmodule
`default_nettype wire
