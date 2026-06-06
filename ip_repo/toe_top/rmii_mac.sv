`default_nettype none
// RMIIマック ラッパー
//
// mii_mac_rx / mii_mac_tx をまとめてtoe_topが期待するインターフェースに変換する。
// USE_RMII=1 固定で使用 (MIIモードは不使用)。
//
// RX経路: rmii_rxd[1:0] + rmii_crs_dv → rmii_to_axis → 16バイトFIFO
//         → remove_crc (CRC4バイト除去) → crc_mac (CRC検証) → AXI-Stream出力
//
// TX経路: AXI-Stream入力 → append_crc (CRC付加) → prepend_preamble (プリアンブル付加)
//         → axis_to_rmii → rmii_txd[1:0] + rmii_tx_en

module rmii_mac #(
    parameter USE_RMII = 1  // 常に1 (互換性のため残している)
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- RMII RX (LAN8720→FPGA) -------------------------------------------
    input  wire [1:0]  rmii_rxd,      // 受信データ (2bit/clk, LSBファースト)
    input  wire        rmii_crs_dv,   // キャリアセンス/データバリッド

    // ---- RMII TX (FPGA→LAN8720) -------------------------------------------
    output wire [1:0]  rmii_txd,      // 送信データ (2bit/clk)
    output wire        rmii_tx_en,    // 送信イネーブル

    // ---- RX AXI-Stream出力 (TOEエンジンへ) -----------------------------------
    output wire [7:0]  rx_tdata,
    output wire        rx_tvalid,
    output wire        rx_tlast,
    output wire        rx_tuser,      // 1=CRCエラー

    // ---- TX AXI-Stream入力 (TOEエンジンから) ---------------------------------
    input  wire [7:0]  tx_tdata,
    input  wire        tx_tvalid,
    output wire        tx_tready,
    input  wire        tx_tlast
);

// TX: MIIの4bitバス出力 (RMIIでは下位2bitのみ使用)
wire [3:0] tx_mii_d;
wire       tx_mii_en;

// TX MACモジュール: ペイロードにCRC付加・プリアンブル付加してRMII出力
mii_mac_tx #(
    .USE_RMII (1)
) u_mac_tx (
    .clock                (clk),
    .aresetn              (rst_n),
    .mii_d                (tx_mii_d),
    .mii_en               (tx_mii_en),
    .mii_er               (),
    // 通常送信ストリーム (CRC+プリアンブル自動付加)
    .saxis_tdata          (tx_tdata),
    .saxis_tvalid         (tx_tvalid),
    .saxis_tready         (tx_tready),
    .saxis_tuser          (1'b0),
    .saxis_tlast          (tx_tlast),
    // バイパスストリーム (未使用: 0固定)
    .saxis_bypass_tdata   (8'h00),
    .saxis_bypass_tvalid  (1'b0),
    .saxis_bypass_tready  (),
    .saxis_bypass_tuser   (1'b0),
    .saxis_bypass_tlast   (1'b0)
);

// RMIIはMIIの2bit版: 下位2bitのみ使用
assign rmii_txd   = tx_mii_d[1:0];
assign rmii_tx_en = tx_mii_en;

// RX MACモジュール: RMII入力をAXI-StreamへCRC検証付きで変換
// rmii_rxd は {2'b00, rmii_rxd} として4bit MIIバスとして渡す
mii_mac_rx #(
    .USE_RMII (1)
) u_mac_rx (
    .clock        (clk),
    .aresetn      (rst_n),
    .mii_d        ({2'b00, rmii_rxd}), // 下位2bitのみ有効 (RMII)
    .mii_dv       (rmii_crs_dv),
    .mii_er       (1'b0),
    .maxis_tdata  (rx_tdata),
    .maxis_tvalid (rx_tvalid),
    .maxis_tuser  (rx_tuser),
    .maxis_tlast  (rx_tlast)
);

endmodule
`default_nettype wire
