// =============================================================================
// モジュール名  : axis_to_rmii
// 機能概要      : AXI-Stream(8bit) → RMII(2bit×4フェーズ)変換モジュール
//                 1バイトを4クロックかけて2bitずつ送信する。
//                 送信完了後はインターフレームギャップ(IFG)を挿入してから
//                 次のフレーム受け付けへ戻る。
//                 RMII(Reduced Media Independent Interface): 100Mbps Ethernet用
//                 50MHzクロックで2bit/クロック = 100Mbps
// 改版履歴      : (なし)
// =============================================================================
`default_nettype none

module axis_to_rmii (
    input wire clock,
    input wire aresetn,

    // --- RMII 送信インタフェース ---
    // rmii_d : 送信データ (2bit, LSBファースト)
    // rmii_en: 送信イネーブル (フレーム送信中はHigh)
    output logic [3:0] rmii_d,
    output logic       rmii_en,

    // --- スレーブ側 AXI-Stream インタフェース ---
    // tvalid: 上流からのデータ有効信号
    // tready: このモジュールが受信可能であることを示す
    // tlast : フレームの最終バイトを示す
    input wire  [7:0]  saxis_tdata,
    input wire         saxis_tvalid,
    output logic       saxis_tready,
    input wire         saxis_tlast
);

// tdata/tlast を内部に取り込むためのラッチレジスタ
// PHASE_0〜PHASE_3の4フェーズ中にバイトデータを保持する
logic [7:0] tdata;
logic       tlast;

// =============================================================================
// FSM 状態定義
// S_RESET     : リセット直後の初期化状態
// S_IDLE      : 上流からのデータ待ち状態 (saxis_tready=1)
// S_PHASE_0   : バイトのbit[1:0]を送信するフェーズ (1クロック目)
// S_PHASE_1   : バイトのbit[3:2]を送信するフェーズ (2クロック目)
// S_PHASE_2   : バイトのbit[5:4]を送信するフェーズ (3クロック目)
// S_PHASE_3   : バイトのbit[7:6]を送信するフェーズ (4クロック目)
//               最終バイトでなければ次バイトを先読みして連続送信
// S_INTERFRAME: フレーム終了後のインターフレームギャップ挿入状態
//               interframeレジスタが全0になるまでrmii_enをLowに保つ
// =============================================================================
typedef enum  {
    S_RESET,
    S_IDLE,
    S_PHASE_0,
    S_PHASE_1,
    S_PHASE_2,
    S_PHASE_3,
    S_INTERFRAME
} state_t;

state_t state = S_RESET;

// =============================================================================
// saxis_tready 生成 (組み合わせ回路)
// S_IDLE   : 次のバイトを受信する準備ができている
// S_PHASE_3: 最終バイトでなければ次バイトを受け付ける (パイプライン受信)
// その他   : 送信中につきデータ受け付け不可
// =============================================================================
always_comb begin
    case(state)
    S_IDLE: saxis_tready = 1;
    S_PHASE_3: saxis_tready = !tlast;   // 最終バイトでなければ次バイト受信可
    default: saxis_tready = 0;
    endcase
end

// =============================================================================
// インターフレームギャップカウンタ
// 24bitシフトレジスタで実現。LSBに1をセットし、左シフトしながらゼロになるまで待つ。
// 24クロック分のギャップを挿入する (50MHzで約480ns、IEEE 802.3最低IFG=96bit=960ns)
// =============================================================================
logic [23:0] interframe = 0;

// =============================================================================
// FSM メイン処理 (順序回路)
// =============================================================================
always_ff @(posedge clock) begin
    if( !aresetn ) begin
        state <= S_RESET;
        tlast <= 0;
        rmii_d <= 0;
        rmii_en <= 0;
    end
    else begin
        case(state)
        S_RESET: begin
            // リセット解除後すぐにIDLE状態へ移行
            state <= S_IDLE;
            tlast <= 0;
        end
        S_IDLE: begin
            // 上流からデータが来たら1バイトをラッチして送信開始
            if( saxis_tvalid ) begin
                tdata <= saxis_tdata;   // バイトデータをラッチ
                tlast <= saxis_tlast;   // 最終バイトフラグをラッチ
                state <= S_PHASE_0;
            end
        end
        S_PHASE_0: begin
            // bit[1:0]を送信 (RMIIの第1フェーズ)
            rmii_d <= tdata[1:0];
            rmii_en <= 1;               // 送信イネーブルをアサート
            state <= S_PHASE_1;
        end
        S_PHASE_1: begin
            // bit[3:2]を送信 (RMIIの第2フェーズ)
            rmii_d <= tdata[3:2];
            rmii_en <= 1;
            state <= S_PHASE_2;
        end
        S_PHASE_2: begin
            // bit[5:4]を送信 (RMIIの第3フェーズ)
            rmii_d <= tdata[5:4];
            rmii_en <= 1;
            state <= S_PHASE_3;
        end
        S_PHASE_3: begin
            // bit[7:6]を送信 (RMIIの第4フェーズ = 最終フェーズ)
            rmii_d <= tdata[7:6];
            rmii_en <= 1;
            if( !tlast && saxis_tvalid ) begin
                // 連続送信: 最終バイトでなく次バイトが有効なら先読みしてPHASE_0へ
                tdata <= saxis_tdata;
                tlast <= saxis_tlast;
                state <= S_PHASE_0;
            end
            else begin
                // 最終バイト送信完了: インターフレームギャップへ
                state <= S_INTERFRAME;
                interframe <= 1;        // シフトレジスタの初期値 (1→左シフト→0になるまで待つ)
            end
        end
        S_INTERFRAME: begin
            // インターフレームギャップ期間: rmii_enをLowに保ち、次フレームまで待機
            rmii_en <= 0;
            tlast <= 0;
            interframe <= interframe << 1;  // 毎クロック左シフト
            if( |interframe == 0 ) begin
                // interframeが全0になったらIDLE状態へ戻る
                state <= S_IDLE;
            end
        end
        endcase
    end
end

endmodule

`default_nettype wire
