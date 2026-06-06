`default_nettype none
// 改版履歴:
//   rev2 2026-06-03  byte_cnt=19のNBAタイミングバグ修正:
//                    (1) ip_csum_validがNBA未コミットのip_csumを参照し常にfalseになっていた
//                        → 奇数末尾バイトで既に計算済みのsum変数の折り畳みに変更
//                    (2) ps_sumがNBA未確定のcap_dst_ip[7:0]とcap_payload_lenを使用していた
//                        → rx_tdata(dst_ip最終バイト)とtcp_len_val(blocking変数)に変更
//   rev1 2026-06-03  中間バイトのrx_tuser蓄積を削除: mii_mac_rxがtlast以外で常にtuser=1を
//                    出すためcrc_errが常に1となり全TCPパケットが棄却されていた。
//                    arp_engine rev3と同じ修正。CRCはtlast時のrx_tuserのみで判定する。
//
// ===========================================================================
// tcp_rx_hdr_dec.sv — TCP受信ヘッダデコーダ
//
// 機能概要:
//   frame_muxからEthernetフレームをバイトストリームとして受信し、
//   Ethernet/IP/TCPヘッダを解析・検証してtcp_state_ctrlに通知する。
//   有効なペイロードはrx_bufferに書き込む。
//
// 検証項目（全て通過した場合のみpkt_valid=1を出力）:
//   - MACレイヤ: 宛先MAC == local_mac, 送信元MAC == remote_mac
//   - Ethernetレイヤ: EtherType == 0x0800（IPv4）
//   - IPレイヤ: プロトコル番号 == 6（TCP）, 宛先IP == local_ip, 送信元IP == remote_ip
//   - TCPレイヤ: 宛先ポート == local_port, 送信元ポート == remote_port
//   - CRCエラーなし（rx_tuser == 0）
//   - IPチェックサム: 正常（合計 == 0xFFFF）
//   - TCPチェックサム: 正常（合計 == 0xFFFF）
//
// 処理の流れ:
//   バイトカウンタと状態機械でフレームを解析:
//   S_ETH（Ethernetヘッダ: 0-13バイト目）
//     → S_IP（IPヘッダ: 14バイト目以降）
//       → S_TCP_HDR（TCPヘッダ: 20バイト）
//         → S_PAYLOAD（ペイロード: rx_bufferへ書き込み）
//           → S_DRAIN（フレーム末尾まで読み捨て）
//
// チェックサム計算:
//   IPチェックサム: IPヘッダの偶数バイト位置で16ビットワードを積算
//   TCPチェックサム: TCP疑似ヘッダ + TCPヘッダ + ペイロードを積算
// ===========================================================================

module tcp_rx_hdr_dec (
    input  wire        clk,    // システムクロック
    input  wire        rst_n,  // 非同期リセット（負論理）

    // ---- RXバイトストリーム（frame_mux からのIPフレームのみ） ---------------
    input  wire [7:0]  rx_tdata,   // 受信データ（1バイト）
    input  wire        rx_tvalid,  // 受信データ有効
    input  wire        rx_tlast,   // フレーム末尾
    input  wire        rx_tuser,   // エラーフラグ（1 = CRC不一致）

    // ---- 期待するアドレス（tcp_state_ctrl / axi4lite_regsから） ---------------
    input  wire [47:0] local_mac,   // ローカルMACアドレス（宛先として期待）
    input  wire [47:0] remote_mac,  // リモートMACアドレス（送信元として期待）
    input  wire [31:0] local_ip,    // ローカルIPアドレス
    input  wire [31:0] remote_ip,   // リモートIPアドレス
    input  wire [15:0] local_port,  // ローカルTCPポート番号
    input  wire [15:0] remote_port, // リモートTCPポート番号
    input  wire        addr_valid,  // アドレスが設定済みフラグ

    // ---- デコード結果（tcp_state_ctrlへ） -------------------------------------
    output logic        pkt_valid,       // 有効パケット受信フラグ（1サイクルパルス）
    output logic        rx_syn,          // SYNフラグ
    output logic        rx_ack,          // ACKフラグ
    output logic        rx_fin,          // FINフラグ
    output logic        rx_rst,          // RSTフラグ
    output logic [31:0] rx_seq_num,      // 受信シーケンス番号
    output logic [31:0] rx_ack_num,      // 受信ACK番号
    output logic [15:0] rx_win_size,     // 受信ウィンドウサイズ
    output logic [15:0] rx_payload_len,  // ペイロード長（バイト）

    // ---- ペイロード → rx_buffer ----------------------------------------------
    output logic [7:0]  pl_data,   // ペイロードデータ（rx_tdataを直接接続）
    output logic        pl_wr_en,  // rx_bufferへの書き込みイネーブル
    input  wire        pl_full    // rx_bufferが満杯フラグ
);

// ---------------------------------------------------------------------------
// バイトカウンタとキャプチャフィールド
// ---------------------------------------------------------------------------
logic [7:0]  byte_cnt = '0;   // 各ヘッダ状態内でのバイト位置カウンタ
logic        crc_err  = 1'b0; // フレーム内でCRCエラーが発生したフラグ

// Ethernetヘッダキャプチャ（バイト0-13）
logic [47:0] cap_dst_mac = '0;   // キャプチャした宛先MACアドレス
logic [47:0] cap_src_mac = '0;   // キャプチャした送信元MACアドレス
logic [15:0] cap_eth_type = '0;  // キャプチャしたEtherType

// IPヘッダキャプチャ（バイト14-33）
logic [3:0]  cap_ihl    = 4'd5;       // IPヘッダ長（32ビットワード数, 通常=5）
logic [15:0] cap_ip_total_len = '0;   // IPトータル長（ヘッダ + ペイロード）
logic [7:0]  cap_ip_proto = '0;       // IPプロトコル番号（TCP=6）
logic [31:0] cap_src_ip = '0;         // 送信元IPアドレス
logic [31:0] cap_dst_ip = '0;         // 宛先IPアドレス
logic [7:0]  ip_hdr_byte = '0;        // 16ビットワード計算用の高バイト保持レジスタ

// TCPヘッダキャプチャ（IHL=5の場合バイト34以降）
logic [15:0] cap_src_port = '0;   // 送信元TCPポート番号
logic [15:0] cap_dst_port = '0;   // 宛先TCPポート番号
logic [31:0] cap_seq_num  = '0;   // TCPシーケンス番号
logic [31:0] cap_ack_num  = '0;   // TCP ACK番号
logic [3:0]  cap_data_off = 4'd5; // TCPデータオフセット（ヘッダ長, 通常=5）
logic [7:0]  cap_flags    = '0;   // TCP制御フラグバイト
logic [15:0] cap_win_size = '0;   // TCPウィンドウサイズ
logic [15:0] cap_payload_len = '0; // TCPペイロード長
logic [7:0]  prev_byte    = '0;   // 16ビットフィールド組み立て用高バイト保持

// ---------------------------------------------------------------------------
// フレーム解析状態機械の状態定義
// ---------------------------------------------------------------------------
typedef enum logic [2:0] {
    S_ETH,     // Ethernetヘッダ解析中（バイト0-13）
    S_IP,      // IPヘッダ解析中
    S_TCP_HDR, // TCPヘッダ解析中（20バイト）
    S_PAYLOAD, // TCPペイロード受信中（rx_bufferへ書き込み）
    S_DRAIN    // フレーム末尾まで読み捨て（無効フレームの場合）
} state_t;
state_t state = S_ETH;

// TCPヘッダ開始バイト位置: 14 + IHL*4（IHLはIPヘッダ長ワード数）
logic [7:0] tcp_start;
assign tcp_start = 8'd14 + {4'h0, cap_ihl, 2'b00};

// TCPペイロード開始バイト位置: tcp_start + data_off*4
logic [7:0] pl_start;
assign pl_start = tcp_start + {4'h0, cap_data_off, 2'b00};

// ペイロードのrx_bufferへの書き込み（S_PAYLOAD状態でCRCエラーなし・バッファ未満杯時）
assign pl_wr_en = rx_tvalid && (state == S_PAYLOAD) && !crc_err && !pl_full;
assign pl_data  = rx_tdata;  // ペイロードデータはrx_tdataをそのまま接続

// チェックサム計算用の一時変数は always_ff 内で automatic 宣言する。
// モジュールレベルに置くと always_ff 内ブロッキング代入(=)で
// VivadoがFFとして合成し計算結果が1クロック遅延するバグが生じる。

// ---------------------------------------------------------------------------
// IPチェックサム（1の補数加算）
// IPヘッダバイトを2バイトずつ加算し、最終値が0xFFFFであれば正常
// ---------------------------------------------------------------------------
logic [16:0] ip_csum  = '0;     // IPチェックサム累積値（17ビット: キャリー含む）
logic        ip_csum_valid = 1'b0;  // IPチェックサム正常フラグ

// ---------------------------------------------------------------------------
// TCPチェックサム（疑似ヘッダ + TCPヘッダ + ペイロードの1の補数加算）
// 最終値が0xFFFFであれば正常
// ---------------------------------------------------------------------------
logic [16:0] tcp_csum = '0;     // TCPチェックサム累積値（17ビット）
logic        tcp_phase = 1'b0;  // 0=高バイト待ち, 1=低バイト待ち（16ビットワード組み立て）
logic        tcp_csum_valid = 1'b0;  // TCPチェックサム正常フラグ

// ---------------------------------------------------------------------------
// メインバイト処理（always_ffブロック）
// rx_tvalidがアサートされるたびに1バイト処理する
// ---------------------------------------------------------------------------
always_ff @(posedge clk or negedge rst_n) begin
    // always_ff内のローカル計算用一時変数（automaticにより組み合わせ回路として合成される）
    automatic logic [16:0] sum;          // 16ビット加算結果（キャリービット含む17ビット）
    automatic logic [15:0] tcp_len_val;  // TCPセグメント長計算用
    automatic logic [31:0] ps_sum;       // TCP疑似ヘッダ合計（32ビット）
    if (!rst_n) begin
        byte_cnt     <= '0;
        state        <= S_ETH;
        crc_err      <= 1'b0;
        pkt_valid    <= 1'b0;
        cap_payload_len <= '0;
        ip_csum      <= '0;
        tcp_csum     <= '0;
        tcp_phase    <= 1'b0;
    end else begin
        pkt_valid <= 1'b0;  // 毎サイクルクリア（tlast時のみアサート）

        if (rx_tvalid) begin
            // mii_mac_rxはtlast以外で常にtuser=1を出すため中間バイトのtuserは無視する
            // CRCエラーはrx_tlast時のrx_tuserのみで判定する (L346)
            prev_byte <= rx_tdata;           // 16ビットフィールド用に前バイトを保持

            case (state)

            // ----------------------------------------------------------------
            // Ethernetヘッダ解析（バイト0-13）
            // 宛先MAC、送信元MAC、EtherTypeをキャプチャする
            // ----------------------------------------------------------------
            S_ETH: begin
                case (byte_cnt)
                    // 宛先MACアドレス（バイト0-5）
                    8'd0: cap_dst_mac[47:40] <= rx_tdata;
                    8'd1: cap_dst_mac[39:32] <= rx_tdata;
                    8'd2: cap_dst_mac[31:24] <= rx_tdata;
                    8'd3: cap_dst_mac[23:16] <= rx_tdata;
                    8'd4: cap_dst_mac[15:8]  <= rx_tdata;
                    8'd5: cap_dst_mac[7:0]   <= rx_tdata;
                    // 送信元MACアドレス（バイト6-11）
                    8'd6:  cap_src_mac[47:40] <= rx_tdata;
                    8'd7:  cap_src_mac[39:32] <= rx_tdata;
                    8'd8:  cap_src_mac[31:24] <= rx_tdata;
                    8'd9:  cap_src_mac[23:16] <= rx_tdata;
                    8'd10: cap_src_mac[15:8]  <= rx_tdata;
                    8'd11: cap_src_mac[7:0]   <= rx_tdata;
                    // EtherType（バイト12-13）
                    8'd12: cap_eth_type[15:8] <= rx_tdata;
                    8'd13: begin
                        cap_eth_type[7:0] <= rx_tdata;
                        // IPヘッダ処理開始前にチェックサムアキュムレータをリセット
                        ip_csum  <= '0;
                        tcp_csum <= '0;
                    end
                    default: ;
                endcase
                if (byte_cnt == 8'd13) begin
                    state     <= S_IP;  // Ethernetヘッダ完了 → IPヘッダへ
                    byte_cnt  <= '0;    // IPヘッダ内バイトカウントを0にリセット
                end else
                    byte_cnt <= byte_cnt + 1'b1;
            end

            // ----------------------------------------------------------------
            // IPヘッダ解析（Ethヘッダ後、byte_cnt=0からの相対位置）
            // IHL、トータル長、プロトコル番号、送信元/宛先IPをキャプチャ
            // IPチェックサムも2バイトずつ積算する
            // ----------------------------------------------------------------
            S_IP: begin
                case (byte_cnt)
                    8'd0: begin
                        cap_ihl           <= rx_tdata[3:0];  // IPヘッダ長（ワード数）
                        tcp_csum <= '0;  // TCPチェックサムをリセット
                    end
                    8'd2:  cap_ip_total_len[15:8] <= rx_tdata;  // IPトータル長（高バイト）
                    8'd3:  cap_ip_total_len[7:0]  <= rx_tdata;  // IPトータル長（低バイト）
                    8'd9:  cap_ip_proto           <= rx_tdata;  // プロトコル番号（TCP=6）
                    8'd12: cap_src_ip[31:24] <= rx_tdata;
                    8'd13: cap_src_ip[23:16] <= rx_tdata;
                    8'd14: cap_src_ip[15:8]  <= rx_tdata;
                    8'd15: cap_src_ip[7:0]   <= rx_tdata;       // 送信元IPアドレス
                    8'd16: cap_dst_ip[31:24] <= rx_tdata;
                    8'd17: cap_dst_ip[23:16] <= rx_tdata;
                    8'd18: cap_dst_ip[15:8]  <= rx_tdata;
                    8'd19: begin
                        cap_dst_ip[7:0] <= rx_tdata;            // 宛先IPアドレス
                        // TCPペイロード長を計算: IPトータル長 - IPヘッダ長 - TCPヘッダ長(20)
                        tcp_len_val = cap_ip_total_len - {6'h0, cap_ihl, 2'b00};
                        cap_payload_len <= tcp_len_val - 16'd20;  // TCPヘッダ20バイトを除いた長さ
                    end
                    default: ;
                endcase

                // IPヘッダバイトを2バイトごとに16ビットワードとして1の補数加算
                if (byte_cnt[0] == 1'b0) begin  // 偶数バイト: 高バイトを保存
                    ip_hdr_byte <= rx_tdata;
                end else begin  // 奇数バイト: {高バイト, 低バイト}として加算
                    sum     = ip_csum + {1'b0, ip_hdr_byte, rx_tdata};
                    ip_csum <= {1'b0, sum[15:0]} + {16'h0, sum[16]};  // キャリーを折り込む
                end

                // IPヘッダ末尾でTCPヘッダへ遷移（IHL*4-1バイト目）
                if (byte_cnt == ({4'h0, cap_ihl, 2'b00} - 8'd1)) begin
                    // IPチェックサム検証: byte_cnt=19は奇数バイトのため sum に最終ワード込み
                    // ip_csumはNBAで未コミットなのでsumの折り畳み結果を直接使う
                    ip_csum_valid <= ({1'b0, sum[15:0]} + {16'h0, sum[16]} == 17'h0FFFF);
                    // TCP疑似ヘッダのチェックサム寄与を計算してシード値とする
                    // 疑似ヘッダ: 送信元IP + 宛先IP + プロトコル(6) + TCPセグメント長
                    // cap_dst_ip[7:0]とcap_payload_lenはNBA未コミットのため直接値を使う
                    ps_sum = {16'h0, cap_src_ip[31:16]}
                           + {16'h0, cap_src_ip[15:0]}
                           + {16'h0, cap_dst_ip[31:16]}
                           + {16'h0, cap_dst_ip[15:8], rx_tdata}  // [7:0]はNBA未確定→rx_tdata
                           + 32'h0000_0006                         // プロトコル番号=TCP(6)
                           + {16'h0, tcp_len_val};                 // NBA未確定→blocking変数を使う
                    // 32ビット合計を17ビットに折り畳んでTCPチェックサムの初期値とする
                    tcp_csum <= {1'b0, ps_sum[15:0]} + {16'h0, ps_sum[16:16]}
                              + {16'h0, ps_sum[17:17]};
                    tcp_phase <= 1'b0;
                    state    <= S_TCP_HDR;  // TCPヘッダ解析へ
                    byte_cnt <= '0;
                end else
                    byte_cnt <= byte_cnt + 1'b1;
            end

            // ----------------------------------------------------------------
            // TCPヘッダ解析（20バイト, byte_cnt=0からの相対位置）
            // ポート番号、シーケンス番号、ACK番号、フラグ等をキャプチャ
            // TCPチェックサム計算も継続する
            // ----------------------------------------------------------------
            S_TCP_HDR: begin
                case (byte_cnt)
                    8'd0:  cap_src_port[15:8] <= rx_tdata;  // 送信元ポート（高バイト）
                    8'd1:  cap_src_port[7:0]  <= rx_tdata;  // 送信元ポート（低バイト）
                    8'd2:  cap_dst_port[15:8] <= rx_tdata;  // 宛先ポート（高バイト）
                    8'd3:  cap_dst_port[7:0]  <= rx_tdata;  // 宛先ポート（低バイト）
                    8'd4:  cap_seq_num[31:24] <= rx_tdata;  // シーケンス番号 [31:24]
                    8'd5:  cap_seq_num[23:16] <= rx_tdata;  // シーケンス番号 [23:16]
                    8'd6:  cap_seq_num[15:8]  <= rx_tdata;  // シーケンス番号 [15:8]
                    8'd7:  cap_seq_num[7:0]   <= rx_tdata;  // シーケンス番号 [7:0]
                    8'd8:  cap_ack_num[31:24] <= rx_tdata;  // ACK番号 [31:24]
                    8'd9:  cap_ack_num[23:16] <= rx_tdata;  // ACK番号 [23:16]
                    8'd10: cap_ack_num[15:8]  <= rx_tdata;  // ACK番号 [15:8]
                    8'd11: cap_ack_num[7:0]   <= rx_tdata;  // ACK番号 [7:0]
                    8'd12: cap_data_off        <= rx_tdata[7:4];  // データオフセット（ヘッダ長）
                    8'd13: cap_flags           <= rx_tdata;       // TCP制御フラグバイト
                    8'd14: cap_win_size[15:8]  <= rx_tdata;  // ウィンドウサイズ（高バイト）
                    8'd15: cap_win_size[7:0]   <= rx_tdata;  // ウィンドウサイズ（低バイト）
                    // バイト16-17: TCPチェックサム（チェックサム計算対象に含める）
                    // バイト18-19: 緊急ポインタ（TCPチェックサムに含める）
                    default: ;
                endcase

                // TCPチェックサム: TCPヘッダバイトを2バイトごとに加算
                if (tcp_phase == 1'b0) begin
                    ip_hdr_byte <= rx_tdata;  // 高バイトを保存
                    tcp_phase   <= 1'b1;
                end else begin
                    sum      = tcp_csum + {1'b0, ip_hdr_byte, rx_tdata};
                    tcp_csum <= {1'b0, sum[15:0]} + {16'h0, sum[16]};  // キャリー折り込み
                    tcp_phase <= 1'b0;
                end

                // 固定20バイトのTCPヘッダ解析完了
                if (byte_cnt == 8'd19) begin
                    // ペイロード長が0なら読み捨て（DRAIN）、あれば受信（PAYLOAD）へ
                    state    <= (cap_payload_len == '0) ? S_DRAIN : S_PAYLOAD;
                    byte_cnt <= '0;
                end else
                    byte_cnt <= byte_cnt + 1'b1;
            end

            // ----------------------------------------------------------------
            // ペイロード受信（rx_bufferへの書き込みはpl_wr_en/pl_dataで行う）
            // チェックサム計算を継続する
            // ----------------------------------------------------------------
            S_PAYLOAD: begin
                // ペイロードバイトをTCPチェックサムに加算
                if (tcp_phase == 1'b0) begin
                    ip_hdr_byte <= rx_tdata;  // 高バイトを保存
                    tcp_phase   <= 1'b1;
                end else begin
                    sum      = tcp_csum + {1'b0, ip_hdr_byte, rx_tdata};
                    tcp_csum <= {1'b0, sum[15:0]} + {16'h0, sum[16]};
                    tcp_phase <= 1'b0;
                end
                if (rx_tlast) state <= S_DRAIN;  // フレーム末尾でDRAINへ
            end

            S_DRAIN: ;  // フレーム末尾(tlast)に達するまでバイトを読み捨て

            endcase

            // ----------------------------------------------------------------
            // フレーム末尾（tlast）処理
            // チェックサム最終処理とパケット有効性の判定を行う
            // ----------------------------------------------------------------
            if (rx_tlast) begin
                // ペイロードが奇数バイトで終わった場合: ゼロパディングして最終ワードを加算
                if (tcp_phase && state == S_PAYLOAD) begin
                    sum      = tcp_csum + {1'b0, ip_hdr_byte, 8'h00};  // 低バイトをゼロ補完
                    tcp_csum <= {1'b0, sum[15:0]} + {16'h0, sum[16]};
                end
                tcp_csum_valid <= (tcp_csum == 17'h0FFFF);  // TCPチェックサム検証

                // 全検証項目をチェックして有効なTCPパケットかどうかを判定
                if (!crc_err && !rx_tuser             // CRCエラーなし (tuserはtlast時の最終CRC結果)
                    && cap_eth_type  == 16'h0800      // EtherType = IPv4
                    && cap_ip_proto  == 8'd6          // IPプロトコル = TCP
                    && addr_valid                     // アドレスが設定済み
                    && cap_dst_mac   == local_mac     // 宛先MAC一致
                    && cap_src_mac   == remote_mac    // 送信元MAC一致
                    && cap_dst_ip    == local_ip      // 宛先IP一致
                    && cap_src_ip    == remote_ip     // 送信元IP一致
                    && cap_dst_port  == local_port    // 宛先ポート一致
                    && cap_src_port  == remote_port   // 送信元ポート一致
                    && ip_csum_valid                  // IPチェックサム正常
                    && (tcp_csum == 17'h0FFFF)) begin // TCPチェックサム正常

                    // 全検証通過: デコード結果をtcp_state_ctrlに出力
                    pkt_valid       <= 1'b1;
                    rx_syn          <= cap_flags[1];  // SYNフラグ
                    rx_ack          <= cap_flags[4];  // ACKフラグ
                    rx_fin          <= cap_flags[0];  // FINフラグ
                    rx_rst          <= cap_flags[2];  // RSTフラグ
                    rx_seq_num      <= cap_seq_num;   // シーケンス番号
                    rx_ack_num      <= cap_ack_num;   // ACK番号
                    rx_win_size     <= cap_win_size;  // ウィンドウサイズ
                    rx_payload_len  <= cap_payload_len; // ペイロード長
                end

                // 次フレームの処理に備えて全フラグ・カウンタをリセット
                state    <= S_ETH;
                byte_cnt <= '0;
                crc_err  <= 1'b0;
                ip_csum  <= '0;
                tcp_csum <= '0;
                tcp_phase <= 1'b0;
            end
        end  // rx_tvalid
    end
end

endmodule
`default_nettype wire
