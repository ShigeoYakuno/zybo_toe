// =============================================================================
// モジュール名  : crc_mac
// 機能概要      : イーサネットCRC-32計算コア
//                 AXI-Streamで入力された8bitデータを1クロックで処理し、
//                 CRC-32を逐次計算する。入力データはパススルーで出力される。
//                 CRC規格: IEEE 802.3準拠 (反射多項式 0xEDB88320, LSBファースト)
//                 初期値: 0xFFFFFFFF、最終出力は反転(XOR 0xFFFFFFFF)
// 改版履歴      : (なし)
// =============================================================================
`default_nettype none

module crc_mac (
    input wire clock,
    input wire aresetn,

    // --- スレーブ側 AXI-Stream インタフェース ---
    // tvalid: データが有効であることを示す (マスターがアサート)
    // tready: 受信準備完了を示す (スレーブがアサート)
    // tlast : フレームの最終バイトを示す
    // tuser : ユーザー定義信号 (エラーフラグ等)
    input  wire [7:0] saxis_tdata,
    input  wire       saxis_tvalid,
    output wire       saxis_tready,
    input  wire       saxis_tlast,
    input  wire       saxis_tuser,

    // --- マスター側 AXI-Stream インタフェース (パススルー) ---
    output wire [7:0] maxis_tdata,
    output wire       maxis_tvalid,
    input  wire       maxis_tready,
    output wire       maxis_tlast,
    output wire       maxis_tuser,

    // --- CRC計算結果 ---
    // tlastと同クロックで確定した最終CRC値を出力する
    output wire  [31:0] crc_out
);

// =============================================================================
// パススルー接続
// このモジュールはデータを遅延なく素通しさせながらCRCを計算する
// =============================================================================
assign maxis_tdata = saxis_tdata;
assign maxis_tvalid = saxis_tvalid;
assign saxis_tready = maxis_tready;
assign maxis_tlast = saxis_tlast;
assign maxis_tuser = saxis_tuser;

// =============================================================================
// CRC-32 反射多項式
// IEEE 802.3イーサネットで使用される0xEDB88320 (0x04C11DB7の反射)
// =============================================================================
localparam [31:0] POLYNOMIAL = 32'b1110_1101_1011_1000_1000_0011_0010_0000;

// remainder: CRC除算の余りレジスタ (初期値 0xFFFFFFFF)
reg  [31:0] remainder;

// rem_stage[0..8]: 8ビット分の逐次XOR演算ステージ (組み合わせ回路)
// 各ステージで1ビットずつLSBシフト+多項式XORを行う
wire [31:0] rem_stage[8:0];

// ステージ0: 入力バイトを現在のremainderの下位8bitにXOR
assign rem_stage[0] = {remainder[31:8], remainder[7:0] ^ saxis_tdata};

// ステージ1〜8: 1ビットずつ右シフトし、LSBが1なら多項式とXOR
// これはCRC-32のビット単位計算を8回展開したもの
generate
for(genvar i = 0; i < 8; i = i + 1) begin
    assign rem_stage[i+1] = {1'b0, rem_stage[i][31:1] ^ (rem_stage[i][0] ? POLYNOMIAL : 32'b0)};
end
endgenerate

// 8ビット処理後の新しいCRC値
wire [31:0] remainder_next;
assign remainder_next = rem_stage[8];

// =============================================================================
// CRC出力
// tlastかつtransfer成立時: 最終バイト処理後のCRCを反転して出力 (~remainder_next)
// それ以外の時: 前クロックのCRC出力を保持
// =============================================================================
reg [31:0] crc_out_reg;
assign crc_out = saxis_tvalid && saxis_tready && saxis_tlast ? ~remainder_next : crc_out_reg;

// =============================================================================
// CRC レジスタ更新
// tvalid && tready (転送成立) のクロックでremainder_nextを取り込む
// tlastの場合は次フレームのためにremainderを初期値 0xFFFFFFFF にリセット
// =============================================================================
always @(posedge clock) begin
    if( !aresetn ) begin
        remainder <= {32 {1'b1}};   // リセット時: CRC初期値 0xFFFFFFFF をセット
        crc_out_reg   <= 0;
    end
    else begin
        // 転送成立時のみremainderを更新; tlast後は次フレームのためにリセット
        remainder <= saxis_tvalid && saxis_tready ? (saxis_tlast ? {32 {1'b1}} : remainder_next) : remainder;
        crc_out_reg <= crc_out;     // CRC出力値をレジスタに保持
    end
end

endmodule

`default_nettype wire
