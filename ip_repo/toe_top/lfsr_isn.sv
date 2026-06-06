`default_nettype none
// ===========================================================================
// lfsr_isn.sv — TCP初期シーケンス番号（ISN）生成器
//
// 機能概要:
//   32ビットフィボナッチLFSR（Linear Feedback Shift Register）を使って
//   TCP接続ごとに異なる初期シーケンス番号（ISN: Initial Sequence Number）を生成する。
//
// LFSR多項式:
//   x^32 + x^30 + x^26 + x^25 + 1  （ガロア形式）
//   フィードバックタップ: ビット31, 29, 25, 24（0ベース）
//   周期: 2^32 - 1（全ての非ゼロ値を生成、最大長系列）
//
// 実装の詳細:
//   - 左シフト型LFSRで、上位ビット（lfsr[31]）のXNOR演算でフィードバックビットを生成
//   - 全ゼロ状態（lock-up state）を検出して初期値にリセットする
//   - リセット信号なし: 電源投入後すぐにカウント開始
//
// ISN使用方法:
//   - tcp_state_ctrlがSYNパケット送信時にisnの現在値をラッチして使用する
//   - クロックごとにisnが変化するため、各接続で異なるISNが得られる
// ===========================================================================

module lfsr_isn (
    input  wire        clk,        // システムクロック（50MHz）
    output logic [31:0] isn        // 現在の初期シーケンス番号（常時更新）
);
    // LFSR状態レジスタ（初期値: 0xABCD_1234）
    logic [31:0] lfsr = 32'hABCD_1234;

    always_ff @(posedge clk) begin
        if (lfsr == '0)
            // 全ゼロ状態（lock-up state）からの脱出: 初期値にリセット
            lfsr <= 32'hABCD_1234;
        else
            // LFSRの次状態を計算（左シフト + フィードバックビット）
            // フィードバックビット = lfsr[31] ~^ lfsr[29] ~^ lfsr[25] ~^ lfsr[24]
            //   （XNOR: フィボナッチLFSRのタップ位置）
            //   タップは多項式 x^32 + x^30 + x^26 + x^25 + 1 に対応
            lfsr <= {lfsr[30:0], lfsr[31] ~^ lfsr[29] ~^ lfsr[25] ~^ lfsr[24]};
    end

    // 現在のLFSR値をISNとして直接出力（レジスタの組み合わせ出力）
    assign isn = lfsr;
endmodule
`default_nettype wire
