`default_nettype none
// ===========================================================================
// rx_buffer.sv — TCP受信バッファ（4KB同期FIFO）
//
// 機能概要:
//   TCPで受信したペイロードデータを一時蓄積する4KBの同期FIFOバッファ。
//   xpm_fifo_sync（Xilinx Primitive: 同期FIFO）を使用する。
//   両ポート（書き込み・読み出し）ともclk_50ドメインで動作する。
//
// データフロー:
//   tcp_rx_hdr_dec（書き込み側）
//     → xpm_fifo_sync（4096バイト同期FIFO）
//     → axi4lite_regs（読み出し側: RX_DATAレジスタ0x2C経由でPSが読み出す）
//       ただし axi4lite_regs内のxpm_fifo_asyncで更にs_axi_aclkドメインへ橋渡し
//
// インタフェース:
//   書き込み側: tcp_rx_hdr_decのペイロードデコーダから直接書き込む
//   読み出し側: axi4lite_regsのRX非同期FIFOブリッジが読み出す
//   rd_count  : PSがRX_COUNTレジスタ（0x30番地）を読んでバイト数を把握するために使用
// ===========================================================================

module rx_buffer (
    input  wire        clk,    // システムクロック（clk_50ドメイン）
    input  wire        rst_n,  // 非同期リセット（負論理）

    // ---- 書き込み側 — tcp_rx_hdr_decからのペイロードデータ -------------------
    input  wire [7:0]  wr_data,   // 書き込みデータ（1バイト）
    input  wire        wr_en,     // 書き込みイネーブル
    output logic        wr_full,  // バッファ満杯フラグ（書き込み禁止を通知）

    // ---- 読み出し側 — axi4lite_regsのRX非同期FIFOブリッジへ ------------------
    output logic [7:0]  rd_data,    // 読み出しデータ（1バイト）
    input  wire        rd_en,      // 読み出しイネーブル
    output logic        rd_empty,  // バッファ空フラグ
    output logic [11:0] rd_count   // バッファ内の有効バイト数（0〜4095）
);

// xpm_fifo_sync: Xilinx同期FIFOプリミティブ
// - 4096バイト深さのブロックRAMFIFO
// - 標準読み出しモード（FWFTではない: 1クロック読み出し遅延あり）
// - RD_DATA_COUNT_WIDTH=12: 4096バイトを12ビットでカウント
xpm_fifo_sync #(
    .FIFO_MEMORY_TYPE ("block"),        // ブロックRAMを使用
    .FIFO_WRITE_DEPTH (4096),           // FIFO深さ: 4096バイト（4KB）
    .WRITE_DATA_WIDTH (8),              // 書き込みデータ幅: 8ビット
    .READ_DATA_WIDTH  (8),              // 読み出しデータ幅: 8ビット
    .READ_MODE        ("std"),          // 標準読み出しモード（1クロック遅延）
    .FIFO_READ_LATENCY(1),              // 読み出し遅延: 1クロック
    .RD_DATA_COUNT_WIDTH(12),           // 読み出しデータカウント幅: 12ビット
    .WR_DATA_COUNT_WIDTH(12),           // 書き込みデータカウント幅: 12ビット
    .USE_ADV_FEATURES ("0000"),         // 高度な機能は未使用
    .DOUT_RESET_VALUE ("0")             // リセット時のdout値: 0
) u_fifo (
    .wr_clk  (clk),      // 書き込みクロック（clk_50ドメイン）
    .rst     (~rst_n),   // 同期リセット（正論理: rst_nを反転）
    .din     (wr_data),  // 書き込みデータ
    .wr_en   (wr_en),    // 書き込みイネーブル
    .full    (wr_full),  // 満杯フラグ（書き込み側が参照）
    .dout    (rd_data),  // 読み出しデータ
    .rd_en   (rd_en),    // 読み出しイネーブル
    .empty   (rd_empty), // 空フラグ（読み出し側が参照）
    .rd_data_count (rd_count),  // 読み出し可能バイト数（12ビット）
    .wr_data_count (),          // 書き込みカウント（未使用）
    .prog_empty(),
    .prog_full(),
    .overflow(),
    .underflow(),
    .wr_rst_busy(),
    .rd_rst_busy(),
    .almost_empty(),
    .almost_full(),
    .sleep(1'b0),
    .injectdbiterr(1'b0),
    .injectsbiterr(1'b0),
    .sbiterr(),
    .dbiterr()
);

endmodule
`default_nettype wire
