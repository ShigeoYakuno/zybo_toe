// =============================================================================
// モジュール名  : prepend_preamble
// 機能概要      : AXI-Streamデータの前にイーサネットプリアンブルとSFDを付加するモジュール
//                 送信フレームの先頭に以下のバイト列を挿入する:
//                   プリアンブル: 0x55 × PREAMBLE_LENGTH (デフォルト7バイト)
//                   SFD         : 0xD5 × 1バイト
//                 その後、入力AXI-Streamのデータをそのまま出力する。
// パラメータ    :
//   PREAMBLE       : プリアンブルバイト値 (デフォルト 0x55)
//   SFD            : Start Frame Delimiter バイト値 (デフォルト 0xD5)
//   PREAMBLE_LENGTH: プリアンブルのバイト数 (デフォルト 7)
// 改版履歴      : (なし)
// =============================================================================
`default_nettype none

module prepend_preamble #(
    parameter bit [7:0] PREAMBLE = 8'h55,       // プリアンブルバイト値 (0x55固定)
    parameter bit [7:0] SFD = 8'hd5,            // Start Frame Delimiter (0xD5固定)
    parameter int PREAMBLE_LENGTH = 7            // プリアンブルの繰り返し回数
) (
    input wire clock,
    input wire aresetn,

    // --- スレーブ側 AXI-Stream インタフェース (ペイロードデータ入力) ---
    // tvalid: 上流からのデータ有効信号
    // tready: このモジュールがデータを受け付けられるときにアサート
    // tlast : フレームの最終バイトを示す
    input  wire  [7:0]  saxis_tdata,
    input  wire         saxis_tvalid,
    output reg          saxis_tready,
    input  wire         saxis_tlast,

    // --- マスター側 AXI-Stream インタフェース (プリアンブル+データ出力) ---
    // tvalid: 下流へのデータ有効信号
    // tready: 下流がデータを受け付けられるときにアサート
    // tlast : フレームの最終バイトを示す
    output reg   [7:0]  maxis_tdata,
    output reg          maxis_tvalid,
    input  wire         maxis_tready,
    output reg          maxis_tlast
);

// preamble_count: 残りプリアンブルバイト数を管理するカウンタ
// PREAMBLE_LENGTH分のビット幅を$clog2で最小化
logic [$clog2(PREAMBLE_LENGTH)-1:0] preamble_count = 0;

// =============================================================================
// FSM 状態定義
// S_RESET   : リセット直後の初期化状態
// S_IDLE    : 上流からのデータ待ち状態
// S_PREAMBLE: プリアンブル (0x55) を PREAMBLE_LENGTH バイト送信する状態
//             maxis_treadyがアサートされるたびにpreamble_countをデクリメント
//             countが0になったらS_SFDへ移行
// S_SFD     : SFD (0xD5) を1バイト送信する状態
//             送信完了後、入力データの先頭バイトをラッチしてS_DATAへ
// S_DATA    : ペイロードデータを順次転送する状態
//             tlastを検出したらS_IDLEへ戻る
// =============================================================================
typedef enum  {
    S_RESET,
    S_IDLE,
    S_PREAMBLE,
    S_SFD,
    S_DATA
} state_t;


state_t state = S_RESET;

// =============================================================================
// saxis_tready 生成 (組み合わせ回路)
// S_SFD : SFDを下流に転送しながら入力の先頭バイトを受け取る
// S_DATA: 出力バッファに空きがあれば入力を受け付ける
//         (!maxis_tvalid): 出力バッファが空の場合
//         (maxis_tvalid && maxis_tready && !maxis_tlast): 転送成立かつ最終でない
// =============================================================================
always_comb begin
    case(state)
    S_SFD: begin
        saxis_tready = maxis_tready;   // SFD送信中は入力の先頭バイトを受け付け
    end
    S_DATA: begin
        // 出力側が受け取れる(またはバッファが空)ときのみ入力を受け付ける
        saxis_tready = !maxis_tvalid || maxis_tvalid && maxis_tready && !maxis_tlast;
    end
    default: saxis_tready = 0;
    endcase
end

// =============================================================================
// FSM メイン処理 (順序回路)
// =============================================================================
always_ff @(posedge clock) begin
    if( !aresetn ) begin
        maxis_tdata <= 0;
        maxis_tvalid <= 0;
        maxis_tlast <= 0;
    end
    else begin
        case(state)
        S_RESET: begin
            // リセット解除後すぐにIDLE状態へ移行
            state <= S_IDLE;
            maxis_tlast <= 0;
        end
        S_IDLE: begin
            // 上流からデータが来たらプリアンブル送信を開始
            if( saxis_tvalid ) begin
                preamble_count <= PREAMBLE_LENGTH - 1;  // カウンタをプリアンブル長-1にセット
                maxis_tdata <= PREAMBLE;                // プリアンブルバイト (0x55) を出力にセット
                maxis_tvalid <= 1;
                maxis_tlast <= 0;
                state <= S_PREAMBLE;
            end
        end
        S_PREAMBLE: begin
            // 下流がデータを受け取るたびにカウンタをデクリメント
            if( maxis_tready ) begin
                preamble_count <= preamble_count - 1;
                if( preamble_count == 0 )  begin
                    // プリアンブル送信完了: 次はSFD (0xD5) を送信
                    maxis_tdata <= SFD;
                    state <= S_SFD;
                end
                // preamble_count > 0の間はmaxis_tdataは変化させない (常に0x55を出力)
            end
        end
        S_SFD: begin
            // SFD送信完了: 入力データの先頭バイトをラッチしてデータ転送へ
            if( maxis_tready ) begin
                maxis_tdata <= saxis_tdata;     // 入力の最初のデータバイトをラッチ
                maxis_tlast <= saxis_tlast;     // tlastフラグも引き継ぐ
                state <= S_DATA;
            end
        end
        S_DATA: begin
            // 出力転送成立 (tvalid && tready) のクロックで次のデータを取り込む
            if( maxis_tvalid && maxis_tready ) begin
                if( maxis_tlast ) begin
                    // 最終バイトを転送完了: IDLEへ戻る
                    maxis_tvalid <= 0;
                    state <= S_IDLE;
                end
                else begin
                    // 続きのデータを入力から取り込む
                    maxis_tvalid <= saxis_tvalid;
                    maxis_tdata <= saxis_tdata;
                    maxis_tlast <= saxis_tlast;
                end
            end
            else if( saxis_tvalid && saxis_tready ) begin
                // 出力が受け取れない間にも入力データを受け取ってバッファする
                maxis_tvalid <= saxis_tvalid;
                maxis_tdata <= saxis_tdata;
                maxis_tlast <= saxis_tlast;
            end
        end
        endcase
    end
end

endmodule

`default_nettype wire
