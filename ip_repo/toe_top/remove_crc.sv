// =============================================================================
// モジュール名  : remove_crc
// 機能概要      : AXI-Streamフレームの末尾4バイト(CRC-32)を除去するモジュール
//                 受信フレームのCRC4バイトを4バイトFIFO(シフトレジスタ)で遅延させ、
//                 フレーム終端(tlast)検出時に末尾4バイトを破棄して出力する。
//                 除去したCRC値はcrc出力ポートに保持される。
//                 動作原理: 4バイトを先読みバッファに溜めてから出力開始し、
//                           後続バイトが来るたびにバッファをシフトしながら出力する。
//                           tlastが来たときはバッファの最上位バイトがCRC最終バイトなので
//                           そのまま破棄してフレーム終了を通知する。
// 改版履歴      : (なし)
// =============================================================================
`default_nettype none

module remove_crc (
    input wire clock,
    input wire aresetn,

    // --- スレーブ側 AXI-Stream インタフェース (CRC付きデータ入力) ---
    // tvalid: 上流からのデータ有効信号
    // tready: このモジュールがデータを受け付けられるときにアサート
    // tlast : フレームの最終バイト(CRCの最終バイト)を示す
    // tuser : ユーザー信号 (エラーフラグ等)
    input  wire [7:0] saxis_tdata,
    input  wire       saxis_tvalid,
    output reg       saxis_tready,
    input  wire       saxis_tlast,
    input  wire       saxis_tuser,

    // --- マスター側 AXI-Stream インタフェース (CRC除去後データ出力) ---
    // tlast : CRC除去後の最終データバイト出力時にアサート
    output reg   [7:0]  maxis_tdata,
    output reg          maxis_tvalid,
    input  wire         maxis_tready,
    output reg          maxis_tlast,
    output reg          maxis_tuser,

    // --- CRC値出力 ---
    // フレーム終端(tlast)検出時に除去した4バイトCRC値を出力
    output reg [31:0] crc
);

// =============================================================================
// 4バイト先読みバッファ
// buffer[7:0]  : バッファ内最も古いバイト (次に出力されるバイト)
// buffer[31:24]: バッファ内最も新しいバイト
// 新しいバイトはMSB側から入り、出力時はLSB側から取り出す
// =============================================================================
logic [31:0] buffer;

// =============================================================================
// FSM 状態定義
// S_RESET : リセット直後の初期化状態
// S_FILL_0: バッファ1バイト目を受信する状態 (buffer[7:0]を充填)
// S_FILL_1: バッファ2バイト目を受信する状態 (buffer[15:8]を充填)
// S_FILL_2: バッファ3バイト目を受信する状態 (buffer[23:16]を充填)
// S_FILL_3: バッファ4バイト目を受信する状態 (buffer[31:24]を充填)
//           4バイト溜まったらS_DATAへ移行 (ただし途中でtlastが来たら短フレームとして再スタート)
// S_DATA  : バッファのLSBを出力しながら新しいバイトをMSBに補充する状態
//           新しいバイトのtlastを見てmaxis_tlastを決定する
// =============================================================================
typedef enum {
    S_RESET,
    S_FILL_0,
    S_FILL_1,
    S_FILL_2,
    S_FILL_3,
    S_DATA
} state_t;

state_t state = S_RESET;

// =============================================================================
// saxis_tready 生成 (組み合わせ回路)
// S_FILL_0〜S_FILL_3: バッファを充填中は常に受信可能
// S_DATA: 出力側に転送できるときのみ受信可能
//         (!maxis_tvalid): 出力バッファが空
//         (maxis_tvalid && maxis_tready && !maxis_tlast): 転送成立かつ最終でない
// =============================================================================
always_comb begin
    case(state)
    S_FILL_0: saxis_tready = 1;    // バッファ充填中は常に受信可能
    S_FILL_1: saxis_tready = 1;
    S_FILL_2: saxis_tready = 1;
    S_FILL_3: saxis_tready = 1;
    S_DATA: begin
        // 出力バッファに空きがあるときのみ入力を受け付ける
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
        state <= S_RESET;
    end
    else begin
        case( state )
        S_RESET: begin
            // リセット解除後: バッファ充填開始状態へ移行
            state <= S_FILL_0;
            maxis_tvalid <= 0;
            maxis_tlast <= 0;
            crc <= 0;
        end
        S_FILL_0: begin
            // バッファの1バイト目 (buffer[7:0]) を充填
            if( saxis_tvalid ) begin
                buffer[7:0] <= saxis_tdata;
                if( saxis_tlast ) begin
                    // 短すぎるフレーム (1バイト): バッファをリセットして再スタート
                    state <= S_FILL_0;
                end
                else begin
                    state <= S_FILL_1;
                end
            end
        end
        S_FILL_1: begin
            // バッファの2バイト目 (buffer[15:8]) を充填
            if( saxis_tvalid ) begin
                buffer[15:8] <= saxis_tdata;
                if( saxis_tlast ) begin
                    // 短すぎるフレーム (2バイト): 再スタート
                    state <= S_FILL_0;
                end
                else begin
                    state <= S_FILL_2;
                end
            end
        end
        S_FILL_2: begin
            // バッファの3バイト目 (buffer[23:16]) を充填
            if( saxis_tvalid ) begin
                buffer[23:16] <= saxis_tdata;
                if( saxis_tlast ) begin
                    // 短すぎるフレーム (3バイト): 再スタート
                    state <= S_FILL_0;
                end
                else begin
                    state <= S_FILL_3;
                end
            end
        end
        S_FILL_3: begin
            // バッファの4バイト目 (buffer[31:24]) を充填
            // これでバッファが4バイト満タンになる
            if( saxis_tvalid ) begin
                buffer[31:24] <= saxis_tdata;
                if( saxis_tlast ) begin
                    // 短すぎるフレーム (4バイト以下=CRCのみ): 再スタート
                    state <= S_FILL_0;
                end
                else begin
                    // バッファが満タン: データ出力状態へ移行
                    state <= S_DATA;
                end
            end
        end
        S_DATA: begin
            // バッファのLSBバイト(buffer[7:0])を出力しながら
            // 新しいバイトをMSB側(buffer[31:24])に補充する
            if( maxis_tvalid && maxis_tready ) begin
                if( maxis_tlast ) begin
                    // 最終バイト転送完了: バッファ充填状態に戻る
                    maxis_tvalid <= 0;
                    maxis_tlast <= 0;
                    state <= S_FILL_0;
                end
                else if( saxis_tvalid && saxis_tready ) begin
                    // 出力転送成立 かつ 入力も有効: バッファをシフトしながら補充
                    maxis_tdata <= buffer[7:0];         // バッファ先頭バイトを出力
                    maxis_tvalid <= 1;
                    maxis_tlast <= saxis_tlast;         // 入力のtlastを引き継ぐ
                    maxis_tuser <= saxis_tuser;
                    buffer[23:0] <= buffer[31:8];       // バッファを1バイト右シフト
                    buffer[31:24] <= saxis_tdata;       // 新しいバイトをMSBに格納
                end
                else begin
                    // 出力転送成立したが入力が来ていない: 出力をいったん無効化
                    maxis_tvalid <= 0;
                end
            end
            else if( saxis_tvalid && saxis_tready ) begin
                // 出力が受け取れない間でも入力が来たらバッファシフト+出力準備
                maxis_tdata <= buffer[7:0];             // バッファ先頭バイトを出力準備
                maxis_tvalid <= 1;
                maxis_tlast <= saxis_tlast;
                maxis_tuser <= saxis_tuser;
                buffer[23:0] <= buffer[31:8];           // バッファを1バイト右シフト
                buffer[31:24] <= saxis_tdata;           // 新しいバイトをMSBに格納
            end

            // フレーム終端(tlast)検出時: バッファに残っている4バイトがCRC値
            // {saxis_tdata, buffer[31:8]} = [CRC_3, CRC_2, CRC_1, CRC_0] (リトルエンディアン)
            if( saxis_tvalid && saxis_tready && saxis_tlast ) begin
                crc <= {saxis_tdata, buffer[31:8]};
            end
        end
        endcase

    end
end

endmodule

`default_nettype wire
