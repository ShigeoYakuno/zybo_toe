`default_nettype none

// ===========================================================================
// simple_fifo.v — 汎用同期FIFOモジュール（Verilog-2001）
//
// 機能概要:
//   AXI-Streamインタフェースを持つ汎用の同期FIFOバッファ。
//   レジスタ配列をメモリとして使用する小規模なFIFO実装。
//   深さは 2^DEPTH_BITS で指定する。
//
// AXI-Streamインタフェース:
//   スレーブ（入力）: saxis_tdata / saxis_tvalid / saxis_tready
//   マスタ（出力）: maxis_tdata / maxis_tvalid / maxis_tready
//
// ポインタ方式:
//   index_w: 次の書き込みインデックス（DEPTH_BITS+1ビット）
//   index_r: 次の読み出しインデックス（DEPTH_BITS+1ビット）
//   上位1ビットはラップアラウンド検出用（満杯/空の判定に使用）
//
// 満杯・空の判定:
//   空  : index_r == index_w（読み出しと書き込みが同じ位置）
//   満杯: index_r[DEPTH_BITS] != index_w[DEPTH_BITS] かつ
//          index_r[DEPTH_BITS-1:0] == index_w[DEPTH_BITS-1:0]
//   saxis_tready（書き込み可能）= 空 または 未満杯
//     = index_r[DEPTH_BITS] == index_w[DEPTH_BITS]  （ラップアラウンドなし）
//     || index_r[DEPTH_BITS-1:0] != index_w[DEPTH_BITS-1:0]（同一アドレスでない）
//
// パラメータ:
//   DATA_BITS  : データ幅（ビット数、デフォルト8）
//   DEPTH_BITS : 深さの対数（デフォルト3 → 深さ2^3=8エントリ）
//
// 使用例（mii_mac_rx.svでの使用）:
//   DEPTH_BITS=4 → 深さ16（Ethernet受信のバッファリング用）
// ===========================================================================

module simple_fifo #(
    parameter DATA_BITS = 8,   // データ幅（ビット）
    parameter DEPTH_BITS = 3   // FIFO深さの対数（深さ = 2^DEPTH_BITS）
) (
    input wire clock,    // システムクロック
    input wire aresetn,  // 非同期リセット（負論理）

    // スレーブ（入力）ポート
    input  wire [DATA_BITS-1:0] saxis_tdata,   // 書き込みデータ
    input  wire                 saxis_tvalid,  // 書き込みデータ有効
    output wire                 saxis_tready,  // 書き込み受け付け可能（1=書き込み可）

    // マスタ（出力）ポート
    output wire [DATA_BITS-1:0] maxis_tdata,   // 読み出しデータ（現在の読み出しポインタのデータ）
    output wire                 maxis_tvalid,  // 読み出しデータ有効（1=データあり）
    input  wire                 maxis_tready   // 読み出し受け付け（1=受け取り可能）
);

// ---------------------------------------------------------------------------
// ポインタレジスタ（DEPTH_BITS+1ビット幅、上位1ビットはラップアラウンド検出用）
// ---------------------------------------------------------------------------
reg [DEPTH_BITS:0] index_r;  // 読み出しポインタ
reg [DEPTH_BITS:0] index_w;  // 書き込みポインタ

// ---------------------------------------------------------------------------
// FIFOメモリ配列（レジスタ実装、深さ = 2^DEPTH_BITS）
// ---------------------------------------------------------------------------
reg [DATA_BITS-1:0] memory[2**DEPTH_BITS-1:0];

// ---------------------------------------------------------------------------
// saxis_tready（書き込み可能フラグ）の判定
// FIFOが空（index_r==index_wで上位ビット含め全一致）または
// 未満杯（上位ビットが同じ、もしくはアドレス部分が異なる）のとき書き込み可能
// ---------------------------------------------------------------------------
assign saxis_tready = index_r[DEPTH_BITS] == index_w[DEPTH_BITS]   // 上位ビットが同じ（ラップアラウンドなし）
                   || index_r[DEPTH_BITS-1:0] != index_w[DEPTH_BITS-1:0]; // アドレス部分が異なる（満杯でない）

// ---------------------------------------------------------------------------
// maxis_tvalid（読み出しデータ有効フラグ）の判定
// index_r != index_w であれば少なくとも1エントリ格納済み
// ---------------------------------------------------------------------------
assign maxis_tvalid = index_r != index_w;

// ---------------------------------------------------------------------------
// maxis_tdata: 現在の読み出しポインタが指すメモリの内容を出力
// （組み合わせ論理出力: FWFTと同様の動作）
// ---------------------------------------------------------------------------
assign maxis_tdata  = memory[index_r[DEPTH_BITS-1:0]];

// ---------------------------------------------------------------------------
// ポインタ更新とメモリ書き込み
// ---------------------------------------------------------------------------
always @(posedge clock) begin
    if( !aresetn ) begin
        // リセット: 両ポインタをゼロにリセット（FIFOを空にする）
        index_r <= 0;
        index_w <= 0;
    end
    else begin
        // 書き込み: saxis_tvalidかつsaxis_treadyのとき（ハンドシェイク成立）
        index_w <= saxis_tvalid && saxis_tready ? index_w + 1 : index_w;

        // 読み出し: maxis_tvalidかつmaxis_treadyのとき（ハンドシェイク成立）
        index_r <= maxis_tvalid && maxis_tready ? index_r + 1 : index_r;

        // メモリへの書き込み: ハンドシェイク成立時に現在のwrite_wアドレスにデータを格納
        if( saxis_tvalid && saxis_tready ) begin
            memory[index_w[DEPTH_BITS-1:0]] <= saxis_tdata;
        end
    end
end

endmodule

`default_nettype wire
