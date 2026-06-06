// =============================================================================
// モジュール名  : rmii_to_axis
// 機能概要      : RMII(2bit/クロック) → AXI-Stream(8bit)変換モジュール
//                 4クロックで2bitずつ受信し、8bitに組み立ててAXI-Streamに出力。
//                 SFD(Start Frame Delimiter = 0xD5)を検出したフレーム受信開始。
//                 フレーム終端はrmii_dvがLowになることで検出する。
//                 最終バイトの判定はdv信号の遅延を利用して1クロック遅れで行う。
// 改版履歴      : (なし)
// =============================================================================
`default_nettype none

module rmii_to_axis (
    input wire clock,
    input wire aresetn,

    // --- RMII 受信インタフェース ---
    // rmii_d : 受信データ (2bit/クロック, LSBファースト)
    // rmii_dv: データ有効信号 (キャリア検出中はHigh)
    input wire [1:0] rmii_d,
    input wire       rmii_dv,

    // --- マスター側 AXI-Stream インタフェース ---
    // tdata : 組み立てた8bitデータ
    // tvalid: データが有効であることを示す
    // tuser : エラーフラグ等のユーザー信号
    // tlast : フレームの最終バイトを示す
    // ※ このモジュールはtreadyを持たない (常に出力可能とみなす)
    output logic  [7:0]  maxis_tdata,
    output logic         maxis_tvalid,
    output logic         maxis_tuser,
    output logic         maxis_tlast
);

// SFD (Start Frame Delimiter): プリアンブル終端を示す特定バイト値
// 0xD5 = 1101_0101 (RMIIでは下位2bitから順に送信)
localparam SFD = 8'hd5;

// SFD検出フラグ: 4フェーズ分のrmii_dvが全High かつ d_4がSFD値のとき1
logic sfd_detected;

// フェーズカウンタ: 0〜3の4フェーズで1バイトを受信
// SFD検出時または3→0でリセット
logic [1:0] phase = 0;

// in_frame: フレーム受信中フラグ (SFD後にセット、dvがLowで解除)
// prev_in_frame: 前クロックのin_frame (フレーム終端検出用)
logic prev_in_frame = 0;
logic in_frame = 0;

// =============================================================================
// 入力バッファ (3クロック分の遅延バッファ)
// RMIIの受信データはフレーム終端検出のため遅延させて処理する
// dv_buf_3[2:0]: 過去3クロック分のrmii_dv (dv_buf_3[0]が1クロック前)
// d_buf_3[5:0] : 過去3クロック分のrmii_d  (d_buf_3[1:0]が1クロック前)
// =============================================================================
logic [2:0] dv_buf_3;   // DV input buffer for 3 cycles.
logic [5:0] d_buf_3;    // D  input buffer for 3 cycles.

logic  [7:0]  maxis_tdata_next = 0;    // 出力する8bitデータの中間ラッチ
logic         maxis_tvalid_next = 0;   // 出力validの1クロック前フラグ

// 入力データを毎クロックシフトして遅延バッファに格納
always_ff @(posedge clock) begin
    if( !aresetn ) begin
        dv_buf_3 <= 0;
        d_buf_3 <= 0;
    end
    else begin
        // 新しい値をMSBに格納し、古い値をLSBへシフト
        dv_buf_3 <= {rmii_dv, dv_buf_3[2:1]};
        d_buf_3  <= {rmii_d,  d_buf_3[5:2]};
    end
end

// =============================================================================
// 現在クロックと過去3クロック分のデータを結合
// dv_4[3]: 現在のrmii_dv, dv_4[0]: 3クロック前のrmii_dv
// d_4[7:6]: 現在のrmii_d,  d_4[1:0]: 3クロック前のrmii_d
// =============================================================================
logic [3:0] dv_4;   // current and prev 3 cycles DV signal.
logic [7:0] d_4;    // current and prev 3 cycles DV signal.

always_comb begin
    dv_4 = {rmii_dv, dv_buf_3};
    d_4 =  {rmii_d,  d_buf_3};
end

// =============================================================================
// SFD検出ロジック
// 4クロック分のdvがすべてHigh (dv_4 == 4'b1111) かつ
// 4クロック分のdatが SFD(0xD5) を構成しており、
// かつフレーム受信中でない (!in_frame) 場合にSFDを検出
// =============================================================================
assign sfd_detected = dv_4 == 4'b1111 && d_4 == SFD && !in_frame;

// =============================================================================
// フェーズカウンタ・フレーム状態更新
// =============================================================================
always_ff @(posedge clock) begin
    if( !aresetn ) begin
        phase <= 0;
        in_frame <= 0;
        prev_in_frame <= 0;
    end
    else begin
        prev_in_frame <= in_frame;  // 前クロックのin_frameを保存

        // フェーズカウンタ: SFD検出時はリセット、そうでなければ0〜3を循環
        phase <= (sfd_detected || phase == 2'd3) ? 0 : phase + 1;

        // フレーム状態更新:
        //   SFD検出→受信開始 (in_frame=1)
        //   dv_4の上位2bitがともに0→フレーム終了 (in_frame=0)
        in_frame <=   sfd_detected ? 1
                    : dv_4[3:2] == 2'b00 ? 0
                    : in_frame;
    end
end

// =============================================================================
// AXI-Stream 出力生成
// バイトデータはphase==3のときにd_4の8bitをラッチし、
// 次のphase==3のタイミングで実際のAXI-Stream出力へ転送する。
// (1クロック遅延することでフレーム終端 = tlastの判定が可能になる)
// =============================================================================
always_ff @(posedge clock) begin
    if( !aresetn ) begin
        maxis_tdata <= 0;
        maxis_tvalid <= 0;
        maxis_tlast <= 0;
        maxis_tuser <= 0;
        maxis_tdata_next <= 0;
        maxis_tvalid_next <= 0;
    end
    else begin
        maxis_tvalid <= 0;  // デフォルトでvalidはLow (後段で上書き)

        // phase==3: 4クロック分のデータが揃ったのでd_4の8bitをラッチ
        // dv_4[2]とdv_4[0]でバッファ内3クロック前から現在まで有効かチェック
        if( dv_4[2] && dv_4[0] && in_frame && phase == 2'd3 ) begin
            maxis_tdata_next <= d_4; // Hold data (8bitデータを中間ラッチへ保存)
        end
        // phase==0: バイト境界に到達し、かつフレーム内なら出力validフラグをセット
        if( prev_in_frame && in_frame && phase == 2'd0 ) begin
            maxis_tvalid_next <= 1;
        end
        // 出力タイミング: maxis_tvalid_nextがセットされており phase==3の時
        // 1クロック後にフレーム状態を確認してtlastを決定できる
        if( maxis_tvalid_next && phase == 2'd3 ) begin
            maxis_tdata <= maxis_tdata_next;    // 8bitデータを出力へ
            maxis_tvalid <= maxis_tvalid_next;  // valid をアサート
            maxis_tlast <= !in_frame;           // フレーム受信中でなければ最終バイト
            maxis_tvalid_next <= 0;             // フラグをクリア
        end
    end
end


endmodule

`default_nettype wire
