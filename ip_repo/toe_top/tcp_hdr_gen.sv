`default_nettype none
// 改版履歴:
//   rev3 2026-06-03  S_SEND_PAD: tx_tlastをtx_ptr==58で先読み立て→バイト59転送時にtlast=1を保証
//                    修正前: tx_ptr==59でtx_tlast<=1'b1(NBA)→次クロックで反映されるため
//                    バイト59がtlast=0で転送されappend_crcがFCSを出力しなかった
//                    結果FCSなしフレームがNICでハードウェア棄却→Wiresharkに届かなかった
//   rev2 2026-06-03  S_SEND_HDR: if(tx_tready)→if(tx_tready&&tx_tvalid)に変更
//                    S_BUILDからS_SEND_HDRに遷移した初回サイクルはtx_tvalid出力がまだ0だが
//                    append_crcがS_IDLEのためmac_tx_tready=1になりtx_ptrが空振りインクリメント
//                    していた。hdr_buf[1]がスキップされFCSが不正になりPC NICでフレームが棄却
//                    されていたため、SYNがWiresharkに見えずSYN_SENTタイムアウトになっていた。
//   rev1 2026-06-01  制御パケットをS_BUILD経由に変更: S_IDLEでbuild_hdr直呼びだと
//                    l_*の<=代入が未反映のため初回SYNの宛先MACが全0になるバグを修正
//
// ===========================================================================
// tcp_hdr_gen.sv — TCP/IP/Ethernetヘッダ生成モジュール
//
// 機能概要:
//   tcp_state_ctrlからの送信要求を受けて、Ethernet+IP+TCPヘッダを生成し、
//   オプションのペイロードとともにAXI-Streamで出力する。
//
// 2パス処理（データセグメントの場合）:
//   Pass 1（S_CSUM_PAYLOAD）: tx_bufferからペイロードを読み出しチェックサムを計算
//   Pass 2（S_SEND_HDR / S_SEND_PAYLOAD）: ヘッダを先頭に付けてフレーム全体を送信
//
// 制御パケット（SYN/ACK/FIN, payload_len=0）の場合:
//   チェックサムは組み合わせ論理で即時計算し、1パスで送信する。
//
// ヘッダ構成（54バイト固定）:
//   バイト  0-13: Ethernetヘッダ（Dst MAC 6B + Src MAC 6B + EtherType 2B）
//   バイト 14-33: IPヘッダ（20バイト、TTL=64, Proto=TCP=6）
//   バイト 34-53: TCPヘッダ（20バイト、データオフセット=5）
//
// Ethernet最小フレームサイズ:
//   ペイロードなし（60バイト未満）の場合はゼロパディングを追加する
//
// パラメータ:
//   WIN_SIZE : アドバタイズする受信ウィンドウサイズ（デフォルト 4096バイト）
// ===========================================================================

module tcp_hdr_gen #(
    parameter WIN_SIZE = 16'd4096  // アドバタイズする受信ウィンドウサイズ
)(
    input  wire        clk,    // システムクロック
    input  wire        rst_n,  // 非同期リセット（負論理）

    // ---- tcp_state_ctrlからのヘッダフィールド --------------------------------
    input  wire        send_req,      // 送信要求（1サイクルパルス）
    input  wire [8:0]  flags,         // TCP制御フラグ: NS|CWR|ECE|URG|ACK|PSH|RST|SYN|FIN
    input  wire [31:0] seq_num,       // 送信シーケンス番号
    input  wire [31:0] ack_num,       // 送信ACK番号
    input  wire [10:0] payload_len,   // ペイロード長（制御パケットは0）
    input  wire        payload_en,    // 1=tx_bufferからペイロードを取得
    output logic        gen_busy,      // 生成中はアサート（1=ビジー）

    // ---- アドレス情報（send_req時にラッチ） -----------------------------------
    input  wire [47:0] local_mac,   // ローカルMACアドレス（送信元）
    input  wire [47:0] remote_mac,  // リモートMACアドレス（宛先）
    input  wire [31:0] local_ip,    // ローカルIPアドレス（送信元）
    input  wire [31:0] remote_ip,   // リモートIPアドレス（宛先）
    input  wire [15:0] local_port,  // ローカルTCPポート（送信元）
    input  wire [15:0] remote_port, // リモートTCPポート（宛先）

    // ---- tx_bufferとのインタフェース（ペイロード読み出し） --------------------
    // Pass 1: buf_send_reqをアサートしてペイロードをストリーミング受信
    output logic        buf_send_req,  // tx_bufferへの送信開始要求（パルス）
    output logic [10:0] buf_send_len,  // 要求するペイロード長
    input  wire        buf_busy,      // tx_bufferがビジーフラグ
    input  wire [7:0]  buf_rd_data,   // tx_bufferからの読み出しデータ
    input  wire        buf_rd_valid,  // 読み出しデータ有効
    input  wire        buf_rd_last,   // セグメント末尾フラグ

    // ---- TXアービタへのAXI-Stream出力 ------------------------------------------
    output logic [7:0]  tx_tdata,   // 送信データ（1バイト）
    output logic        tx_tvalid,  // 送信データ有効
    input  wire        tx_tready,  // 送信レディ（バックプレッシャー）
    output logic        tx_tlast    // フレーム末尾
);

// ---------------------------------------------------------------------------
// 定数定義
// ---------------------------------------------------------------------------
localparam HDR_LEN = 8'd54;   // ヘッダ長: Eth(14) + IP(20) + TCP(20) = 54バイト
localparam MIN_LEN = 8'd60;   // Ethernet最小フレーム長（ペイロード含まず）

// ---------------------------------------------------------------------------
// 状態機械の状態定義
// ---------------------------------------------------------------------------
typedef enum logic [2:0] {
    S_IDLE,          // アイドル（送信要求待ち）
    S_CSUM_PAYLOAD,  // Pass 1: ペイロードを読み出してチェックサムを蓄積
    S_BUILD,         // 最終チェックサムを計算してヘッダバッファを埋める
    S_SEND_HDR,      // ヘッダバイトを順次ストリーミング送信
    S_SEND_PAYLOAD,  // Pass 2: ペイロードを再ストリーミング送信
    S_SEND_PAD       // Ethernet最小フレームサイズに達するまでゼロパディング
} state_t;
state_t state = S_IDLE;

// ---------------------------------------------------------------------------
// send_req時にラッチするパラメータ（送信処理中は固定）
// ---------------------------------------------------------------------------
logic [47:0] l_dst_mac, l_src_mac;      // MACアドレス（宛先・送信元）
logic [31:0] l_src_ip, l_dst_ip;        // IPアドレス（送信元・宛先）
logic [15:0] l_src_port, l_dst_port;    // TCPポート（送信元・宛先）
logic [31:0] l_seq, l_ack;              // シーケンス番号・ACK番号
logic [8:0]  l_flags;                   // TCP制御フラグ
logic [10:0] l_plen;                    // ペイロード長
logic        l_pload;                   // ペイロード有効フラグ

// ---------------------------------------------------------------------------
// TCP部分チェックサム計算関数（疑似ヘッダ + TCPヘッダ固定部分）
// チェックサムフィールドは0として計算する（1の補数和）
// ---------------------------------------------------------------------------
function automatic [31:0] tcp_partial_csum;
    input [31:0] src_ip, dst_ip;
    input [15:0] src_port, dst_port;
    input [31:0] seq, ack;
    input [8:0]  flags;
    input [15:0] payload_len;
    logic [31:0] s;
    begin
        // TCP疑似ヘッダ（送信元IP + 宛先IP + プロトコル番号 + TCPセグメント長）
        s = src_ip[31:16] + src_ip[15:0]
          + dst_ip[31:16] + dst_ip[15:0]
          + 32'h0000_0006                      // プロトコル番号=6（TCP）
          + {16'h0, payload_len + 16'd20};     // TCPセグメント長（ヘッダ20 + ペイロード）
        // TCPヘッダ固定部分（チェックサムフィールド=0、緊急ポインタ=0として計算）
        s += {16'h0, src_port};
        s += {16'h0, dst_port};
        s += {seq[31:16]};
        s += {seq[15:0]};
        s += {ack[31:16]};
        s += {ack[15:0]};
        s += 32'h0000_5000;   // データオフセット=5（20バイト）, 予約ビット=0
        s += {16'h0, 7'h0, flags[7:0]};  // 制御フラグ（下位6ビット）
        s += {16'h0, WIN_SIZE};           // 受信ウィンドウサイズ
        // 緊急ポインタ = 0（加算省略）
        tcp_partial_csum = s;
    end
endfunction

// 32ビット1の補数和を16ビットに折り畳む（キャリーを折り込む）
function automatic [15:0] fold32;
    input [31:0] s;
    logic [16:0] t;
    begin
        t     = {1'b0, s[31:16]} + {1'b0, s[15:0]};
        fold32 = t[15:0] + {15'h0, t[16]};  // キャリーを最下位ビットに足す
    end
endfunction

// 17ビット値を16ビットに折り畳む
function automatic [15:0] fold17;
    input [16:0] s;
    fold17 = s[15:0] + {15'h0, s[16]};
endfunction

// ---------------------------------------------------------------------------
// IPヘッダチェックサム計算関数
// IPヘッダの1の補数和の補数を計算する
// ---------------------------------------------------------------------------
function automatic [15:0] ip_checksum;
    input [31:0] src_ip, dst_ip;
    input [15:0] total_len;
    logic [31:0] s;
    begin
        // IPヘッダ固定部分（VER=4, IHL=5, DSCP=0, ECN=0, ID=0, DF=1, TTL=64, Proto=TCP）
        s = 32'h4500         // ver=4, IHL=5, DSCP=0, ECN=0
          + {16'h0, total_len}
          + 32'h4000         // ID=0, DF（フラグメント禁止）フラグ
          + 32'h4006;        // TTL=64, プロトコル=6（TCP）
        // チェックサムフィールドは0（省略）
        s += {16'h0, src_ip[31:16]} + {16'h0, src_ip[15:0]};
        s += {16'h0, dst_ip[31:16]} + {16'h0, dst_ip[15:0]};
        ip_checksum = ~fold32(s);  // 1の補数（最終チェックサム値）
    end
endfunction

// ---------------------------------------------------------------------------
// 60バイトのヘッダバッファ（Eth 14B + IP 20B + TCP 20B + パディング 6B）
// ---------------------------------------------------------------------------
logic [7:0] hdr_buf [0:59];   // ヘッダバイト配列（最大60バイト）
logic [6:0] tx_ptr;           // ヘッダ送信バイトインデックス
logic [10:0] pay_cnt;         // 残りペイロードバイト数

// ---------------------------------------------------------------------------
// ペイロードチェックサムアキュムレータ（Pass 1用）
// ペイロードバイトを2バイトずつ16ビットワードとして加算する
// ---------------------------------------------------------------------------
logic [31:0] pay_csum_acc = '0;    // ペイロードチェックサム蓄積値
logic        pay_csum_phase = 1'b0; // 0=高バイト待ち, 1=低バイト待ち
logic [7:0]  pay_csum_prev  = '0;  // 高バイト保持用

// ---------------------------------------------------------------------------
// ヘッダバッファ構築タスク（S_BUILD状態またはS_IDLEから呼び出す）
// build_hdr()を呼び出すと hdr_buf[0..59] に完成したヘッダが格納される
// ---------------------------------------------------------------------------
task build_hdr;
    // always_ff内でhdr_bufをブロッキング代入(=)すると
    // VivadoがFF更新を正しく合成しない場合があるため<=（NBA）を使用する。
    // ローカル変数の計算は=のまま（タスク内の逐次計算に必要）。
    logic [15:0] ip_total;        // IPトータル長（IPヘッダ + TCPヘッダ + ペイロード）
    logic [15:0] ip_csum_val;     // IPヘッダチェックサム値
    logic [31:0] tcp_base;        // TCP部分チェックサム（疑似ヘッダ + TCPヘッダ固定部）
    logic [31:0] tcp_with_pay;    // TCP部分チェックサム + ペイロードチェックサム
    logic [15:0] tcp_csum_val;    // 最終TCPチェックサム値
    logic [15:0] pay_len16;       // ペイロード長（16ビット）
    begin
        pay_len16  = {5'h0, l_plen};
        ip_total   = 16'd40 + pay_len16;  // IP(20) + TCP(20) + ペイロード
        ip_csum_val = ip_checksum(l_src_ip, l_dst_ip, ip_total);

        // TCPチェックサム = 部分チェックサム + ペイロードチェックサム（既に蓄積済み）
        tcp_base     = tcp_partial_csum(l_src_ip, l_dst_ip, l_src_port, l_dst_port,
                                        l_seq, l_ack, l_flags, pay_len16);
        tcp_with_pay = tcp_base + pay_csum_acc;
        tcp_csum_val = ~fold32(tcp_with_pay);  // 1の補数

        // Ethernetヘッダ（14バイト）
        hdr_buf[0]  <= l_dst_mac[47:40]; hdr_buf[1]  <= l_dst_mac[39:32];
        hdr_buf[2]  <= l_dst_mac[31:24]; hdr_buf[3]  <= l_dst_mac[23:16];
        hdr_buf[4]  <= l_dst_mac[15:8];  hdr_buf[5]  <= l_dst_mac[7:0];
        hdr_buf[6]  <= l_src_mac[47:40]; hdr_buf[7]  <= l_src_mac[39:32];
        hdr_buf[8]  <= l_src_mac[31:24]; hdr_buf[9]  <= l_src_mac[23:16];
        hdr_buf[10] <= l_src_mac[15:8];  hdr_buf[11] <= l_src_mac[7:0];
        hdr_buf[12] <= 8'h08;            hdr_buf[13] <= 8'h00;  // EtherType=0x0800（IPv4）

        // IPヘッダ（20バイト）
        hdr_buf[14] <= 8'h45;  // ver=4（IPv4）, IHL=5（20バイト）
        hdr_buf[15] <= 8'h00;  // DSCP=0, ECN=0
        hdr_buf[16] <= ip_total[15:8];   hdr_buf[17] <= ip_total[7:0];   // トータル長
        hdr_buf[18] <= 8'h00;            hdr_buf[19] <= 8'h00;  // ID=0（フラグメントなし）
        hdr_buf[20] <= 8'h40;            hdr_buf[21] <= 8'h00;  // DF=1, フラグメントオフセット=0
        hdr_buf[22] <= 8'd64;            hdr_buf[23] <= 8'd6;   // TTL=64, プロトコル=TCP(6)
        hdr_buf[24] <= ip_csum_val[15:8];hdr_buf[25] <= ip_csum_val[7:0];  // IPチェックサム
        hdr_buf[26] <= l_src_ip[31:24];  hdr_buf[27] <= l_src_ip[23:16];
        hdr_buf[28] <= l_src_ip[15:8];   hdr_buf[29] <= l_src_ip[7:0];    // 送信元IP
        hdr_buf[30] <= l_dst_ip[31:24];  hdr_buf[31] <= l_dst_ip[23:16];
        hdr_buf[32] <= l_dst_ip[15:8];   hdr_buf[33] <= l_dst_ip[7:0];    // 宛先IP

        // TCPヘッダ（20バイト）
        hdr_buf[34] <= l_src_port[15:8]; hdr_buf[35] <= l_src_port[7:0];  // 送信元ポート
        hdr_buf[36] <= l_dst_port[15:8]; hdr_buf[37] <= l_dst_port[7:0];  // 宛先ポート
        hdr_buf[38] <= l_seq[31:24];     hdr_buf[39] <= l_seq[23:16];
        hdr_buf[40] <= l_seq[15:8];      hdr_buf[41] <= l_seq[7:0];       // シーケンス番号
        hdr_buf[42] <= l_ack[31:24];     hdr_buf[43] <= l_ack[23:16];
        hdr_buf[44] <= l_ack[15:8];      hdr_buf[45] <= l_ack[7:0];       // ACK番号
        hdr_buf[46] <= 8'h50;            // データオフセット=5（20バイト）, 予約=0
        hdr_buf[47] <= {3'h0, l_flags[5:0]};  // TCP制御フラグ（下位6ビット: URG..FIN）
        hdr_buf[48] <= WIN_SIZE[15:8];   hdr_buf[49] <= WIN_SIZE[7:0];    // 受信ウィンドウ
        hdr_buf[50] <= tcp_csum_val[15:8]; hdr_buf[51] <= tcp_csum_val[7:0];  // TCPチェックサム
        hdr_buf[52] <= 8'h00;            hdr_buf[53] <= 8'h00;  // 緊急ポインタ=0

        // Ethernet最小フレームサイズ60バイトへのゼロパディング（制御パケット用）
        for (int i = 54; i < 60; i++) hdr_buf[i] <= 8'h00;
    end
endtask

// ---------------------------------------------------------------------------
// メイン状態機械
// ---------------------------------------------------------------------------
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state         <= S_IDLE;
        gen_busy      <= 1'b0;
        tx_tvalid     <= 1'b0;
        tx_tlast      <= 1'b0;
        tx_tdata      <= 8'h00;
        tx_ptr        <= '0;
        pay_cnt       <= '0;
        pay_csum_acc  <= '0;
        pay_csum_phase <= 1'b0;
        buf_send_req  <= 1'b0;
        buf_send_len  <= '0;
    end else begin
        tx_tvalid    <= 1'b0;  // 毎サイクルクリア（有効なサイクルのみアサート）
        tx_tlast     <= 1'b0;  // 毎サイクルクリア（末尾バイトのサイクルのみアサート）
        buf_send_req <= 1'b0;  // 毎サイクルクリア（1サイクルパルス）

        case (state)

        // ------------------------------------------------------------------
        // アイドル状態: 送信要求を待つ
        // ------------------------------------------------------------------
        S_IDLE: begin
            gen_busy <= 1'b0;
            if (send_req) begin
                // 送信パラメータをラッチ（処理中に変化しても影響しないよう）
                l_dst_mac  <= remote_mac;  l_src_mac  <= local_mac;
                l_src_ip   <= local_ip;    l_dst_ip   <= remote_ip;
                l_src_port <= local_port;  l_dst_port <= remote_port;
                l_seq      <= seq_num;     l_ack      <= ack_num;
                l_flags    <= flags;       l_plen     <= payload_len;
                l_pload    <= payload_en;
                gen_busy   <= 1'b1;  // 生成開始

                pay_csum_acc   <= '0;  // チェックサムアキュムレータをリセット
                pay_csum_phase <= 1'b0;

                if (payload_en && payload_len != '0) begin
                    // データパケット: Pass 1（ペイロードチェックサム計算）を開始
                    buf_send_req <= 1'b1;       // tx_bufferにセグメント読み出し要求
                    buf_send_len <= payload_len;
                    state <= S_CSUM_PAYLOAD;
                end else begin
                    // 制御パケット: S_BUILDを経由してl_*のFFが確定してからbuild_hdrを呼ぶ
                    // ★バグ修正: S_IDLEでbuild_hdrを即呼ぶと<=代入が未反映で宛先MACが全0になる
                    state <= S_BUILD;
                end
            end
        end

        // ------------------------------------------------------------------
        // S_CSUM_PAYLOAD: Pass 1 — ペイロードバイトを受信してチェックサムを蓄積
        // ペイロードを2バイトずつ16ビットワードとして1の補数加算する
        // ------------------------------------------------------------------
        S_CSUM_PAYLOAD: begin
            if (buf_rd_valid) begin
                if (pay_csum_phase == 1'b0) begin
                    // 高バイト（偶数バイト）を保存
                    pay_csum_prev  <= buf_rd_data;
                    pay_csum_phase <= 1'b1;
                end else begin
                    // 低バイト（奇数バイト）が来たら16ビットワードとして加算
                    pay_csum_acc   <= pay_csum_acc
                                    + {16'h0, pay_csum_prev, buf_rd_data};
                    pay_csum_phase <= 1'b0;
                end
                if (buf_rd_last) begin
                    // 末尾に奇数バイトが余った場合はゼロパディングして加算
                    if (pay_csum_phase == 1'b0)  // 高バイト保持中なら奇数バイト末尾
                        pay_csum_acc <= pay_csum_acc
                                      + {16'h0, buf_rd_data, 8'h00};  // 低バイトをゼロ補完
                    state <= S_BUILD;  // チェックサム蓄積完了 → ヘッダ構築へ
                end
            end
        end

        // ------------------------------------------------------------------
        // S_BUILD: 最終チェックサムを計算してヘッダバッファを構築する
        // build_hdr()タスクを呼び出してhdr_bufを埋め、Pass 2の送信を準備する
        // ------------------------------------------------------------------
        S_BUILD: begin
            build_hdr();  // IPチェックサム・TCPチェックサムを含むヘッダを構築
            // データパケット(Pass 2)のみtx_bufferに再読み出し要求を送る
            // 制御パケット(l_plen=0)はbuf_send_reqを出さない
            if (l_pload && l_plen != '0) begin
                buf_send_req <= 1'b1;
                buf_send_len <= l_plen;
                pay_cnt      <= l_plen;
            end
            state        <= S_SEND_HDR;
            tx_ptr       <= 7'd0;
        end

        // ------------------------------------------------------------------
        // S_SEND_HDR: ヘッダバイトを順次AXI-Streamに出力する（0〜53バイト目）
        // ------------------------------------------------------------------
        S_SEND_HDR: begin
            tx_tvalid <= 1'b1;
            tx_tdata  <= hdr_buf[tx_ptr];  // 現在のヘッダバイトを出力
            if (tx_tready && tx_tvalid) begin  // tvalid=0の初回サイクルはptrを進めない
                if (tx_ptr == 7'd53) begin
                    // ヘッダ末尾（バイト53）を送信完了
                    if (l_pload && l_plen != '0)
                        state <= S_SEND_PAYLOAD;  // ペイロードがあれば次へ
                    else if (7'd53 < 7'd59) begin
                        // ペイロードなし: 60バイトに達するまでゼロパディング
                        state  <= S_SEND_PAD;
                        tx_ptr <= 7'd54;
                    end else begin
                        // ちょうど60バイト: フレーム末尾を出力してIDLEへ
                        tx_tlast <= 1'b1;
                        state    <= S_IDLE;
                    end
                end else
                    tx_ptr <= tx_ptr + 1'b1;  // 次のヘッダバイトへ
            end
        end

        // ------------------------------------------------------------------
        // S_SEND_PAYLOAD: Pass 2 — tx_bufferからペイロードを再ストリーミング送信
        // ------------------------------------------------------------------
        S_SEND_PAYLOAD: begin
            if (buf_rd_valid) begin
                tx_tdata  <= buf_rd_data;  // ペイロードバイトを出力
                tx_tvalid <= 1'b1;
                if (buf_rd_last) begin
                    // ペイロード末尾: フレーム末尾フラグを立てて完了
                    tx_tlast <= 1'b1;
                    state    <= S_IDLE;
                    gen_busy <= 1'b0;
                end
            end
        end

        // ------------------------------------------------------------------
        // S_SEND_PAD: Ethernet最小フレームサイズ（60バイト）に達するまでゼロ送信
        // ------------------------------------------------------------------
        S_SEND_PAD: begin
            tx_tvalid <= 1'b1;
            tx_tdata  <= 8'h00;  // パディングはゼロバイト
            if (tx_tready) begin
                if (tx_ptr == 7'd59) begin
                    // 60バイト目: フレーム末尾フラグはtx_ptr==58の時点で立済み
                    state    <= S_IDLE;
                    gen_busy <= 1'b0;
                end else begin
                    tx_ptr <= tx_ptr + 1'b1;
                    // 1サイクル先読み: バイト59をtready=1で転送する瞬間にtlast=1が
                    // 確定している必要があるため、バイト58の転送確定時点で立てる
                    if (tx_ptr == 7'd58) tx_tlast <= 1'b1;
                end
            end
        end

        endcase
    end
end

endmodule
`default_nettype wire
