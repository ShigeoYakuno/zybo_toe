`default_nettype none
// ===========================================================================
// tx_buffer.sv — TCP送信バッファ（8KB循環バッファ）
//
// 機能概要:
//   TCPの送信データを蓄積するための8KB循環バッファ。
//   ARM PSからの書き込みと、TCP再送に対応した送信ポインタ管理を実装する。
//   xpm_memory_tdpram（Xilinx Primitive: 真デュアルポートBRAM）を使用。
//
// ポインタ方式（3ポインタ）:
//   wr_ptr   : アプリケーション（ARM PS）が書き込む位置
//   send_ptr : TCP エンジンが次に送信するバイト位置
//   ack_ptr  : ACK確認済みの最古バイト位置（ここまでは解放済み）
//
// バッファ使用量:
//   used = wr_ptr - ack_ptr（ACK未確認の書き込み済みバイト数）
//   free = DEPTH - used
//   wr_full は free が DEPTH/4 以下になると ほぼ満杯としてアサート
//
// 再送機能:
//   retrans_req がアサートされると send_ptr が ack_ptr にリセットされ、
//   ACK未確認のデータを再送する。
//
// 送信フロー:
//   1. tcp_state_ctrl が send_req + send_len をアサート
//   2. tx_buffer が send_ptr から send_len バイトを rd_data/rd_valid でストリーミング
//   3. セグメント末尾で rd_last をアサート
//   4. ACK受信時に ack_advance + ack_delta で ack_ptr を進める
//
// パラメータ:
//   DEPTH_LOG2 : バッファ深さのlog2（デフォルト13 → 8192バイト）
// ===========================================================================

module tx_buffer #(
    parameter  DEPTH_LOG2 = 13    // バッファ深さ: 2^13 = 8192バイト（8KB）
)(
    input  wire        clk,    // システムクロック
    input  wire        rst_n,  // 非同期リセット（負論理）

    // ---- アプリケーション書き込みインタフェース（AXI非同期FIFOから） ----------
    input  wire [7:0]  wr_data,    // 書き込みデータ（1バイト）
    input  wire        wr_en,      // 書き込みイネーブル
    output logic        wr_full,   // ほぼ満杯フラグ（ARMへのフロー制御）
    output logic [13:0] wr_count,  // バッファ使用バイト数（TX_COUNTレジスタ用）

    // ---- TCPエンジン送信制御インタフェース --------------------------------------
    input  wire        send_req,   // 送信開始要求（1サイクルパルス）
    input  wire [10:0] send_len,   // 送信するセグメントのバイト数
    output logic        send_busy, // 送信中フラグ（ストリーミング中はアサート）
    output logic [7:0]  rd_data,   // 読み出しデータ（ストリーミング出力）
    output logic        rd_valid,  // 読み出しデータ有効
    output logic        rd_last,   // セグメント末尾フラグ

    // ---- ACK進め制御（tcp_state_ctrlから） ------------------------------------
    input  wire        ack_advance,  // ACKポインタ進め要求（1サイクルパルス）
    input  wire [10:0] ack_delta,    // 今回ACKされたバイト数

    // ---- 再送制御（tcp_state_ctrlから） ----------------------------------------
    input  wire        retrans_req   // 再送要求（send_ptrをack_ptrにリセット）
);

localparam DEPTH = 1 << DEPTH_LOG2;  // バッファ深さ = 8192バイト

// ---------------------------------------------------------------------------
// 3ポインタ（ラップアラウンド算術演算）
// ---------------------------------------------------------------------------
logic [DEPTH_LOG2-1:0] wr_ptr   = '0;  // 次の書き込み先アドレス
logic [DEPTH_LOG2-1:0] ack_ptr  = '0;  // ACK確認済み最古バイトのアドレス
logic [DEPTH_LOG2-1:0] send_ptr = '0;  // 次に送信するバイトのアドレス

// バッファ使用量: wr_ptr - ack_ptr（ラップアラウンドに対応した差分計算）
logic [DEPTH_LOG2:0] used;
assign used = {1'b0, wr_ptr} - {1'b0, ack_ptr};

// バッファ空き容量
logic [DEPTH_LOG2:0] free;
assign free = DEPTH[DEPTH_LOG2:0] - used;
// ほぼ満杯判定: 空き容量が全体の25%以下になったらwr_fullをアサート
assign wr_full  = (free <= (DEPTH >> 2));
assign wr_count = used[DEPTH_LOG2-1:0];  // 使用量をカウントレジスタに出力

// ---------------------------------------------------------------------------
// XPM真デュアルポートBRAM
// ポートA: 書き込みポート（wr_ptr アドレスにwr_dataを書き込む）
// ポートB: 読み出しポート（rd_addr_r アドレスからbram_dout_bを読み出す）
// 共通クロック（同一クロックドメイン）使用
// ---------------------------------------------------------------------------
logic [7:0] bram_dout_b;                  // BRAMポートBの読み出しデータ
logic [DEPTH_LOG2-1:0] rd_addr_r = '0;   // BRAMポートBの読み出しアドレス

xpm_memory_tdpram #(
    .ADDR_WIDTH_A       (DEPTH_LOG2),
    .ADDR_WIDTH_B       (DEPTH_LOG2),
    .BYTE_WRITE_WIDTH_A (8),
    .BYTE_WRITE_WIDTH_B (8),
    .CLOCKING_MODE      ("common_clock"),  // 両ポート同一クロック
    .MEMORY_PRIMITIVE   ("block"),         // ブロックRAMを使用
    .MEMORY_SIZE        (DEPTH * 8),       // 8192バイト × 8ビット
    .READ_LATENCY_A     (1),               // ポートA読み出し遅延1クロック
    .READ_LATENCY_B     (1),               // ポートB読み出し遅延1クロック
    .WRITE_DATA_WIDTH_A (8),
    .WRITE_DATA_WIDTH_B (8),
    .WRITE_MODE_A       ("no_change"),     // 書き込み時はdoutaを変化させない
    .WRITE_MODE_B       ("no_change"),
    .USE_MEM_INIT       (0)                // 初期化なし
) u_bram (
    .clka  (clk),        .clkb  (clk),
    .addra (wr_ptr),     .addrb (rd_addr_r),   // 書き込み/読み出しアドレス
    .dina  (wr_data),    .dinb  (8'h00),       // 書き込みデータ（ポートBは未使用）
    .wea   (wr_en & ~wr_full),  // 満杯でない場合のみ書き込む
    .web   (1'b0),              // ポートBは読み出し専用
    .ena   (1'b1),       .enb   (1'b1),
    .douta (),           .doutb (bram_dout_b), // ポートBの読み出しデータ
    .rsta  (1'b0),       .rstb  (1'b0),
    .injectdbiterra(1'b0), .injectsbiterra(1'b0),
    .injectdbiterrb(1'b0), .injectsbiterrb(1'b0),
    .regcea(1'b1),       .regceb(1'b1),
    .sleep (1'b0)
);

// ---------------------------------------------------------------------------
// 書き込みポインタ更新
// wr_enがアサートされ、かつバッファが満杯でない場合にwr_ptrをインクリメント
// ---------------------------------------------------------------------------
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        wr_ptr <= '0;
    else if (wr_en && !wr_full)
        wr_ptr <= wr_ptr + 1'b1;
end

// ---------------------------------------------------------------------------
// ACKポインタ更新
// ack_advanceがアサートされるとack_ptrをack_delta分進める（バッファを解放）
// ---------------------------------------------------------------------------
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        ack_ptr <= '0;
    else if (ack_advance)
        ack_ptr <= ack_ptr + {{(DEPTH_LOG2-11){1'b0}}, ack_delta};  // 符号拡張してack_delta分進める
end

// ---------------------------------------------------------------------------
// 送信ステートマシン
// S_IDLE  → send_req受信で送信開始
// S_WAIT  → BRAMの読み出し遅延（1クロック）を吸収する
// S_SEND  → rd_data/rd_validをアサートしてデータを順次ストリーミング出力
// ---------------------------------------------------------------------------
typedef enum logic [1:0] { S_IDLE, S_WAIT, S_SEND } state_t;
state_t state = S_IDLE;
logic [10:0] cnt;  // 残り送信バイトカウンタ

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state    <= S_IDLE;
        send_ptr <= '0;
        cnt      <= '0;
        rd_valid <= 1'b0;
        rd_last  <= 1'b0;
        send_busy <= 1'b0;
    end else begin
        rd_valid  <= 1'b0;  // 毎サイクルクリア
        rd_last   <= 1'b0;  // 毎サイクルクリア

        // 再送要求: send_ptrをack_ptrに戻す（未ACKのデータを再送するため）
        if (retrans_req)
            send_ptr <= ack_ptr;

        case (state)
        S_IDLE: begin
            send_busy <= 1'b0;
            if (send_req && send_len != '0) begin
                // 送信要求受信: 残バイト数をセットしてBRAM読み出し開始
                cnt       <= send_len - 1'b1;  // 1バイト目はここでアドレス発行済みなので-1
                rd_addr_r <= send_ptr;          // BRAMポートBのアドレスをセット
                send_ptr  <= send_ptr + 1'b1;   // 次バイトのsend_ptrを準備
                send_busy <= 1'b1;
                state     <= S_WAIT;  // BRAM読み出し遅延1サイクルを待つ
            end
        end
        S_WAIT: begin
            // BRAMの1クロック読み出し遅延を吸収するダミーサイクル
            // このサイクルでアドレスを発行し続けることで次のS_SENDでデータが出る
            rd_addr_r <= send_ptr;
            send_ptr  <= send_ptr + 1'b1;
            state     <= S_SEND;
        end
        S_SEND: begin
            // BRAMからのデータをrd_dataとして出力
            rd_data  <= bram_dout_b;
            rd_valid <= 1'b1;  // データ有効
            if (cnt == '0) begin
                // 最終バイト: rd_lastをアサートして完了
                rd_last   <= 1'b1;
                send_busy <= 1'b0;
                state     <= S_IDLE;
            end else begin
                // 次バイトのアドレスを発行（BRAMの1クロック遅延分先行して発行）
                cnt       <= cnt - 1'b1;
                rd_addr_r <= send_ptr;
                send_ptr  <= send_ptr + 1'b1;
            end
        end
        endcase
    end
end

endmodule
`default_nettype wire
