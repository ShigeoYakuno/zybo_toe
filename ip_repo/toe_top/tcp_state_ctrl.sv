`default_nettype none
// 改版履歴:
//   rev1 2026-06-01  tx_busy自己クリアのデッドコード削除: tx_req_pendingが常に0のため
//                    tx_busyが1サイクルで消えていた。tcp_layer側の多重ドライバ修正と合わせて対処
//
// ===========================================================================
// tcp_state_ctrl.sv — TCP状態機械（ステートマシン）
//
// 機能概要:
//   RFC 793に基づくTCP接続管理を行うステートマシン。
//   Active Open（能動的接続開始）のみサポート（Passive Openは非対応）。
//
// 管理する状態（STATUSレジスタ経由でARMに公開）:
//   0=CLOSED      : 未接続
//   1=SYN_SENT    : SYN送信済み、SYN-ACK待ち
//   2=ESTABLISHED : 接続確立、データ転送可能
//   3=FIN_WAIT_1  : FIN送信済み、ACK待ち
//   4=FIN_WAIT_2  : FINのACK受信済み、リモートのFIN待ち
//   5=TIME_WAIT   : 2MSL待機（FIN-ACK後の待機期間）
//   6=CLOSE_WAIT  : リモートからFIN受信、アプリのclose待ち
//   7=LAST_ACK    : FIN送信済み、最終ACK待ち
//
// タイムアウト（50MHzクロック基準）:
//   SYN_SENT タイムアウト : 3秒    = 150,000,000クロック
//   2MSL（TIME_WAIT）     : 100ms  = 5,000,000クロック
//   再送タイムアウト       : 200ms  = 10,000,000クロック
//
// 主要な動作:
//   - ARMからの connect_req 立ち上がりでSYN送信、SYN_SENTへ遷移
//   - SYN-ACK受信でACK送信、ESTABLISHEDへ遷移（接続確立）
//   - データ受信でACK送信（受信ペイロードはrx_bufferへ）
//   - ARMからの disconnect_req 立ち上がりでFIN+ACK送信、FIN_WAIT_1へ遷移
//   - リモートからFIN受信でCLOSE_WAIT遷移し、ARMのdisconnect_reqでFIN送信
//   - RSTパケット受信で即時CLOSEDへ
//   - 再送タイムアウト時にretrans_reqをアサートしてtx_bufferに再送を指示
// ===========================================================================

module tcp_state_ctrl #(
    parameter CLK_HZ       = 50_000_000,
    parameter SYN_TIMEOUT  = CLK_HZ * 3,       // SYN_SENTタイムアウト: 3秒
    parameter TWAIT_TIMEOUT = CLK_HZ / 10,     // TIME_WAITタイムアウト: 100ms（2MSL）
    parameter RETX_TIMEOUT  = CLK_HZ / 5       // 再送タイムアウト: 200ms
)(
    input  wire        clk,    // システムクロック（50MHz）
    input  wire        rst_n,  // 非同期リセット（負論理）

    // ---- ARM PSからの制御信号（AXIドメインから同期済み） -------------------
    input  wire        connect_req,     // 接続開始要求（立ち上がりエッジで動作）
    input  wire        disconnect_req,  // 切断要求（立ち上がりエッジで動作）

    // ---- RXパス入力（tcp_rx_hdr_decからのデコード結果） ----------------------
    input  wire        pkt_valid,       // 有効なTCPパケット受信（1サイクルパルス）
    input  wire        rx_syn,          // SYNフラグ
    input  wire        rx_ack,          // ACKフラグ
    input  wire        rx_fin,          // FINフラグ
    input  wire        rx_rst,          // RSTフラグ（接続リセット）
    input  wire [31:0] rx_seq_num,      // リモートのシーケンス番号
    input  wire [31:0] rx_ack_num,      // リモートのACK番号（こちらの送信分）
    input  wire [15:0] rx_win_size,     // リモートの受信ウィンドウサイズ
    input  wire [15:0] rx_payload_len,  // 受信ペイロード長（バイト）

    // ---- LFSRからのISN（初期シーケンス番号） -----------------------------------
    input  wire [31:0] isn,             // SYN送信時にラッチする初期シーケンス番号

    // ---- TX制御出力（tcp_hdr_genへ） -----------------------------------------
    output logic        tx_send_req,     // 送信要求（1サイクルパルス）
    output logic [8:0]  tx_flags,        // TCP制御フラグ: NS|CWR|ECE|URG|ACK|PSH|RST|SYN|FIN
    output logic [31:0] tx_seq_num,      // 送信シーケンス番号
    output logic [31:0] tx_ack_num,      // 送信ACK番号
    output logic [10:0] tx_payload_len,  // ペイロード長（制御パケットは0）
    output logic        tx_payload_en,   // tx_bufferからペイロードを取得するフラグ
    output logic        tx_busy,         // tcp_hdr_genが動作中フラグ

    // ---- 再送制御出力（tx_bufferへ） -------------------------------------------
    output logic        retrans_req,     // 再送要求（send_ptrをack_ptrにリセット）
    output logic        ack_advance,     // ACKポインタ進め要求
    output logic [10:0] ack_delta,       // ACKされたバイト数

    // ---- ステータス出力（axi4lite_regs, clk_50ドメイン） ----------------------
    output logic [3:0]  tcp_state,       // TCP状態番号（STATUSレジスタへ）
    output logic        irq              // 状態変化割り込み（1サイクルパルス）
);

// ---------------------------------------------------------------------------
// TCP状態の列挙型定義
// ---------------------------------------------------------------------------
typedef enum logic [3:0] {
    ST_CLOSED      = 4'd0,  // 未接続
    ST_SYN_SENT    = 4'd1,  // SYN送信済み
    ST_ESTABLISHED = 4'd2,  // 接続確立
    ST_FIN_WAIT_1  = 4'd3,  // FIN送信済み（ACK待ち）
    ST_FIN_WAIT_2  = 4'd4,  // FINのACK受信済み（リモートFIN待ち）
    ST_TIME_WAIT   = 4'd5,  // 2MSL待機中
    ST_CLOSE_WAIT  = 4'd6,  // リモートFIN受信済み（アプリclose待ち）
    ST_LAST_ACK    = 4'd7   // 最終ACK待ち
} state_t;

state_t state     = ST_CLOSED;  // 現在の状態
state_t state_r   = ST_CLOSED;  // 前クロックの状態（状態変化検出用）

// tcp_stateとして外部に公開（axi4lite_regsのSTATUSレジスタへ）
assign tcp_state = state[3:0];

// ---------------------------------------------------------------------------
// 割り込み生成: 状態が変化したときに1サイクルのIRQパルスを出力する
// ---------------------------------------------------------------------------
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_CLOSED;
        irq     <= 1'b0;
    end else begin
        state_r <= state;
        irq     <= (state != state_r);  // 状態変化時にIRQパルスを出力
    end
end

// ---------------------------------------------------------------------------
// シーケンス番号管理
// local_seq: こちらが次に送信するシーケンス番号
// local_ack: こちらがリモートに期待する次のシーケンス番号（= 送信するACK番号）
// remote_win: リモートの受信ウィンドウサイズ
// ---------------------------------------------------------------------------
logic [31:0] local_seq;   // こちらの次送信シーケンス番号
logic [31:0] local_ack;   // こちらのACK番号（リモートの次期待シーケンス番号）
logic [15:0] remote_win;  // リモートの受信ウィンドウサイズ

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        local_ack  <= '0;
        remote_win <= 16'd4096;
    end else begin
        if (pkt_valid) begin
            remote_win <= rx_win_size;  // リモートウィンドウを更新
            // ACK番号の更新: 期待次シーケンス = リモートのseq + ペイロード長
            // SYNまたはFINは1バイト分のシーケンス番号を消費する
            if (rx_syn || rx_fin)
                local_ack <= rx_seq_num + 32'd1 + {16'h0, rx_payload_len};
            else if (rx_payload_len != '0)
                local_ack <= rx_seq_num + {16'h0, rx_payload_len};
        end
    end
end

// ---------------------------------------------------------------------------
// タイマー（SYN_SENT タイムアウト / TIME_WAIT 2MSL タイマー）
// timer_enがアサートされている状態でのみカウントアップする
// ---------------------------------------------------------------------------
logic [27:0] timer = '0;    // 汎用タイマーカウンタ
logic        timer_expire;  // タイムアウト発生フラグ（1サイクルパルス）
logic        timer_en;      // タイマー動作イネーブル

always_ff @(posedge clk or negedge rst_n) begin
    automatic logic [28:0] lim;  // タイムアウト上限値（automatic: 組み合わせ中間値）
    if (!rst_n) begin
        timer        <= '0;
        timer_expire <= 1'b0;
    end else begin
        timer_expire <= 1'b0;
        if (!timer_en) begin
            timer <= '0;  // タイマー無効時はリセット
        end else begin
            // 状態に応じてタイムアウト上限値を選択
            case (state)
                ST_SYN_SENT:  lim = SYN_TIMEOUT[28:0];    // 3秒
                ST_TIME_WAIT: lim = TWAIT_TIMEOUT[28:0];  // 100ms（2MSL）
                default:      lim = RETX_TIMEOUT[28:0];   // 200ms
            endcase
            if (timer == lim[27:0]) begin
                timer        <= '0;
                timer_expire <= 1'b1;  // タイムアウト発生
            end else
                timer <= timer + 1'b1;
        end
    end
end
// タイマーはSYN_SENTとTIME_WAIT状態でのみ動作
assign timer_en = (state == ST_SYN_SENT) || (state == ST_TIME_WAIT);

// ---------------------------------------------------------------------------
// 再送タイマー（ESTABLISHED等のデータ転送状態で動作）
// タイムアウトするとretrans_reqをアサートしてtx_bufferに再送を指示する
// ---------------------------------------------------------------------------
logic [27:0] retx_timer = '0;   // 再送タイマーカウンタ
logic        retx_expire;        // 再送タイムアウト発生フラグ

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        retx_timer <= '0;
        retx_expire <= 1'b0;
    end else begin
        retx_expire <= 1'b0;
        // 再送タイマーはデータ転送中の状態でのみカウントアップ
        if (state == ST_ESTABLISHED || state == ST_FIN_WAIT_1 ||
            state == ST_CLOSE_WAIT  || state == ST_LAST_ACK) begin
            if (retx_timer == RETX_TIMEOUT[27:0]) begin
                retx_timer  <= '0;
                retx_expire <= 1'b1;  // 再送タイムアウト発生
            end else
                retx_timer <= retx_timer + 1'b1;
        end else
            retx_timer <= '0;  // 対象外の状態ではリセット
    end
end

// ---------------------------------------------------------------------------
// TX要求アービタ（送信シリアライズ）
// 同時に複数の送信要求が発生しないよう管理する
// ---------------------------------------------------------------------------
logic tx_req_pending = 1'b0;  // 未処理の送信要求フラグ
logic [8:0]  pend_flags = '0; // 保留中の送信フラグ
logic [10:0] pend_plen  = '0; // 保留中のペイロード長
logic        pend_pload = 1'b0; // 保留中のペイロードフラグ

// ---------------------------------------------------------------------------
// ACKトラッキング（tx_bufferのACKポインタ管理）
// 受信したACK番号からack_deltaを計算し、tx_bufferのack_ptrを進める
// ---------------------------------------------------------------------------
logic [31:0] last_acked = '0;  // 最後にACKされたシーケンス番号

always_ff @(posedge clk or negedge rst_n) begin
    automatic logic [31:0] delta;  // ACKデルタ計算用（automatic: 組み合わせ中間値）
    if (!rst_n) begin
        last_acked  <= '0;
        ack_advance <= 1'b0;
        ack_delta   <= '0;
        retrans_req <= 1'b0;
    end else begin
        ack_advance <= 1'b0;
        retrans_req <= 1'b0;
        // ESTABLISHED状態でACKパケット受信時: 新たにACKされたバイト数を計算
        if (pkt_valid && rx_ack && state == ST_ESTABLISHED) begin
            delta = rx_ack_num - last_acked;  // ACK番号の差分（ラップアラウンド対応）
            if (delta != '0 && delta[31] == 1'b0) begin
                // 有効な前進ACK: tx_bufferのACKポインタを進める
                last_acked  <= rx_ack_num;
                ack_advance <= 1'b1;
                ack_delta   <= delta[10:0];  // ACKされたバイト数
            end
        end
        // 再送タイムアウト: tx_bufferのsend_ptrをack_ptrにリセット
        if (retx_expire && state == ST_ESTABLISHED)
            retrans_req <= 1'b1;
    end
end

// ---------------------------------------------------------------------------
// メイン状態機械
// connect_req/disconnect_reqは立ち上がりエッジを検出して使用する
// ---------------------------------------------------------------------------
logic  connect_req_r = 1'b0, conn_rise;     // connect_req立ち上がり検出用
logic  disconnect_req_r = 1'b0, disc_rise;  // disconnect_req立ち上がり検出用
assign conn_rise = connect_req    && !connect_req_r;   // 立ち上がりエッジ
assign disc_rise = disconnect_req && !disconnect_req_r; // 立ち上がりエッジ

// 前クロックの制御信号を記録
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        connect_req_r    <= 1'b0;
        disconnect_req_r <= 1'b0;
    end else begin
        connect_req_r    <= connect_req;
        disconnect_req_r <= disconnect_req;
    end
end

// ---------------------------------------------------------------------------
// TCP状態遷移ロジック（メイン always_ff ブロック）
// ---------------------------------------------------------------------------
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state          <= ST_CLOSED;
        local_seq      <= '0;
        tx_send_req    <= 1'b0;
        tx_flags       <= '0;
        tx_seq_num     <= '0;
        tx_ack_num     <= '0;
        tx_payload_len <= '0;
        tx_payload_en  <= 1'b0;
        tx_busy        <= 1'b0;
        tx_req_pending <= 1'b0;
    end else begin
        tx_send_req <= 1'b0;  // 送信要求は1サイクルパルスのため毎サイクルクリア

        case (state)

        // ------------------------------------------------------------------
        // CLOSED状態: ARMからの接続要求を待つ
        // ------------------------------------------------------------------
        ST_CLOSED: begin
            if (conn_rise) begin
                local_seq   <= isn;           // ISNをLFSRから取得
                state       <= ST_SYN_SENT;   // SYN_SENT状態へ遷移
                // SYNパケットを送信（SYNフラグのみ: ビット1）
                tx_flags       <= 9'b0_0000_0010;  // SYN
                tx_seq_num     <= isn;
                tx_ack_num     <= '0;          // SYNではACK番号は0
                tx_payload_len <= '0;          // 制御パケットのためペイロードなし
                tx_payload_en  <= 1'b0;
                tx_send_req    <= 1'b1;
                tx_busy        <= 1'b1;
                local_seq      <= isn + 32'd1; // SYNは1バイト分のシーケンスを消費
            end
        end

        // ------------------------------------------------------------------
        // SYN_SENT状態: SYN-ACKを待つ
        // ------------------------------------------------------------------
        ST_SYN_SENT: begin
            if (pkt_valid && rx_syn && rx_ack && !rx_rst) begin
                // SYN-ACK受信: 3-wayハンドシェイク完了 → ESTABLISHEDへ
                state <= ST_ESTABLISHED;
                // ACKパケットを送信
                tx_flags       <= 9'b0_0001_0000;  // ACK
                tx_seq_num     <= local_seq;
                tx_ack_num     <= local_ack;
                tx_payload_len <= '0;
                tx_payload_en  <= 1'b0;
                tx_send_req    <= 1'b1;
                tx_busy        <= 1'b1;
            end else if (pkt_valid && rx_rst) begin
                // RST受信: 即時CLOSEDへ
                state <= ST_CLOSED;
            end else if (timer_expire) begin
                // SYN_SENTタイムアウト（3秒）: 接続断念
                state <= ST_CLOSED;
            end
        end

        // ------------------------------------------------------------------
        // ESTABLISHED状態: データ転送中
        // ------------------------------------------------------------------
        ST_ESTABLISHED: begin
            if (pkt_valid && rx_rst) begin
                // RST受信: 即時CLOSEDへ
                state <= ST_CLOSED;
            end else if (pkt_valid && rx_fin) begin
                // リモートからFIN受信: パッシブクローズ → CLOSE_WAITへ
                state <= ST_CLOSE_WAIT;
                // FINに対するACKを送信
                tx_flags       <= 9'b0_0001_0000;  // ACK
                tx_seq_num     <= local_seq;
                tx_ack_num     <= local_ack;
                tx_payload_len <= '0;
                tx_payload_en  <= 1'b0;
                tx_send_req    <= 1'b1;
                tx_busy        <= 1'b1;
            end else if (disc_rise) begin
                // ARMから切断要求: アクティブクローズ → FIN_WAIT_1へ
                state <= ST_FIN_WAIT_1;
                // FIN+ACKを送信
                tx_flags       <= 9'b0_0001_0001;  // FIN + ACK
                tx_seq_num     <= local_seq;
                tx_ack_num     <= local_ack;
                tx_payload_len <= '0;
                tx_payload_en  <= 1'b0;
                tx_send_req    <= 1'b1;
                tx_busy        <= 1'b1;
                local_seq      <= local_seq + 32'd1;  // FINは1バイト分のシーケンスを消費
            end else if (pkt_valid && rx_ack && rx_payload_len > '0) begin
                // データ受信: ACKを返す（ペイロードはrx_bufferに格納済み）
                tx_flags       <= 9'b0_0001_0000;  // ACK
                tx_seq_num     <= local_seq;
                tx_ack_num     <= local_ack;
                tx_payload_len <= '0;
                tx_payload_en  <= 1'b0;
                tx_send_req    <= 1'b1;
                tx_busy        <= 1'b1;
            end
        end

        // ------------------------------------------------------------------
        // FIN_WAIT_1状態: こちらからFINを送信済み、ACKを待つ
        // ------------------------------------------------------------------
        ST_FIN_WAIT_1: begin
            if (pkt_valid && rx_ack && !rx_fin) begin
                // FINのACKのみ受信: FIN_WAIT_2へ
                state <= ST_FIN_WAIT_2;
            end else if (pkt_valid && rx_fin) begin
                // リモートからFIN（同時クローズ）: TIME_WAITへ
                state <= ST_TIME_WAIT;
                tx_flags       <= 9'b0_0001_0000;  // ACK
                tx_seq_num     <= local_seq;
                tx_ack_num     <= local_ack;
                tx_payload_len <= '0;
                tx_payload_en  <= 1'b0;
                tx_send_req    <= 1'b1;
                tx_busy        <= 1'b1;
            end
        end

        // ------------------------------------------------------------------
        // FIN_WAIT_2状態: FINのACK受信済み、リモートのFINを待つ
        // ------------------------------------------------------------------
        ST_FIN_WAIT_2: begin
            if (pkt_valid && rx_fin) begin
                // リモートからFIN受信: TIME_WAITへ
                state <= ST_TIME_WAIT;
                tx_flags       <= 9'b0_0001_0000;  // ACK
                tx_seq_num     <= local_seq;
                tx_ack_num     <= local_ack;
                tx_payload_len <= '0;
                tx_payload_en  <= 1'b0;
                tx_send_req    <= 1'b1;
                tx_busy        <= 1'b1;
            end
        end

        // ------------------------------------------------------------------
        // TIME_WAIT状態: 2MSL（100ms）待機後にCLOSEDへ
        // 遅延したセグメントが消滅するのを待つ期間
        // ------------------------------------------------------------------
        ST_TIME_WAIT: begin
            if (timer_expire) state <= ST_CLOSED;  // 2MSL経過後にCLOSED
        end

        // ------------------------------------------------------------------
        // CLOSE_WAIT状態: リモートからFINを受信済み、ARMのcloseを待つ
        // ------------------------------------------------------------------
        ST_CLOSE_WAIT: begin
            if (disc_rise) begin
                // ARMから切断要求: LAST_ACKへ
                state <= ST_LAST_ACK;
                // FIN+ACKを送信
                tx_flags       <= 9'b0_0001_0001;  // FIN + ACK
                tx_seq_num     <= local_seq;
                tx_ack_num     <= local_ack;
                tx_payload_len <= '0;
                tx_payload_en  <= 1'b0;
                tx_send_req    <= 1'b1;
                tx_busy        <= 1'b1;
                local_seq      <= local_seq + 32'd1;  // FINは1バイト分のシーケンスを消費
            end
        end

        // ------------------------------------------------------------------
        // LAST_ACK状態: FINを送信済み、最終ACKを待つ
        // ------------------------------------------------------------------
        ST_LAST_ACK: begin
            if (pkt_valid && rx_ack)
                state <= ST_CLOSED;  // 最終ACK受信でCLOSED（接続完全クローズ）
        end

        default: state <= ST_CLOSED;  // 未定義状態のフォールバック
        endcase
    end
end

endmodule
`default_nettype wire
