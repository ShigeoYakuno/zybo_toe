// =============================================================================
// モジュール名  : axis_mux
// 機能概要      : 2入力→1出力 AXI-Streamマルチプレクサ
//                 2つのスレーブ入力(saxis_0, saxis_1)を調停して
//                 1つのマスター出力(maxis)に接続する。
//                 調停ポリシー: 入力0(saxis_0)が優先。
//                   IDLE状態でsaxis_0が有効ならsaxis_0を選択。
//                   saxis_0が無効のときのみsaxis_1を選択。
//                 フレーム単位で切り替え: フレーム途中での切り替えは行わない。
//                 tlastを受信したらIDLEに戻り、次のフレームで再調停する。
// 改版履歴      : (なし)
// =============================================================================
`default_nettype none

module axis_mux (
    input wire clock,
    input wire aresetn,

    // --- マスター側 AXI-Stream インタフェース (多重化後の出力) ---
    // tvalid: 下流へのデータ有効信号
    // tready: 下流が受信可能なときにアサート (入力)
    // tuser : ユーザー信号 (エラーフラグ等)
    // tlast : フレームの最終バイトを示す
    output reg [7:0]  maxis_tdata,
    output reg        maxis_tvalid,
    input  wire       maxis_tready,
    output reg        maxis_tuser,
    output reg        maxis_tlast,

    // --- スレーブ入力0 (優先入力) ---
    // IDLEで先にtvalidが来た場合に優先選択される
    input  wire [7:0] saxis_0_tdata,
    input  wire       saxis_0_tvalid,
    output reg        saxis_0_tready,
    input  wire       saxis_0_tuser,
    input  wire       saxis_0_tlast,

    // --- スレーブ入力1 (低優先入力) ---
    // IDLEでsaxis_0が無効のときのみ選択される
    input  wire [7:0] saxis_1_tdata,
    input  wire       saxis_1_tvalid,
    output reg        saxis_1_tready,
    input  wire       saxis_1_tuser,
    input  wire       saxis_1_tlast
);

// =============================================================================
// FSM 状態定義
// IDLE   : どちらの入力も処理していない待機状態
//          saxis_0が優先: saxis_0_tvalidが来ればOUTPUT0へ
//          saxis_0が無効のときのみ saxis_1からOUTPUT1へ
// OUTPUT0: saxis_0のデータをmaxisへ転送中
//          saxis_0_tlastを検出したらIDLEへ戻る
// OUTPUT1: saxis_1のデータをmaxisへ転送中
//          saxis_1_tlastを検出したらIDLEへ戻る
// =============================================================================
typedef enum logic [1:0] {
    IDLE    = 2'b00,
    OUTPUT0 = 2'b01,
    OUTPUT1 = 2'b10
} state_t;

state_t state = IDLE;

// =============================================================================
// tready 生成 (組み合わせ回路)
// 選択された入力のtreadyは「出力バッファが空またはmaxis_treadyがアサート」のとき有効
// 非選択の入力はtreadyをDeassertして転送を停止する
// =============================================================================
// TREADY
always_comb begin
    case(state)
    IDLE: begin
        // IDLE中はどちらの入力も受け付けない
        saxis_0_tready = 0;
        saxis_1_tready = 0;
    end
    OUTPUT0: begin
        // saxis_0を出力中: saxis_0のみtreadyをアサート
        // 出力バッファが空(maxis_tvalidがLow)またはmaxis_treadyがアサートのとき受け付け可能
        saxis_0_tready = !maxis_tvalid || maxis_tready;
        saxis_1_tready = 0;    // saxis_1は転送停止
    end
    OUTPUT1: begin
        // saxis_1を出力中: saxis_1のみtreadyをアサート
        saxis_0_tready = 0;    // saxis_0は転送停止
        saxis_1_tready = !maxis_tvalid || maxis_tready;
    end
    endcase
end

// =============================================================================
// FSM メイン処理 (順序回路)
// =============================================================================
always_ff @(posedge clock) begin
    if( !aresetn ) begin
        state <= IDLE;
        maxis_tvalid <= 0;
    end
    else begin
        // 出力転送成立時: validをいったんLowに (次のデータで再アサート)
        if( maxis_tvalid && maxis_tready ) begin
            maxis_tvalid <= 0;
        end

        case(state)
        IDLE: begin
            // 調停: saxis_0が優先
            if( saxis_0_tvalid ) begin
                // saxis_0からフレームが来た → OUTPUT0へ
                state <= OUTPUT0;
            end
            else if( saxis_1_tvalid ) begin
                // saxis_0が無効でsaxis_1にデータがある → OUTPUT1へ
                state <= OUTPUT1;
            end
        end
        OUTPUT0: begin
            // saxis_0のデータをmaxisへ転送
            if(saxis_0_tvalid && saxis_0_tready) begin
                maxis_tvalid <= 1;
                maxis_tdata <= saxis_0_tdata;
                maxis_tuser <= saxis_0_tuser;
                maxis_tlast <= saxis_0_tlast;
                if( saxis_0_tlast ) begin
                    // フレーム終端: IDLEへ戻り次のフレームを再調停
                    state <= IDLE;
                end
            end
        end
        OUTPUT1: begin
            // saxis_1のデータをmaxisへ転送
            if(saxis_1_tvalid && saxis_1_tready) begin
                maxis_tvalid <= 1;
                maxis_tdata <= saxis_1_tdata;
                maxis_tuser <= saxis_1_tuser;
                maxis_tlast <= saxis_1_tlast;
                if( saxis_1_tlast ) begin
                    // フレーム終端: IDLEへ戻り次のフレームを再調停
                    state <= IDLE;
                end
            end
        end
        endcase
    end
end

endmodule

`default_nettype wire
