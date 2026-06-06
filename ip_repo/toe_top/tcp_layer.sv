`default_nettype none
// ===========================================================================
// tcp_layer.sv — TCP層トップモジュール
//
// 機能概要:
//   TCP/IP通信に必要なサブモジュールを接続するトップレベルモジュール。
//   以下のサブモジュールをインスタンス化して相互接続する:
//     - lfsr_isn        : 初期シーケンス番号（ISN）生成
//     - rx_buffer       : 受信データFIFOバッファ（4KB）
//     - tx_buffer       : 送信データ循環バッファ（8KB、再送対応）
//     - tcp_rx_hdr_dec  : 受信フレームのEth/IP/TCPヘッダ解析
//     - tcp_state_ctrl  : TCP状態機械（FSM）、接続管理・タイムアウト制御
//     - tcp_hdr_gen     : 送信フレームのEth/IP/TCPヘッダ生成（チェックサム計算）
//
// RXパス:
//   frame_mux（IPv4/TCPフレームのみ）
//     → tcp_rx_hdr_dec（ヘッダ解析・チェックサム検証）
//     → rx_buffer（ペイロード格納）
//     → axi4lite_regs（PSへのデータ転送）
//
// TXパス:
//   axi4lite_regs（PSからのデータ）
//     → tx_buffer（送信データ蓄積）
//     → tcp_hdr_gen（ヘッダ生成・チェックサム計算）
//     → TXアービタ（AXI-Stream出力）
//
// パラメータ:
//   WIN_SIZE : アドバタイズする受信ウィンドウサイズ（デフォルト 4096バイト）
//   CLK_HZ   : 動作クロック周波数（タイムアウト計算用, デフォルト 50MHz）
// ===========================================================================

module tcp_layer #(
    parameter WIN_SIZE = 16'd4096,    // アドバタイズする受信ウィンドウサイズ（バイト）
    parameter CLK_HZ   = 50_000_000  // 動作クロック周波数（Hz）
)(
    input  wire        clk,    // システムクロック（50MHz）
    input  wire        rst_n,  // 非同期リセット（負論理）

    // ---- axi4lite_regsからのアドレス設定 ------------------------------------
    input  wire [47:0] local_mac,    // ローカルMACアドレス
    input  wire [47:0] remote_mac,  // リモートMACアドレス
    input  wire [31:0] local_ip,    // ローカルIPアドレス
    input  wire [31:0] remote_ip,   // リモートIPアドレス
    input  wire [15:0] local_port,  // ローカルTCPポート番号
    input  wire [15:0] remote_port, // リモートTCPポート番号
    input  wire        addr_valid,  // 全アドレスレジスタが設定済みフラグ

    // ---- ARM PSからの接続制御（clkドメイン同期済み） -------------------------
    input  wire        connect_req,    // 接続開始要求（立ち上がりエッジ有効）
    input  wire        disconnect_req, // 切断要求（立ち上がりエッジ有効）

    // ---- ARM PSからのTXデータ（axi4lite_regs非同期FIFO経由） ----------------
    input  wire [7:0]  tx_wr_data,  // TXデータ（1バイト）
    input  wire        tx_wr_en,    // TXデータ書き込みイネーブル
    output logic        tx_wr_full, // TXバッファ満杯フラグ（ARM側にフロー制御）

    // ---- ARM PSへのRXデータ（axi4lite_regs非同期FIFOブリッジ経由） ----------
    output logic [7:0]  rx_rd_data,   // RXデータ（1バイト）
    input  wire        rx_rd_en,     // RXデータ読み出しイネーブル
    output logic        rx_rd_empty, // RXバッファ空フラグ
    output logic [11:0] rx_rd_count, // RXバッファ内の有効バイト数

    // ---- frame_muxからのRXバイトストリーム（バックプレッシャーなし） ----------
    input  wire [7:0]  rx_tdata,   // 受信データ（1バイト）
    input  wire        rx_tvalid,  // 受信データ有効
    input  wire        rx_tlast,   // フレーム末尾
    input  wire        rx_tuser,   // エラーフラグ（1 = CRC不一致）

    // ---- TXアービタへのAXI-Stream出力 ----------------------------------------
    output logic [7:0]  tx_tdata,   // 送信データ（1バイト）
    output logic        tx_tvalid,  // 送信データ有効
    input  wire        tx_tready,  // 送信レディ（バックプレッシャー）
    output logic        tx_tlast,   // フレーム末尾

    // ---- axi4lite_regsへのステータス出力 -----------------------------------------
    output logic [3:0]  tcp_state,  // TCP状態（0=CLOSED〜7=LAST_ACK）
    output logic        irq         // 状態変化割り込み（1サイクルパルス）
);

// ---------------------------------------------------------------------------
// ISN生成: LFSRを使って初期シーケンス番号を連続的に生成する
// SYN送信時にtcp_state_ctrlが現在のISN値をサンプリングする
// ---------------------------------------------------------------------------
logic [31:0] isn;  // 現在の初期シーケンス番号
lfsr_isn u_lfsr (
    .clk (clk),
    .isn (isn)
);

// ---------------------------------------------------------------------------
// RXバッファ: tcp_rx_hdr_decが書き込んだペイロードを一時蓄積する4KB FIFO
// axi4lite_regsを経由してPS（ARM）が読み出す
// ---------------------------------------------------------------------------
logic [7:0]  rxbuf_wr_data;  // 書き込みデータ（tcp_rx_hdr_decから）
logic        rxbuf_wr_en;    // 書き込みイネーブル
logic        rxbuf_wr_full;  // バッファ満杯（書き込み不可）
logic [7:0]  rxbuf_rd_data;  // 読み出しデータ（axi4lite_regsへ）
logic        rxbuf_rd_en;    // 読み出しイネーブル
logic        rxbuf_rd_empty; // バッファ空フラグ
logic [11:0] rxbuf_rd_count; // バッファ内の有効バイト数

rx_buffer u_rx_buf (
    .clk      (clk),
    .rst_n    (rst_n),
    .wr_data  (rxbuf_wr_data),
    .wr_en    (rxbuf_wr_en),
    .wr_full  (rxbuf_wr_full),
    .rd_data  (rxbuf_rd_data),
    .rd_en    (rxbuf_rd_en),
    .rd_empty (rxbuf_rd_empty),
    .rd_count (rxbuf_rd_count)
);

// RXバッファ読み出し側をaxi4lite_regsのインタフェースへ接続
assign rx_rd_data   = rxbuf_rd_data;
assign rx_rd_empty  = rxbuf_rd_empty;
assign rx_rd_count  = rxbuf_rd_count;
assign rxbuf_rd_en  = rx_rd_en;

// ---------------------------------------------------------------------------
// TXバッファ: PS（ARM）が書き込んだ送信データを蓄積する8KB循環バッファ
// tcp_hdr_genがセグメント単位で読み出し、再送時はsend_ptrをリセットする
// ---------------------------------------------------------------------------
logic        txbuf_send_req;    // セグメント送信開始要求
logic [10:0] txbuf_send_len;    // 送信セグメントのペイロード長（バイト）
logic        txbuf_busy;        // 送信ビジーフラグ（ストリーミング中）
logic [7:0]  txbuf_rd_data;     // 読み出しデータ（tcp_hdr_genへ）
logic        txbuf_rd_valid;    // 読み出しデータ有効
logic        txbuf_rd_last;     // セグメント末尾フラグ
logic        txbuf_ack_advance; // ACKポインタ進め要求
logic [10:0] txbuf_ack_delta;   // ACKされたバイト数
logic        txbuf_retrans;     // 再送要求（send_ptrをack_ptrに戻す）

tx_buffer u_tx_buf (
    .clk         (clk),
    .rst_n       (rst_n),
    .wr_data     (tx_wr_data),
    .wr_en       (tx_wr_en),
    .wr_full     (tx_wr_full),
    .send_req    (txbuf_send_req),
    .send_len    (txbuf_send_len),
    .send_busy   (txbuf_busy),
    .rd_data     (txbuf_rd_data),
    .rd_valid    (txbuf_rd_valid),
    .rd_last     (txbuf_rd_last),
    .ack_advance (txbuf_ack_advance),
    .ack_delta   (txbuf_ack_delta),
    .retrans_req (txbuf_retrans)
);

// ---------------------------------------------------------------------------
// RXヘッダデコーダ: 受信フレームのEth/IP/TCPヘッダを解析する
// チェックサム（IP/TCP）の検証、アドレス・ポートの照合を行い、
// 有効パケットのみpkt_validをアサートしてtcp_state_ctrlに通知する
// ---------------------------------------------------------------------------
logic        pkt_valid;       // 有効なTCPパケットを受信した（1サイクルパルス）
logic        rx_syn, rx_ack, rx_fin, rx_rst;  // TCP制御フラグ
logic [31:0] rx_seq_num, rx_ack_num;           // シーケンス番号・ACK番号
logic [15:0] rx_win_size, rx_payload_len;      // ウィンドウサイズ・ペイロード長

tcp_rx_hdr_dec u_rx_dec (
    .clk            (clk),
    .rst_n          (rst_n),
    .rx_tdata       (rx_tdata),
    .rx_tvalid      (rx_tvalid),
    .rx_tlast       (rx_tlast),
    .rx_tuser       (rx_tuser),
    .local_mac      (local_mac),
    .remote_mac     (remote_mac),
    .local_ip       (local_ip),
    .remote_ip      (remote_ip),
    .local_port     (local_port),
    .remote_port    (remote_port),
    .addr_valid     (addr_valid),
    .pkt_valid      (pkt_valid),
    .rx_syn         (rx_syn),
    .rx_ack         (rx_ack),
    .rx_fin         (rx_fin),
    .rx_rst         (rx_rst),
    .rx_seq_num     (rx_seq_num),
    .rx_ack_num     (rx_ack_num),
    .rx_win_size    (rx_win_size),
    .rx_payload_len (rx_payload_len),
    .pl_data        (rxbuf_wr_data),  // ペイロードをrx_bufferに書き込む
    .pl_wr_en       (rxbuf_wr_en),
    .pl_full        (rxbuf_wr_full)
);

// ---------------------------------------------------------------------------
// TCP状態制御: RFC793に基づくTCP状態機械（FSM）
// Active Open（能動的接続開始）のみサポート。
// タイムアウト・再送制御、ACKポインタ管理も担当する
// ---------------------------------------------------------------------------
logic        tx_send_req;    // ヘッダジェネレータへの送信要求（1サイクルパルス）
logic [8:0]  tx_flags;       // TCP制御フラグ（SYN/ACK/FIN等）
logic [31:0] tx_seq_num, tx_ack_num;  // 送信シーケンス番号・ACK番号
logic [10:0] tx_payload_len; // ペイロード長（制御パケットは0）
logic        tx_payload_en;  // ペイロードをtx_bufferから取得するフラグ
logic        tx_busy;        // 送信ビジーフラグ（tcp_hdr_genが動作中）

tcp_state_ctrl #(
    .CLK_HZ        (CLK_HZ)
) u_state (
    .clk            (clk),
    .rst_n          (rst_n),
    .connect_req    (connect_req),
    .disconnect_req (disconnect_req),
    .pkt_valid      (pkt_valid),
    .rx_syn         (rx_syn),
    .rx_ack         (rx_ack),
    .rx_fin         (rx_fin),
    .rx_rst         (rx_rst),
    .rx_seq_num     (rx_seq_num),
    .rx_ack_num     (rx_ack_num),
    .rx_win_size    (rx_win_size),
    .rx_payload_len (rx_payload_len),
    .isn            (isn),           // LFSRからのISN（SYN送信時にラッチ）
    .tx_send_req    (tx_send_req),
    .tx_flags       (tx_flags),
    .tx_seq_num     (tx_seq_num),
    .tx_ack_num     (tx_ack_num),
    .tx_payload_len (tx_payload_len),
    .tx_payload_en  (tx_payload_en),
    .tx_busy        (tx_busy),
    .retrans_req    (txbuf_retrans),     // 再送要求 → tx_bufferへ
    .ack_advance    (txbuf_ack_advance), // ACKポインタ進め → tx_bufferへ
    .ack_delta      (txbuf_ack_delta),   // ACKされたバイト数 → tx_bufferへ
    .tcp_state      (tcp_state),
    .irq            (irq)
);

// ---------------------------------------------------------------------------
// TXヘッダジェネレータ: Ethernet+IP+TCPヘッダを生成して送信する
// データパケット: 2パスでチェックサム計算（Pass1: ペイロード集計, Pass2: 送信）
// 制御パケット: 組み合わせ論理でチェックサム計算（1パス）
// ---------------------------------------------------------------------------
logic        gen_busy;  // ヘッダジェネレータビジーフラグ

tcp_hdr_gen #(
    .WIN_SIZE (WIN_SIZE)
) u_hdr_gen (
    .clk          (clk),
    .rst_n        (rst_n),
    .send_req     (tx_send_req),    // tcp_state_ctrlからの送信要求
    .flags        (tx_flags),
    .seq_num      (tx_seq_num),
    .ack_num      (tx_ack_num),
    .payload_len  (tx_payload_len),
    .payload_en   (tx_payload_en),
    .gen_busy     (gen_busy),       // 生成中はアサート
    .local_mac    (local_mac),
    .remote_mac   (remote_mac),
    .local_ip     (local_ip),
    .remote_ip    (remote_ip),
    .local_port   (local_port),
    .remote_port  (remote_port),
    .buf_send_req (txbuf_send_req), // tx_bufferへのセグメント読み出し要求
    .buf_send_len (txbuf_send_len),
    .buf_busy     (txbuf_busy),
    .buf_rd_data  (txbuf_rd_data),
    .buf_rd_valid (txbuf_rd_valid),
    .buf_rd_last  (txbuf_rd_last),
    .tx_tdata     (tx_tdata),       // AXI-Stream出力（TXアービタへ）
    .tx_tvalid    (tx_tvalid),
    .tx_tready    (tx_tready),
    .tx_tlast     (tx_tlast)
);

// ★修正: tx_busyはtcp_state_ctrlのoutput portが駆動するため assignを削除
// (assign tx_busy = gen_busy は多重ドライバを引き起こしVivado合成を破壊していた)

endmodule
`default_nettype wire
