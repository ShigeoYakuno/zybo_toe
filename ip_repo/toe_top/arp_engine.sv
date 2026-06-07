`default_nettype none
// 改版履歴:
//   rev6 2026-06-07  send_req をエッジ検出に変更:
//                    send_req がレベルセンシティブだと ARP Reply 受信直後に
//                    ARP_RESOLVED→ARP_WAIT_REPLY に1クロック戻ってしまい
//                    target_mac_valid が20nsしかHighにならず ARM が検出できなかった。
//                    立ち上がりエッジのみでトリガすることで ARP_RESOLVED を保持する。
//   rev5 2026-06-06  rx_is_request/rx_is_reply から !rx_bad を削除:
//                    mii_mac_rxはtlast以外の全バイトでtuser=1を出すためrx_badは常に1になり
//                    rx_is_reply/rx_is_requestが常にFALSEでARP Reply/Requestを認識できなかった。
//                    FSMが!rx_tuser(tlast時)でCRCを判定しているため rx_bad は不要。
//   rev4 2026-06-03  send_req受付条件をARP_IDLEのみ→ARP_IDLE||ARP_RESOLVEDに拡張:
//                    ARP解決後に再ARP要求を出してもHWが無視していた（2回目以降Wiresharkに出ない）バグを修正
//   rev3 2026-06-01  FSM受付条件に!rx_tuser(tlast時)ガードを追加:
//                    rx_is_request/rx_is_replyの!rx_bad削除は未完了のままだった(rev5で完成)
//   rev2 2026-06-01  is_reply_pkt の二重宣言を修正
//   rev1 2026-05-31  is_reply_pkt をラッチ化: ARP Replyがバイト1以降でRequest内容に化けるバグを修正
//
// ARPエンジン
//
// 機能:
//   ① ARP Request送信: target_ipのMACアドレスを解決する (能動的ARP)
//   ② ARP Reply送信:   自分宛のARP Requestに応答する (受動的ARP)
//   ③ 1秒ごとにARP Requestを再送 (reply未受信の場合)
//
// フレーム内バイト位置 (frame_muxからの入力, Etherヘッダ込み):
//   バイト 0- 5: 宛先MAC
//   バイト 6-11: 送信元MAC (ARP SHA の先読み)
//   バイト12-13: EtherType (0x0806)
//   バイト14-21: ARP HTYPE/PTYPE/HLEN/PLEN/OPER
//   バイト22-27: ARP SHA (送信元HWアドレス) ← 解決したMACはここから取得
//   バイト28-31: ARP SPA (送信元IPアドレス)
//   バイト32-37: ARP THA (宛先HWアドレス)
//   バイト38-41: ARP TPA (宛先IPアドレス)
//   バイト42-59: パディング

module arp_engine #(
    parameter CLK_HZ = 50_000_000
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 設定 (接続中は変化しない) -------------------------------------------
    input  wire [47:0] local_mac,   // 自分のMACアドレス
    input  wire [31:0] local_ip,    // 自分のIPアドレス
    input  wire [31:0] target_ip,   // 解決したい相手のIPアドレス

    // ---- ARP Requestトリガ (PS→FPGA CDC済み) ----------------------------------
    input  wire        send_req,          // 立ち上がりエッジでトリガ
    output logic       target_mac_valid,  // 解決完了フラグ
    output logic [47:0] target_mac_o,     // 解決したMACアドレス

    // ---- RX (frame_muxからのARPフレーム) --------------------------------------
    input  wire [7:0]  rx_tdata,
    input  wire        rx_tvalid,
    input  wire        rx_tlast,
    input  wire        rx_tuser,  // 1=CRCエラー

    // ---- TX (TXアービタへ) ----------------------------------------------------
    output logic [7:0] tx_tdata,
    output logic       tx_tvalid,
    input  wire        tx_tready,
    output logic       tx_tlast
);

// ---------------------------------------------------------------------------
// RX: バイトごとにフィールドを抽出
// ---------------------------------------------------------------------------
logic [5:0]  rx_idx;          // フレーム内バイトインデックス
logic [5:0]  nxt;             // TXポインタ次の値 (always_ff内で使用)
logic [47:0] rx_sha;          // 受信フレームの送信元MACアドレス
logic [31:0] rx_spa;          // 受信フレームの送信元IPアドレス
logic [31:0] rx_tpa;          // 受信フレームの宛先IPアドレス
logic [15:0] rx_oper;         // ARP操作コード (0x0001=Request, 0x0002=Reply)

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rx_idx  <= '0;
        rx_sha  <= '0;
        rx_spa  <= '0;
        rx_tpa  <= '0;
        rx_oper <= '0;
    end else begin
        if (rx_tvalid) begin
            // バイト位置に応じてフィールドを取り込む
            case (rx_idx)
                // Etherヘッダの送信元MAC (バイト6-11) ← 後でARP SHAで上書き
                6'd6:  rx_sha[47:40] <= rx_tdata;
                6'd7:  rx_sha[39:32] <= rx_tdata;
                6'd8:  rx_sha[31:24] <= rx_tdata;
                6'd9:  rx_sha[23:16] <= rx_tdata;
                6'd10: rx_sha[15:8]  <= rx_tdata;
                6'd11: rx_sha[7:0]   <= rx_tdata;
                // ARP 操作コード (バイト20-21)
                6'd20: rx_oper[15:8] <= rx_tdata;
                6'd21: rx_oper[7:0]  <= rx_tdata;
                // ARP SHA: 送信元MACアドレス (バイト22-27)
                6'd22: rx_sha[47:40] <= rx_tdata;
                6'd23: rx_sha[39:32] <= rx_tdata;
                6'd24: rx_sha[31:24] <= rx_tdata;
                6'd25: rx_sha[23:16] <= rx_tdata;
                6'd26: rx_sha[15:8]  <= rx_tdata;
                6'd27: rx_sha[7:0]   <= rx_tdata;
                // ARP SPA: 送信元IPアドレス (バイト28-31)
                6'd28: rx_spa[31:24] <= rx_tdata;
                6'd29: rx_spa[23:16] <= rx_tdata;
                6'd30: rx_spa[15:8]  <= rx_tdata;
                6'd31: rx_spa[7:0]   <= rx_tdata;
                // ARP TPA: 宛先IPアドレス (バイト38-41)
                6'd38: rx_tpa[31:24] <= rx_tdata;
                6'd39: rx_tpa[23:16] <= rx_tdata;
                6'd40: rx_tpa[15:8]  <= rx_tdata;
                6'd41: rx_tpa[7:0]   <= rx_tdata;
                default: ;
            endcase

            if (rx_tlast) begin
                rx_idx <= '0;
            end else if (rx_idx < 6'd63)
                rx_idx <= rx_idx + 1'b1;
        end
    end
end

// ---------------------------------------------------------------------------
// ARP FSM (状態機械)
// ---------------------------------------------------------------------------
typedef enum logic [2:0] {
    ARP_IDLE,        // 待機中
    ARP_DO_REQUEST,  // (未使用: IDLEからWAIT_REPLYへ直遷移するため)
    ARP_WAIT_REPLY,  // ARP Reply待機中 (1秒ごとに再送)
    ARP_DO_REPLY,    // ARP Reply送信中
    ARP_RESOLVED     // MAC解決済み
} arp_state_t;

arp_state_t arp_state = ARP_IDLE;

// 再送タイマー: CLK_HZクロック = 1秒
localparam RETRY_CNT = CLK_HZ;
logic [25:0] retry_timer = '0;
logic        retry_pulse;         // 1秒ごとのパルス

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        retry_timer <= '0;
        retry_pulse <= 1'b0;
    end else begin
        retry_pulse <= 1'b0;
        if (arp_state == ARP_WAIT_REPLY) begin
            // WAIT_REPLY中は1秒カウント
            if (retry_timer == RETRY_CNT[25:0] - 1'b1) begin
                retry_timer <= '0;
                retry_pulse <= 1'b1; // 1秒経過: 再送パルス発生
            end else
                retry_timer <= retry_timer + 1'b1;
        end else
            retry_timer <= '0; // ARP_WAIT_REPLY以外はリセット
    end
end

// 受信フレームの種別判定 (rx_tlast時点の登録値で評価)
logic rx_is_request; // 自分宛のARP Request
logic rx_is_reply;   // target_ip発のARP Reply
// !rx_bad は不要: FSMの受付ガード(rx_tvalid&&rx_tlast&&!rx_tuser)がCRC判定を担当する。
// rx_badはtlast以外の全バイトでtuser=1のため常に1になりここに含めると永遠にFALSEになる。
assign rx_is_request = (rx_oper == 16'h0001) && (rx_tpa == local_ip);
assign rx_is_reply   = (rx_oper == 16'h0002) && (rx_spa == target_ip);

// send_req 立ち上がりエッジ検出
// レベルセンシティブだと ARP Reply 受信後も send_req=HIGH のままで
// ARP_RESOLVED→ARP_WAIT_REPLY に即リセットされ target_mac_valid が 20ns しか出ない
logic send_req_prev = 1'b0;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) send_req_prev <= 1'b0;
    else        send_req_prev <= send_req;
end
wire send_req_rise = send_req && !send_req_prev;

// 送信保留フラグ
logic do_request = 1'b0; // ARP Request送信要求
logic do_reply   = 1'b0; // ARP Reply送信要求
logic [47:0] reply_dst_mac = '0; // Reply宛先MAC
logic [31:0] reply_dst_ip  = '0; // Reply宛先IP

// TX関連 (always_ff内で使用するため先行宣言)
logic [5:0] tx_ptr    = '0;
logic       tx_active = 1'b0;
logic       tx_send_start;
assign tx_send_start = !tx_active && (do_reply || do_request);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        arp_state        <= ARP_IDLE;
        target_mac_valid <= 1'b0;
        target_mac_o     <= '0;
        do_request       <= 1'b0;
        do_reply         <= 1'b0;
    end else begin
        // フレーム終端でRX種別を評価
        if (rx_tvalid && rx_tlast && !rx_tuser) begin  // rx_tuserがtlast時のCRC結果を示す
            // ARP Replyを受信し、かつ待機中 → MAC解決完了
            if (rx_is_reply && (arp_state == ARP_WAIT_REPLY || arp_state == ARP_DO_REQUEST)) begin
                target_mac_o     <= rx_sha;
                target_mac_valid <= 1'b1;
                arp_state        <= ARP_RESOLVED;
            end
            // ARP Requestを受信 → Reply予約
            if (rx_is_request) begin
                reply_dst_mac <= rx_sha;
                reply_dst_ip  <= rx_spa;
                do_reply      <= 1'b1;
            end
        end

        // PS→FPGA: ARP Request送信トリガ (立ち上がりエッジのみ)
        // IDLE / RESOLVED 両方から受け付け (再ARP対応)
        if (send_req_rise && (arp_state == ARP_IDLE || arp_state == ARP_RESOLVED)) begin
            target_mac_valid <= 1'b0;
            arp_state        <= ARP_WAIT_REPLY;
            do_request       <= 1'b1;
        end

        // 1秒タイマーによる再送
        if (retry_pulse)
            do_request <= 1'b1;

        // TX開始時に送信フラグをクリア
        if (tx_send_start) begin
            do_request <= 1'b0;
            do_reply   <= 1'b0;
        end
    end
end

// ---------------------------------------------------------------------------
// TX: 60バイトARPパケット生成・送信
// ---------------------------------------------------------------------------
logic [7:0] pkt_buf [0:59]; // パケットバッファ (組み合わせ回路で構築)

// is_reply_pkt: 送信開始サイクル(tx_active=0)は do_reply を直接使用し、
// 送信中(tx_active=1)はラッチ値を使用する。
// ★バグ修正: tx_send_start発火と同時に do_reply がクリアされるため、
//   組み合わせ代入だとバイト1以降がRequest内容に化けてしまう。
logic is_reply_lat = 1'b0; // 送信中のReply/Request種別保持用ラッチ

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) is_reply_lat <= 1'b0;
    else if (tx_send_start) is_reply_lat <= do_reply; // 送信開始時に確定
end

// 送信開始サイクルのみ do_reply を直接参照 (バイト0を正しく生成するため)
// 送信中は is_reply_lat を使用 (do_reply がクリアされても安全)
logic is_reply_pkt;
assign is_reply_pkt = tx_active ? is_reply_lat : do_reply;

// パケット宛先フィールド (Request=ブロードキャスト / Reply=要求元)
logic [47:0] pkt_dst_mac;
logic [47:0] pkt_arp_tha;
logic [31:0] pkt_arp_tpa;
assign pkt_dst_mac = is_reply_pkt ? reply_dst_mac       : 48'hFFFF_FFFF_FFFF;
assign pkt_arp_tha = is_reply_pkt ? reply_dst_mac       : 48'h0;
assign pkt_arp_tpa = is_reply_pkt ? reply_dst_ip        : target_ip;

// パケットバッファ組み立て (組み合わせ回路)
always_comb begin
    // --- Ethernetヘッダ ---
    pkt_buf[0]  = pkt_dst_mac[47:40]; pkt_buf[1]  = pkt_dst_mac[39:32];
    pkt_buf[2]  = pkt_dst_mac[31:24]; pkt_buf[3]  = pkt_dst_mac[23:16];
    pkt_buf[4]  = pkt_dst_mac[15:8];  pkt_buf[5]  = pkt_dst_mac[7:0];
    pkt_buf[6]  = local_mac[47:40];   pkt_buf[7]  = local_mac[39:32];  // 送信元MAC
    pkt_buf[8]  = local_mac[31:24];   pkt_buf[9]  = local_mac[23:16];
    pkt_buf[10] = local_mac[15:8];    pkt_buf[11] = local_mac[7:0];
    pkt_buf[12] = 8'h08;              pkt_buf[13] = 8'h06; // EtherType=ARP
    // --- ARPヘッダ ---
    pkt_buf[14] = 8'h00; pkt_buf[15] = 8'h01; // HTYPE=Ethernet
    pkt_buf[16] = 8'h08; pkt_buf[17] = 8'h00; // PTYPE=IPv4
    pkt_buf[18] = 8'h06; pkt_buf[19] = 8'h04; // HLEN=6, PLEN=4
    pkt_buf[20] = 8'h00;
    pkt_buf[21] = is_reply_pkt ? 8'h02 : 8'h01; // OPER: 1=Request, 2=Reply
    // SHA: 送信元MACアドレス (自分)
    pkt_buf[22] = local_mac[47:40];   pkt_buf[23] = local_mac[39:32];
    pkt_buf[24] = local_mac[31:24];   pkt_buf[25] = local_mac[23:16];
    pkt_buf[26] = local_mac[15:8];    pkt_buf[27] = local_mac[7:0];
    // SPA: 送信元IPアドレス (自分)
    pkt_buf[28] = local_ip[31:24];    pkt_buf[29] = local_ip[23:16];
    pkt_buf[30] = local_ip[15:8];     pkt_buf[31] = local_ip[7:0];
    // THA: 宛先MACアドレス
    pkt_buf[32] = pkt_arp_tha[47:40]; pkt_buf[33] = pkt_arp_tha[39:32];
    pkt_buf[34] = pkt_arp_tha[31:24]; pkt_buf[35] = pkt_arp_tha[23:16];
    pkt_buf[36] = pkt_arp_tha[15:8];  pkt_buf[37] = pkt_arp_tha[7:0];
    // TPA: 宛先IPアドレス
    pkt_buf[38] = pkt_arp_tpa[31:24]; pkt_buf[39] = pkt_arp_tpa[23:16];
    pkt_buf[40] = pkt_arp_tpa[15:8];  pkt_buf[41] = pkt_arp_tpa[7:0];
    // パディング (最小フレーム60バイト確保)
    for (int i = 42; i < 60; i++) pkt_buf[i] = 8'h00;
end

// TX AXI-Streamステートマシン
// バイト0から59まで順番にpkt_bufを送出する
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tx_active <= 1'b0;
        tx_ptr    <= '0;
        tx_tvalid <= 1'b0;
        tx_tlast  <= 1'b0;
        tx_tdata  <= 8'h00;
    end else begin
        if (tx_send_start) begin
            // 送信開始: バイト0をセット
            tx_active <= 1'b1;
            tx_ptr    <= 6'd0;
            tx_tdata  <= pkt_buf[0];
            tx_tvalid <= 1'b1;
            tx_tlast  <= 1'b0;
        end else if (tx_active && tx_tready) begin
            if (tx_tlast) begin
                // 最終バイト転送完了 → 送信終了
                tx_active <= 1'b0;
                tx_tvalid <= 1'b0;
                tx_tlast  <= 1'b0;
            end else begin
                // 次のバイトへ進む
                nxt = tx_ptr + 1'b1;
                tx_ptr    <= nxt;
                tx_tdata  <= pkt_buf[nxt];
                tx_tvalid <= 1'b1;
                tx_tlast  <= (nxt == 6'd59); // バイト59が最終
            end
        end
    end
end

endmodule
`default_nettype wire
