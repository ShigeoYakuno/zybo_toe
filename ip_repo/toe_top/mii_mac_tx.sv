`default_nettype none

// ===========================================================================
// mii_mac_tx.sv — 送信MAC（TX MACトップモジュール）
//
// 機能概要:
//   AXI-Streamで入力されたEthernetペイロードにプリアンブル・FCSを付加し、
//   MII または RMII インタフェースへ出力する送信MACモジュール。
//
// データフロー（通常パス）:
//   saxis（ペイロード入力）
//     → append_crc  (FCS 4バイトをフレーム末尾に付加)
//     → prepend_preamble (プリアンブル7バイト + SFD 1バイトを先頭に付加)
//     → axis_mux    (バイパス入力との切替セレクタ)
//     → axis_to_mii (またはaxis_to_rmii)
//     → MII / RMII 出力
//
// バイパスパス:
//   saxis_bypass（プリアンブル・FCS付加済みフレーム）はaxis_muxで直接出力に接続。
//   プリアンブルおよびFCS処理を省略したい場合に使用する。
//
// パラメータ:
//   PREAMBLE_CHARACTER : プリアンブルバイト値（デフォルト 0x55）
//   SFD_CHARACTER      : SFD（フレーム開始デリミタ）値（デフォルト 0xD5）
//   USE_RMII           : 0=MIIモード, 1=RMIIモード
// ===========================================================================

module mii_mac_tx #(
    parameter PREAMBLE_CHARACTER = 8'h55,  // プリアンブルバイト値
    parameter SFD_CHARACTER = 8'hd5,       // SFD（Start Frame Delimiter）値
    parameter bit USE_RMII = 0             // 0=MII, 1=RMII
) (
    input wire clock,    // システムクロック
    input wire aresetn,  // 非同期リセット（負論理）

    // MII / RMII 送信出力
    output reg [3:0] mii_d,   // MII送信データ（RMIIでは[1:0]のみ使用）
    output reg       mii_en,  // 送信有効信号
    output reg       mii_er,  // 送信エラー信号（MIIのみ）

    // 通常送信入力（ペイロードのみ: append_crc/prepend_preambleで加工される）
    input  wire [7:0] saxis_tdata,
    input  wire       saxis_tvalid,
    output wire       saxis_tready,
    input  wire       saxis_tuser,
    input  wire       saxis_tlast,

    // バイパス入力（プリアンブル・FCS付加済みフレームを直接送信する場合に使用）
    input  wire [7:0] saxis_bypass_tdata,
    input  wire       saxis_bypass_tvalid,
    output wire       saxis_bypass_tready,
    input  wire       saxis_bypass_tuser,
    input  wire       saxis_bypass_tlast
);

// ---------------------------------------------------------------------------
// append_crc: 入力ペイロードの末尾にFCS（CRC32、4バイト）を付加する
// ---------------------------------------------------------------------------
logic [7:0] append_crc_out_tdata;
logic       append_crc_out_tvalid;
logic       append_crc_out_tready;
logic       append_crc_out_tuser;
logic       append_crc_out_tlast;

append_crc append_crc_inst (
    .clock(clock),
    .aresetn(aresetn),

    .saxis_tdata(saxis_tdata),
    .saxis_tvalid(saxis_tvalid),
    .saxis_tready(saxis_tready),
    .saxis_tuser(saxis_tuser),
    .saxis_tlast(saxis_tlast),

    .maxis_tdata(append_crc_out_tdata),
    .maxis_tvalid(append_crc_out_tvalid),
    .maxis_tready(append_crc_out_tready),
    .maxis_tuser(append_crc_out_tuser),
    .maxis_tlast(append_crc_out_tlast)
);

// ---------------------------------------------------------------------------
// prepend_preamble: フレーム先頭にプリアンブル（7バイト 0x55）と
//                   SFD（1バイト 0xD5）を付加する
// ---------------------------------------------------------------------------
logic [7:0] prepend_preamble_out_tdata;
logic       prepend_preamble_out_tvalid;
logic       prepend_preamble_out_tready;
logic       prepend_preamble_out_tuser = 0;  // プリアンブル部分はエラーなし
logic       prepend_preamble_out_tlast;

prepend_preamble #(
    .PREAMBLE(PREAMBLE_CHARACTER), .SFD(SFD_CHARACTER)
) prepend_preamble_inst (
    .clock(clock),
    .aresetn(aresetn),

    .saxis_tdata(append_crc_out_tdata),
    .saxis_tvalid(append_crc_out_tvalid),
    .saxis_tready(append_crc_out_tready),
    .saxis_tlast(append_crc_out_tlast),

    .maxis_tdata(prepend_preamble_out_tdata),
    .maxis_tvalid(prepend_preamble_out_tvalid),
    .maxis_tready(prepend_preamble_out_tready),
    .maxis_tlast(prepend_preamble_out_tlast)
);

// ---------------------------------------------------------------------------
// axis_mux: 通常パス（saxis_0）とバイパスパス（saxis_1）を切り替えるマルチプレクサ
//   saxis_0: プリアンブル+FCS付きの通常フレーム
//   saxis_1: バイパス入力（そのまま送信するフレーム）
// ---------------------------------------------------------------------------
logic [7:0] mux_out_tdata;
logic       mux_out_tvalid;
logic       mux_out_tready;
logic       mux_out_tuser;
logic       mux_out_tlast;

axis_mux axis_mux_inst (
    .clock(clock),
    .aresetn(aresetn),

    // ポート0: 通常パス（プリアンブル+FCS付き）
    .saxis_0_tdata(prepend_preamble_out_tdata),
    .saxis_0_tvalid(prepend_preamble_out_tvalid),
    .saxis_0_tready(prepend_preamble_out_tready),
    .saxis_0_tuser(prepend_preamble_out_tuser),
    .saxis_0_tlast(prepend_preamble_out_tlast),

    // ポート1: バイパスパス（加工なしでそのまま送信）
    .saxis_1_tdata(saxis_bypass_tdata),
    .saxis_1_tvalid(saxis_bypass_tvalid),
    .saxis_1_tready(saxis_bypass_tready),
    .saxis_1_tuser(saxis_bypass_tuser),
    .saxis_1_tlast(saxis_bypass_tlast),

    .maxis_tdata(mux_out_tdata),
    .maxis_tvalid(mux_out_tvalid),
    .maxis_tready(mux_out_tready),
    .maxis_tuser(mux_out_tuser),
    .maxis_tlast(mux_out_tlast)
);

// ---------------------------------------------------------------------------
// USE_RMIIパラメータによってRMII出力またはMII出力のどちらかを選択する
// ---------------------------------------------------------------------------
if( USE_RMII ) begin :use_rmii_block
    // RMIIモード: 1バイトを2ビットずつ順に出力する
    axis_to_rmii axis_to_rmii_inst (
        .clock(clock),
        .aresetn(aresetn),

        .saxis_tdata(mux_out_tdata),
        .saxis_tvalid(mux_out_tvalid),
        .saxis_tready(mux_out_tready),
        .saxis_tlast(mux_out_tlast),

        .rmii_d(mii_d[1:0]),  // RMII は下位2ビットを使用
        .rmii_en(mii_en)
    );
    assign mii_d[3:2] = 0;  // 未使用ビットをゼロに固定
    assign mii_er = 0;       // RMIIにはエラー信号なし
end
else begin :use_mii_block
    // MIIモード: 1バイトを4ビットニブルに分けて出力する
    axis_to_mii axis_to_mii_inst (
        .clock(clock),
        .aresetn(aresetn),

        .saxis_tdata(mux_out_tdata),
        .saxis_tvalid(mux_out_tvalid),
        .saxis_tready(mux_out_tready),
        .saxis_tlast(mux_out_tlast),

        .mii_d(mii_d),
        .mii_en(mii_en),
        .mii_er(mii_er)
    );
end

endmodule

`default_nettype wire
