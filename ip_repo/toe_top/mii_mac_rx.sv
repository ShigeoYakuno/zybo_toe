`default_nettype none

// ===========================================================================
// mii_mac_rx.sv — 受信MAC（RX MACトップモジュール）
//
// 機能概要:
//   MII または RMII インタフェースから受信したEthernetフレームを
//   AXI-Streamに変換する受信MACモジュール。
//
// データフロー:
//   mii_to_axis (またはrmii_to_axis)
//     → simple_fifo (16段バッファ)
//     → remove_crc  (末尾4バイトのFCSを除去しFCS値を出力)
//     → crc_mac     (ペイロードのCRCを再計算)
//     → AXI-Stream出力
//
// CRC検証:
//   受信フレーム末尾のFCS(fcs)と再計算したCRC(crc)を比較し、
//   不一致の場合はtuser=1を出力してエラーを通知する。
//
// パラメータ:
//   USE_RMII : 0=MIIモード, 1=RMIIモード
// ===========================================================================

module mii_mac_rx #(
    parameter USE_RMII = 0
)(
    input wire clock,    // システムクロック
    input wire aresetn,  // 非同期リセット（負論理）

    // MII / RMII 受信インタフェース
    input wire [3:0] mii_d,   // MII受信データ（RMIIでは[1:0]のみ使用）
    input wire       mii_dv,  // データ有効信号
    input wire       mii_er,  // 受信エラー信号（MIIのみ）

    // AXI-Stream マスタ出力
    output wire [7:0] maxis_tdata,   // 受信データ（1バイト）
    output wire       maxis_tvalid,  // データ有効
    output wire       maxis_tuser,   // エラーフラグ（1=CRC不一致またはフレームエラー）
    output wire       maxis_tlast    // フレーム末尾
);

// ---------------------------------------------------------------------------
// MII/RMII → AXI-Stream 変換後の中間信号
// ---------------------------------------------------------------------------
logic [7:0] mii_to_axis_out_tdata;
logic       mii_to_axis_out_tvalid;
logic       mii_to_axis_out_tready;
logic       mii_to_axis_out_tuser;
logic       mii_to_axis_out_tlast;

// USE_RMIIパラメータによってRMII変換またはMII変換のどちらかを選択する
if( USE_RMII ) begin :use_rmii_block
    // RMIIモード: 2ビットデータを1バイトに組み立てる
    rmii_to_axis rmii_to_axis_inst (
        .clock(clock),
        .aresetn(aresetn),

        .rmii_d(mii_d[1:0]),   // RMII は下位2ビットのみ使用
        .rmii_dv(mii_dv),

        .maxis_tdata (mii_to_axis_out_tdata),
        .maxis_tvalid(mii_to_axis_out_tvalid),
        .maxis_tuser (mii_to_axis_out_tuser),
        .maxis_tlast (mii_to_axis_out_tlast)
    );
end
else begin :use_mii_block
    // MIIモード: 4ビットニブルを1バイトに組み立てる
    mii_to_axis mii_to_axis_inst (
        .clock(clock),
        .aresetn(aresetn),

        .mii_d(mii_d),
        .mii_dv(mii_dv),
        .mii_er(mii_er),

        .maxis_tdata (mii_to_axis_out_tdata),
        .maxis_tvalid(mii_to_axis_out_tvalid),
        .maxis_tuser (mii_to_axis_out_tuser),
        .maxis_tlast (mii_to_axis_out_tlast)
    );
end

// ---------------------------------------------------------------------------
// 中間バッファ用のFIFOデータ型定義
// tdata, tuser, tlast をひとつの構造体としてFIFOに格納する
// ---------------------------------------------------------------------------
typedef struct packed {
    bit [7:0] tdata;  // データバイト
    bit        tuser; // エラーフラグ
    bit        tlast; // フレーム末尾フラグ
} fifo_data_t;

fifo_data_t fifo_in_tdata;
logic       fifo_in_tvalid;
logic       fifo_in_tready;

fifo_data_t fifo_out_tdata;
logic       fifo_out_tvalid;
logic       fifo_out_tready;

// simple_fifo: 深さ16のバッファ（DEPTH_BITS=4 → 2^4=16段）
// MII/RMIIから来るデータを一時蓄積してrate調整する
simple_fifo #(.DATA_BITS($bits(fifo_data_t)), .DEPTH_BITS(4)) fifo_inst (
    .saxis_tdata (fifo_in_tdata ),
    .saxis_tvalid(fifo_in_tvalid),
    .saxis_tready(),
    .maxis_tdata (fifo_out_tdata ),
    .maxis_tvalid(fifo_out_tvalid),
    .maxis_tready(fifo_out_tready),
    .*
);

// FIFOへの入力: MII/RMII変換後のデータをパック
assign fifo_in_tdata = '{tdata: mii_to_axis_out_tdata, tuser: mii_to_axis_out_tuser, tlast: mii_to_axis_out_tlast};
assign fifo_in_tvalid = mii_to_axis_out_tvalid;

// ---------------------------------------------------------------------------
// remove_crc: フレーム末尾4バイトのFCS（Frame Check Sequence）を除去
// 除去したFCS値はfcsとして出力し、後段のCRC検証に使用する
// ---------------------------------------------------------------------------
logic [31:0] fcs;  // フレームに付加されていたFCS値
logic [7:0] remove_crc_out_tdata;
logic       remove_crc_out_tvalid;
logic       remove_crc_out_tready;
logic       remove_crc_out_tuser;
logic       remove_crc_out_tlast;

remove_crc remove_crc_inst (
    .clock(clock),
    .aresetn(aresetn),

    .saxis_tdata (fifo_out_tdata.tdata),
    .saxis_tvalid(fifo_out_tvalid),
    .saxis_tready(fifo_out_tready),
    .saxis_tuser (fifo_out_tdata.tuser),
    .saxis_tlast (fifo_out_tdata.tlast),

    .maxis_tdata (remove_crc_out_tdata),
    .maxis_tvalid(remove_crc_out_tvalid),
    .maxis_tready(remove_crc_out_tready),
    .maxis_tuser (remove_crc_out_tuser),
    .maxis_tlast (remove_crc_out_tlast),

    .crc(fcs)  // 受信フレームから取り出したFCS（4バイト）
);


// ---------------------------------------------------------------------------
// crc_mac: ペイロードデータに対してCRC32を計算する
// 計算結果はcrcとして出力し、受信FCS(fcs)と比較する
// ---------------------------------------------------------------------------
logic [31:0] crc;  // 受信データから再計算したCRC値
logic [7:0] crc_mac_out_tdata;
logic       crc_mac_out_tvalid;
logic       crc_mac_out_tready;
logic       crc_mac_out_tuser;
logic       crc_mac_out_tlast;

crc_mac crc_mac_inst(
    .clock(clock),
    .aresetn(aresetn),

    .saxis_tdata (remove_crc_out_tdata),
    .saxis_tvalid(remove_crc_out_tvalid),
    .saxis_tready(remove_crc_out_tready),
    .saxis_tuser (remove_crc_out_tuser),
    .saxis_tlast (remove_crc_out_tlast),

    .maxis_tdata (crc_mac_out_tdata),
    .maxis_tvalid(crc_mac_out_tvalid),
    .maxis_tready(crc_mac_out_tready),
    .maxis_tuser (crc_mac_out_tuser),
    .maxis_tlast (crc_mac_out_tlast),

    .crc_out(crc)  // 計算したCRC32値
);

// ---------------------------------------------------------------------------
// CRC検証ロジック
// フレーム末尾(tlast)タイミングで再計算CRC(crc)と受信FCS(fcs)を比較する
// フレーム転送中は前のフレームの結果を保持する
// ---------------------------------------------------------------------------
logic is_crc_valid_reg;
logic is_crc_valid;
// tlastサイクルではcrc==fcsを直接比較、それ以外ではレジスタ値を保持
assign is_crc_valid = crc_mac_out_tvalid && crc_mac_out_tready && crc_mac_out_tlast ? crc == fcs : is_crc_valid_reg;

always @(posedge clock) begin
    if( !aresetn ) begin
        is_crc_valid_reg <= 0;
    end
    else begin
        // 転送が進んでいないときは保持、tlastでCRC比較結果を記録、それ以外は0にリセット
        is_crc_valid_reg <= !(crc_mac_out_tvalid && crc_mac_out_tready) ? is_crc_valid_reg
                          : crc_mac_out_tlast ? crc == fcs
                          : 0;
    end
end

// ---------------------------------------------------------------------------
// AXI-Stream 出力
// tuser = 1 の場合はCRC不一致またはフレームエラー（上位層に通知）
// tready は常時1（バックプレッシャーなし）
// ---------------------------------------------------------------------------
assign maxis_tdata  = crc_mac_out_tdata;
assign maxis_tvalid = crc_mac_out_tvalid;
assign crc_mac_out_tready = 1;  // 常時アクセプト
// tuserはtlast時のみCRC結果を示す。非lastバイトは常に0（エラーなし）
// ★バグ修正: 旧実装はis_crc_validがフレーム中0になるため全バイトtuser=1になっていた
assign maxis_tuser  = crc_mac_out_tlast
                    ? !(is_crc_valid && !crc_mac_out_tuser)
                    : 1'b0;
assign maxis_tlast  = crc_mac_out_tlast;

endmodule

`default_nettype wire
