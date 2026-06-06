`default_nettype none
// 改版履歴:
//   rev1 2026-05-31  rx_tlastを常時ARP/TCPパスに転送 (rx_idxデシンク防止)
//
// RXフレームデマルチプレクサ
//
// MACから受け取ったフレームをEtherTypeで振り分ける:
//   0x0806 (ARP)  → arp_engine へ
//   0x0800 (IPv4) → tcp_layer  へ
//   その他        → 破棄
//
// 重要な設計上の注意:
//   バイト12-13のEtherTypeはALWAYS両パスへ転送する (b_cnt <= 13)。
//   さらにフレーム末尾(rx_tlast)も常時転送する。これにより、非ARPフレームが
//   到着してもarp_engineのrx_idxが正しくリセットされる。
//   (Windows PCはIPv6 NDやmDNSを自動送信するため、このリセットが必須)

module frame_mux (
    input  wire        clk,
    input  wire        rst_n,

    // ---- MACからの入力 (バックプレッシャなし) ---------------------------------
    input  wire [7:0]  rx_tdata,
    input  wire        rx_tvalid,
    input  wire        rx_tlast,
    input  wire        rx_tuser,   // 1=CRCエラー

    // ---- arp_engineへの出力 --------------------------------------------------
    output logic [7:0] arp_tdata,
    output logic       arp_tvalid,
    output logic       arp_tlast,
    output logic       arp_tuser,

    // ---- tcp_layer (tcp_rx_hdr_dec)への出力 ----------------------------------
    output logic [7:0] tcp_tdata,
    output logic       tcp_tvalid,
    output logic       tcp_tlast,
    output logic       tcp_tuser
);

// EtherType検出 (バイト12-13)
logic [7:0]  eth_type_hi = '0; // バイト12 (EtherType上位)
logic [7:0]  byte_cnt_low;     // 未使用 (旧変数、残留)
logic [7:0]  b_cnt = '0;       // フレーム内バイトカウンタ
logic [15:0] etype;            // 組み立てたEtherType

// ルーティング先
typedef enum logic [1:0] {
    ROUTE_NONE, // 破棄
    ROUTE_ARP,  // ARPエンジンへ
    ROUTE_TCP   // TCPレイヤーへ
} route_t;

route_t route = ROUTE_NONE;

// バイトカウントとルート判定 (クロック同期)
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        b_cnt       <= '0;
        route       <= ROUTE_NONE;
        eth_type_hi <= '0;
    end else begin
        if (rx_tvalid) begin
            case (b_cnt)
                8'd12: eth_type_hi <= rx_tdata; // EtherType上位バイトを保存
                8'd13: begin
                    // EtherType確定 → ルート決定
                    etype = {eth_type_hi, rx_tdata};
                    if      (etype == 16'h0806) route <= ROUTE_ARP;  // ARP
                    else if (etype == 16'h0800) route <= ROUTE_TCP;  // IPv4
                    else                        route <= ROUTE_NONE; // 破棄
                end
                default: ;
            endcase

            if (rx_tlast) begin
                // フレーム終端: カウンタとルートをリセット
                b_cnt <= '0;
                route <= ROUTE_NONE;
            end else if (b_cnt < 8'd255)
                b_cnt <= b_cnt + 1'b1;
        end
    end
end

// ファンアウト (組み合わせ回路)
always_comb begin
    // ---- ARPパス ----
    arp_tdata  = rx_tdata;
    arp_tlast  = rx_tlast;
    arp_tuser  = rx_tuser;
    // 有効条件:
    //   ① ARPフレームのペイロード (route==ROUTE_ARP)
    //   ② Etherヘッダ (b_cnt<=13, 全フレーム共通でARPエンジンに渡す)
    //   ③ フレーム末尾 (rx_tlast, 常時転送してrx_idxをリセットさせる)
    arp_tvalid = rx_tvalid && (route == ROUTE_ARP || b_cnt <= 8'd13 || rx_tlast);

    // ---- TCPパス ----
    tcp_tdata  = rx_tdata;
    tcp_tlast  = rx_tlast;
    tcp_tuser  = rx_tuser;
    tcp_tvalid = rx_tvalid && (route == ROUTE_TCP || b_cnt <= 8'd13 || rx_tlast);
end

endmodule
`default_nettype wire
