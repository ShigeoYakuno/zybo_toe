// =============================================================================
// モジュール名  : append_crc
// 機能概要      : AXI-Streamデータの末尾にCRC-32(4バイト)を付加するモジュール
//                 内部でcrc_macを使ってフレームデータのCRCを計算し、
//                 フレーム末尾(tlast)の後にCRC値をリトルエンディアンで
//                 4バイト (CRC_0〜CRC_3) 追加して出力する。
//                 CRC計算: IEEE 802.3準拠 (初期値 0xFFFFFFFF, 最終反転)
// 改版履歴      : (なし)
// =============================================================================
`default_nettype none

module append_crc (
    input wire clock,
    input wire aresetn,

    // --- スレーブ側 AXI-Stream インタフェース (CRC計算前データ入力) ---
    // tvalid: 上流からのデータ有効信号
    // tready: このモジュールがデータを受け付けられるときにアサート
    // tlast : フレームの最終バイト (このタイミングでCRCが確定)
    // tuser : ユーザー信号 (エラーフラグ等)
    input  wire [7:0]  saxis_tdata,
    input  wire        saxis_tvalid,
    output wire        saxis_tready,
    input  wire        saxis_tlast,
    input  wire        saxis_tuser,

    // --- マスター側 AXI-Stream インタフェース (データ+CRC出力) ---
    // tlast : CRCの最終バイト(4バイト目)出力時のみアサートされる
    output wire [7:0]  maxis_tdata,
    output wire        maxis_tvalid,
    input  wire        maxis_tready,
    output wire        maxis_tlast,
    output wire        maxis_tuser
);

// crc_out: crc_macが計算したCRC-32値 (32bit)
// リトルエンディアンで crc_out[7:0] が最初に送出される
logic [31:0] crc_out;

// =============================================================================
// CRC計算コア (crc_mac) のインスタンス
// 入力AXI-Streamをパススルーしながら並列にCRC計算を行う
// input_tdata/tvalid等はcrc_macの出力側信号 (内部接続用)
// =============================================================================
crc_mac crc_mac_inst(
    .clock(clock),
    .aresetn(aresetn),

    // スレーブ側: 外部からの入力をそのまま接続
    .saxis_tdata (saxis_tdata),
    .saxis_tvalid(saxis_tvalid),
    .saxis_tready(saxis_tready),    // saxis_treadyはcrc_macが生成
    .saxis_tlast (saxis_tlast),
    .saxis_tuser (saxis_tuser),

    // マスター側: crc_macのパススルー出力を内部バスに接続
    .maxis_tdata (input_tdata),
    .maxis_tvalid(input_tvalid),
    .maxis_tready(input_tready),
    .maxis_tlast (input_tlast),
    .maxis_tuser (input_tuser),

    .crc_out(crc_out)               // 計算されたCRC-32値
);

// crc_macのパススルー出力を受け取る内部信号
logic [7:0] input_tdata;
logic input_tvalid;
logic input_tready;
logic input_tlast;
logic input_tuser;

// 出力バッファ信号 (FSMからmaxis_*への経路)
logic [7:0] output_tdata;
logic       output_tvalid;
logic       output_tready;
logic       output_tlast;
logic       output_tuser;

// =============================================================================
// FSM 状態定義
// S_RESET: リセット直後の初期化状態
// S_IDLE : 入力データ待ち状態
// S_DATA : ペイロードデータを転送中
//          tlastを検出したらCRC送信状態へ移行
// S_CRC_0: CRCバイト0 (crc_out[7:0])  を送信
// S_CRC_1: CRCバイト1 (crc_out[15:8]) を送信
// S_CRC_2: CRCバイト2 (crc_out[23:16])を送信
// S_CRC_3: CRCバイト3 (crc_out[31:24])を送信 (このバイトでmaxis_tlastをアサート)
// =============================================================================
typedef enum {
    S_RESET,
    S_IDLE,
    S_DATA,
    S_CRC_0,
    S_CRC_1,
    S_CRC_2,
    S_CRC_3
} state_t;

state_t state = S_RESET;

// 出力接続
assign maxis_tdata  = output_tdata;
assign maxis_tvalid = output_tvalid;
assign output_tready = maxis_tready;
// tlastはS_CRC_3かつoutput_tlast(内部の最終フラグ)のときのみアサート
assign maxis_tlast  = output_tlast && state == S_CRC_3;
assign maxis_tuser  = output_tuser;

// =============================================================================
// input_tready 生成 (組み合わせ回路)
// S_IDLE: バッファが空なので常に受け付け可能
// S_DATA: 出力側に転送できるときのみ受け付け可能
//         (!output_tvalid): 出力バッファが空
//         (output_tvalid && output_tready && !output_tlast): 出力転送成立かつ最終でない
// =============================================================================
always_comb begin
    case(state)
    S_IDLE: begin
        input_tready = 1;          // IDLEは常に受信可能
    end
    S_DATA: begin
        // 出力バッファに空きがあるときのみ入力を受け付ける
        input_tready = !output_tvalid || output_tvalid && output_tready && !output_tlast;
    end
    default: input_tready = 0;     // CRC送信中は入力受け付け停止
    endcase
end

// =============================================================================
// FSM メイン処理 (順序回路)
// =============================================================================
always_ff @(posedge clock) begin
    if( !aresetn ) begin
        state <= S_RESET;
        output_tvalid <= 0;
        output_tdata <= 0;
        output_tuser <= 0;
        output_tlast <= 0;
    end
    else begin
        case( state )
        S_RESET: begin
            // リセット解除後すぐにIDLE状態へ移行
            state <= S_IDLE;
            output_tvalid <= 0;
            output_tdata <= 0;
            output_tuser <= 0;
            output_tlast <= 0;
        end
        S_IDLE: begin
            // 入力データが来たら出力バッファにラッチしてデータ転送状態へ
            if( input_tvalid ) begin
                output_tvalid <= 1;
                output_tdata <= input_tdata;
                output_tlast <= input_tlast;
                output_tuser <= input_tuser;
                state <= S_DATA;
            end
        end
        S_DATA: begin
            // 出力転送成立 (tvalid && tready) のクロックで次のデータを取り込む
            if( output_tvalid && output_tready ) begin
                if( output_tlast ) begin
                    // 最終データバイトを転送完了: CRC送信を開始
                    // CRCはリトルエンディアンで crc_out[7:0] から送出
                    output_tdata <= crc_out[7:0];   // CRCバイト0をバッファにセット
                    state <= S_CRC_0;
                end
                else begin
                    // 続きのデータを入力から取り込む
                    output_tvalid <= input_tvalid;
                    output_tdata <= input_tdata;
                    output_tuser <= input_tuser;
                    output_tlast <= input_tlast;
                end
            end
            else if( input_tvalid && input_tready ) begin
                // 出力が受け取れない間に入力データをバッファ
                output_tvalid <= input_tvalid;
                output_tdata <= input_tdata;
                output_tuser <= input_tuser;
                output_tlast <= input_tlast;
            end
        end
        S_CRC_0: begin
            // CRCバイト0 (crc_out[7:0]) 送信中
            // 下流が受け取ったらCRCバイト1をバッファにセット
            if( output_tready ) begin
                output_tdata <= crc_out[15:8];      // CRCバイト1をセット
                state <= S_CRC_1;
            end
        end
        S_CRC_1: begin
            // CRCバイト1 (crc_out[15:8]) 送信中
            if( output_tready ) begin
                output_tdata <= crc_out[23:16];     // CRCバイト2をセット
                state <= S_CRC_2;
            end
        end
        S_CRC_2: begin
            // CRCバイト2 (crc_out[23:16]) 送信中
            if( output_tready ) begin
                output_tdata <= crc_out[31:24];     // CRCバイト3をセット
                state <= S_CRC_3;
            end
        end
        S_CRC_3: begin
            // CRCバイト3 (crc_out[31:24]) 送信中
            // このバイトでmaxis_tlastがアサートされる (output_tlast && S_CRC_3)
            if( output_tready ) begin
                // CRC送信完了: バッファをクリアしてIDLEへ戻る
                output_tdata <= 0;
                output_tvalid <= 0;
                output_tlast <= 0;
                state <= S_IDLE;
            end
        end
        endcase
    end
end

endmodule

`default_nettype wire
