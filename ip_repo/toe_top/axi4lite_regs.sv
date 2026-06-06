`default_nettype none
// ===========================================================================
// axi4lite_regs.sv — AXI4-Liteスレーブ + クロックドメイン橋渡し（CDC）
//
// 機能概要:
//   PSプロセッサ（s_axi_aclkドメイン）とTCPエンジン（clk_50ドメイン）の間で
//   制御・ステータス・データを受け渡すAXI4-Liteレジスタスレーブ。
//
// レジスタマップ（32ビット、ワードアライン）:
//   0x00  CTRL       [0]=connect_req  [1]=disconnect_req  [2]=arp_req  W/R
//   0x04  STATUS     [3:0]=tcp_state  [4]=irq_pending     [5]=arp_mac_valid  R
//   0x08  LOCAL_MAC_HI  [15:0] = local_mac[47:32]         W/R
//   0x0C  LOCAL_MAC_LO  [31:0] = local_mac[31:0]          W/R
//   0x10  REMOTE_MAC_HI [15:0] = remote_mac[47:32]        W/R
//   0x14  REMOTE_MAC_LO [31:0] = remote_mac[31:0]         W/R
//   0x18  LOCAL_IP      [31:0]                             W/R
//   0x1C  REMOTE_IP     [31:0]                             W/R
//   0x20  LOCAL_PORT    [15:0]                             W/R
//   0x24  REMOTE_PORT   [15:0]                             W/R
//   0x28  TX_DATA    [7:0] write = push byte into TX FIFO  W
//   0x2C  RX_DATA    [7:0] read  = pop byte from RX FIFO   R
//   0x30  RX_COUNT   [11:0] bytes available in RX FIFO     R
//
// CDCの方式:
//   AXIドメイン → clk_50ドメイン:
//     - 1ビット制御信号（connect/disconnect/arp）: 2段FFシンクロナイザ
//     - TXデータ: xpm_fifo_async（8ビット, 2048段）
//   clk_50 → AXIドメイン:
//     - tcp_state, irq_pending: 2段FFシンクロナイザ
//     - RXデータ: xpm_fifo_async（8ビット, 4096段）
// ===========================================================================

module axi4lite_regs #(
    parameter AXI_ADDR_W = 6   // アドレス空間 64バイト
)(
    // ---- AXI4-Liteスレーブ（PSプロセッサ側） ----------------------------------------
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,

    // AXI4-Lite ライトアドレスチャネル
    input  wire [AXI_ADDR_W-1:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output logic        s_axi_awready,

    // AXI4-Lite ライトデータチャネル
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output logic        s_axi_wready,

    // AXI4-Lite ライトレスポンスチャネル
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  wire        s_axi_bready,

    // AXI4-Lite リードアドレスチャネル
    input  wire [AXI_ADDR_W-1:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output logic        s_axi_arready,

    // AXI4-Lite リードデータチャネル
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  wire        s_axi_rready,

    // ---- clk_50ドメイン出力（TCPエンジンへ） ---------------------------
    input  wire        clk_50,    // TCPエンジンクロック（50MHz）
    input  wire        rst_50_n,  // clk_50ドメインのリセット（負論理）

    // アドレス設定レジスタ（clk_50ドメインへ同期済み）
    output logic [47:0] local_mac,   // ローカルMACアドレス
    output logic [47:0] remote_mac,  // リモートMACアドレス
    output logic [31:0] local_ip,    // ローカルIPアドレス
    output logic [31:0] remote_ip,   // リモートIPアドレス
    output logic [15:0] local_port,  // ローカルTCPポート番号
    output logic [15:0] remote_port, // リモートTCPポート番号
    output logic        addr_valid,  // 全アドレスレジスタが設定済み

    // TCP接続制御信号（clk_50ドメイン）
    output logic        connect_req,     // 接続要求（立ち上がりエッジ検出）
    output logic        disconnect_req,  // 切断要求（立ち上がりエッジ検出）
    output logic        arp_send_req,    // ARP送信要求

    // ---- TXデータFIFO（tx_bufferライトポートへ, clk_50ドメイン） ----------
    output logic [7:0]  tx_wr_data,  // TXデータ（1バイト）
    output logic        tx_wr_en,    // TXデータ書き込みイネーブル
    input  wire        tx_wr_full,  // TXバッファ満杯フラグ

    // ---- RXデータFIFO（rx_bufferリードポートから, clk_50ドメイン） ---------
    input  wire [7:0]  rx_rd_data,    // RXデータ（1バイト）
    input  wire        rx_rd_en_out,  // (内部駆動)
    output logic        rx_rd_en,     // RXバッファ読み出しイネーブル
    input  wire        rx_rd_empty,  // RXバッファ空フラグ
    input  wire [11:0] rx_rd_count,  // RXバッファ内バイト数

    // ---- clk_50ドメインからのステータス（2段FFでAXIドメインへ同期） ---------
    input  wire [3:0]  tcp_state_50,     // TCP状態（0-7）
    input  wire        irq_50,           // 割り込み要求（状態変化通知）
    input  wire        arp_mac_valid_50  // ARP応答によるMACアドレス有効フラグ
);

// ---------------------------------------------------------------------------
// AXIドメイン側レジスタ（PSプロセッサが読み書きする設定値）
// ---------------------------------------------------------------------------
logic [31:0] reg_ctrl      = '0;   // 制御レジスタ: [0]=接続要求 [1]=切断要求 [2]=ARP要求
logic [15:0] reg_lmac_hi   = '0;   // ローカルMAC上位16ビット
logic [31:0] reg_lmac_lo   = '0;   // ローカルMAC下位32ビット
logic [15:0] reg_rmac_hi   = '0;   // リモートMAC上位16ビット
logic [31:0] reg_rmac_lo   = '0;   // リモートMAC下位32ビット
logic [31:0] reg_lip       = '0;   // ローカルIPアドレス
logic [31:0] reg_rip       = '0;   // リモートIPアドレス
logic [15:0] reg_lport     = '0;   // ローカルTCPポート番号
logic [15:0] reg_rport     = '0;   // リモートTCPポート番号

logic        irq_pending_axi = 1'b0;  // AXIドメインでのIRQ保留フラグ

// ---------------------------------------------------------------------------
// 2段FF同期: clk_50ドメイン → s_axi_aclkドメイン
// TCPステータス・IRQ・ARP MACフラグをAXIドメインに同期させる
// ---------------------------------------------------------------------------
logic [3:0]  tcp_state_s1, tcp_state_axi;  // TCPステータスの2段FF
logic        irq_s1, irq_axi;              // IRQの2段FF
logic        irq_sticky = 1'b0;            // リード時クリアされるスティッキーIRQフラグ
logic        arpmac_axi;                   // ARP MAC有効フラグ（AXIドメイン同期済み）

always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if (!s_axi_aresetn) begin
        tcp_state_s1  <= '0; tcp_state_axi <= '0;
        irq_s1        <= '0; irq_axi       <= '0;
        arpmac_s1     <= '0; arpmac_axi    <= '0;
    end else begin
        // 2段FF同期（メタステービリティ対策）
        tcp_state_s1  <= tcp_state_50;  tcp_state_axi <= tcp_state_s1;
        irq_s1        <= irq_50;        irq_axi       <= irq_s1;
        arpmac_s1     <= arp_mac_valid_50; arpmac_axi <= arpmac_s1;
    end
end

// ---------------------------------------------------------------------------
// 2段FF同期: s_axi_aclkドメイン → clk_50ドメイン（1ビット制御信号）
// connect/disconnect/arp要求をTCPエンジンに同期させる
// ---------------------------------------------------------------------------
logic conn_s1,   conn_50;   // 接続要求の2段FF
logic disc_s1,   disc_50;   // 切断要求の2段FF
logic arp_s1,    arp_50;    // ARP要求の2段FF
logic arpmac_s1;            // ARP MAC有効フラグのステージ1

always_ff @(posedge clk_50 or negedge rst_50_n) begin
    if (!rst_50_n) begin
        conn_s1  <= '0; conn_50  <= '0;
        disc_s1  <= '0; disc_50  <= '0;
        arp_s1   <= '0; arp_50   <= '0;
    end else begin
        // 2段FF同期（メタステービリティ対策）
        conn_s1  <= reg_ctrl[0]; conn_50  <= conn_s1;
        disc_s1  <= reg_ctrl[1]; disc_50  <= disc_s1;
        arp_s1   <= reg_ctrl[2]; arp_50   <= arp_s1;
    end
end

// clk_50ドメインへの制御信号出力
assign connect_req    = conn_50;
assign disconnect_req = disc_50;
assign arp_send_req   = arp_50;

// ---------------------------------------------------------------------------
// アドレスレジスタの2段FF同期: s_axi_aclkドメイン → clk_50ドメイン
// 接続前にのみ設定される準静的な値のため、2段FFで安全に渡す
// ---------------------------------------------------------------------------
logic [47:0] lmac_s1, lmac_50;  // ローカルMACの2段FF
logic [47:0] rmac_s1, rmac_50;  // リモートMACの2段FF
logic [31:0] lip_s1,  lip_50;   // ローカルIPの2段FF
logic [31:0] rip_s1,  rip_50;   // リモートIPの2段FF
logic [15:0] lp_s1,   lp_50;    // ローカルポートの2段FF
logic [15:0] rp_s1,   rp_50;    // リモートポートの2段FF
logic        av_s1,   av_50;    // addr_validの2段FF

always_ff @(posedge clk_50 or negedge rst_50_n) begin
    if (!rst_50_n) begin
        lmac_s1 <= '0; lmac_50 <= '0;
        rmac_s1 <= '0; rmac_50 <= '0;
        lip_s1  <= '0; lip_50  <= '0;
        rip_s1  <= '0; rip_50  <= '0;
        lp_s1   <= '0; lp_50   <= '0;
        rp_s1   <= '0; rp_50   <= '0;
        av_s1   <= '0; av_50   <= '0;
    end else begin
        // 各アドレスレジスタを2段FFで同期
        lmac_s1 <= {reg_lmac_hi, reg_lmac_lo}; lmac_50 <= lmac_s1;
        rmac_s1 <= {reg_rmac_hi, reg_rmac_lo}; rmac_50 <= rmac_s1;
        lip_s1  <= reg_lip;    lip_50 <= lip_s1;
        rip_s1  <= reg_rip;    rip_50 <= rip_s1;
        lp_s1   <= reg_lport;  lp_50  <= lp_s1;
        rp_s1   <= reg_rport;  rp_50  <= rp_s1;
        // addr_valid: 全アドレスレジスタが非ゼロのときにアサート
        av_s1   <= (reg_lmac_hi != '0 || reg_lmac_lo != '0) &&
                   (reg_rmac_hi != '0 || reg_rmac_lo != '0) &&
                   (reg_lip != '0) && (reg_rip != '0) &&
                   (reg_lport != '0) && (reg_rport != '0);
        av_50   <= av_s1;
    end
end

// clk_50ドメインへのアドレス出力
assign local_mac  = lmac_50;
assign remote_mac = rmac_50;
assign local_ip   = lip_50;
assign remote_ip  = rip_50;
assign local_port = lp_50;
assign remote_port = rp_50;
assign addr_valid  = av_50;

// ---------------------------------------------------------------------------
// TX非同期FIFO: AXIライト（s_axi_aclk）→ clk_50ドメイン（tx_bufferライトポート）
// PSからTXデータ（0x28番地への書き込み）を受け取り、clk_50側へ渡す
// ---------------------------------------------------------------------------
logic        tx_fifo_wr_en;   // AXIドメイン側書き込みイネーブル
logic [7:0]  tx_fifo_din;     // AXIドメイン側書き込みデータ
logic        tx_fifo_full;    // AXIドメイン側満杯フラグ
logic        tx_fifo_rd_en;   // clk_50側読み出しイネーブル
logic [7:0]  tx_fifo_dout;    // clk_50側読み出しデータ
logic        tx_fifo_empty;   // clk_50側空フラグ

// TX非同期FIFOインスタンス（ブロックRAM, 2048バイト深さ, FWFTモード）
xpm_fifo_async #(
    .FIFO_MEMORY_TYPE ("block"),
    .FIFO_WRITE_DEPTH (2048),
    .WRITE_DATA_WIDTH (8),
    .READ_DATA_WIDTH  (8),
    .READ_MODE        ("fwft"),       // First Word Fall Through: 読み出し遅延なし
    .CDC_SYNC_STAGES  (2),
    .FIFO_READ_LATENCY(0),
    .USE_ADV_FEATURES ("0000"),
    .DOUT_RESET_VALUE ("0")
) u_tx_afifo (
    .wr_clk        (s_axi_aclk),
    .rst           (~s_axi_aresetn | ~rst_50_n),
    .din           (tx_fifo_din),
    .wr_en         (tx_fifo_wr_en),
    .full          (tx_fifo_full),
    .rd_clk        (clk_50),
    .dout          (tx_fifo_dout),
    .rd_en         (tx_fifo_rd_en),
    .empty         (tx_fifo_empty),
    .wr_data_count (),
    .rd_data_count (),
    .prog_empty    (),
    .prog_full     (),
    .overflow      (),
    .underflow     (),
    .wr_rst_busy   (),
    .rd_rst_busy   (),
    .almost_empty  (),
    .almost_full   (),
    .sbiterr       (),
    .dbiterr       (),
    .sleep         (1'b0),
    .injectdbiterr (1'b0),
    .injectsbiterr (1'b0)
);

// clk_50側: TX非同期FIFOからtx_bufferへデータを転送（tx_bufferが満杯でなければ読み出す）
assign tx_fifo_rd_en = !tx_fifo_empty && !tx_wr_full;
assign tx_wr_data    = tx_fifo_dout;
assign tx_wr_en      = tx_fifo_rd_en;

// ---------------------------------------------------------------------------
// RX非同期FIFO: clk_50ドメイン（rx_buffer）→ AXIリード（s_axi_aclk）
// TCPエンジンが受信したデータをPSが0x2C番地から読み出せるようにする
// ---------------------------------------------------------------------------
logic        rx_afifo_wr_en;   // clk_50側書き込みイネーブル
logic [7:0]  rx_afifo_din;     // clk_50側書き込みデータ
logic        rx_afifo_full;    // clk_50側満杯フラグ
logic        rx_afifo_rd_en;   // AXIドメイン側読み出しイネーブル
logic [7:0]  rx_afifo_dout;    // AXIドメイン側読み出しデータ
logic        rx_afifo_empty;   // AXIドメイン側空フラグ

// RX非同期FIFOインスタンス（ブロックRAM, 4096バイト深さ, FWFTモード）
xpm_fifo_async #(
    .FIFO_MEMORY_TYPE ("block"),
    .FIFO_WRITE_DEPTH (4096),
    .WRITE_DATA_WIDTH (8),
    .READ_DATA_WIDTH  (8),
    .READ_MODE        ("fwft"),       // First Word Fall Through: 読み出し遅延なし
    .CDC_SYNC_STAGES  (2),
    .FIFO_READ_LATENCY(0),
    .USE_ADV_FEATURES ("0000"),
    .DOUT_RESET_VALUE ("0")
) u_rx_afifo (
    .wr_clk        (clk_50),
    .rst           (~rst_50_n | ~s_axi_aresetn),
    .din           (rx_afifo_din),
    .wr_en         (rx_afifo_wr_en),
    .full          (rx_afifo_full),
    .rd_clk        (s_axi_aclk),
    .dout          (rx_afifo_dout),
    .rd_en         (rx_afifo_rd_en),
    .empty         (rx_afifo_empty),
    .wr_data_count (),
    .rd_data_count (),
    .prog_empty    (),
    .prog_full     (),
    .overflow      (),
    .underflow     (),
    .wr_rst_busy   (),
    .rd_rst_busy   (),
    .almost_empty  (),
    .almost_full   (),
    .sbiterr       (),
    .dbiterr       (),
    .sleep         (1'b0),
    .injectdbiterr (1'b0),
    .injectsbiterr (1'b0)
);

// clk_50側: rx_bufferからRX非同期FIFOへデータを転送（FIFOが満杯でなければ読み出す）
assign rx_rd_en      = !rx_rd_empty && !rx_afifo_full;
assign rx_afifo_din  = rx_rd_data;
assign rx_afifo_wr_en = rx_rd_en;

// ---------------------------------------------------------------------------
// AXI4-Liteライト/リードステートマシン
// ライトアドレス・ライトデータを個別にラッチし、両方揃った時点でレジスタに書き込む
// ---------------------------------------------------------------------------
logic [AXI_ADDR_W-1:0] wr_addr;        // ラッチしたライトアドレス
logic [31:0]           wr_data;        // ラッチしたライトデータ
logic                  wr_addr_lat = 1'b0;  // ライトアドレスラッチ済みフラグ
logic                  wr_data_lat = 1'b0;  // ライトデータラッチ済みフラグ
logic                  do_write;       // ライト実行フラグ（組み合わせ論理）

// AWREADYはアドレスがラッチされていない間のみアサート（1サイクルでラッチ）
assign s_axi_awready = !wr_addr_lat;
assign s_axi_wready  = !wr_data_lat;
assign s_axi_bresp   = 2'b00;  // 常にOKAY応答
assign s_axi_arready = 1'b1;   // リードアドレスは常時受け付け可能
assign s_axi_rresp   = 2'b00;  // 常にOKAY応答

// TX_DATA（0x28番地）へのダイレクト書き込み（組み合わせ論理でFIFOに直接プッシュ）
assign tx_fifo_wr_en = (s_axi_awvalid && s_axi_wvalid &&
                        s_axi_awaddr == 6'h28 && !tx_fifo_full);
assign tx_fifo_din   = s_axi_wdata[7:0];

// RX_DATA（0x2C番地）のリード時にRX非同期FIFOからポップ
assign rx_afifo_rd_en = s_axi_arvalid && (s_axi_araddr == 6'h2C) && !rx_afifo_empty;

always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if (!s_axi_aresetn) begin
        s_axi_bvalid  <= 1'b0;
        s_axi_rvalid  <= 1'b0;
        s_axi_rdata   <= '0;
        wr_addr_lat   <= 1'b0;
        wr_data_lat   <= 1'b0;
        wr_addr       <= '0;
        wr_data       <= '0;
        reg_ctrl      <= '0;
        reg_lmac_hi   <= '0; reg_lmac_lo <= '0;
        reg_rmac_hi   <= '0; reg_rmac_lo <= '0;
        reg_lip       <= '0; reg_rip     <= '0;
        reg_lport     <= '0; reg_rport   <= '0;
        irq_sticky    <= 1'b0;
    end else begin
        // ライトレスポンス・リードデータの1サイクルストローブをデアサート
        if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
        if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;

        // --- AXI4-Lite ライトアドレスチャネルのハンドシェイク ---
        if (s_axi_awvalid && s_axi_awready) begin
            wr_addr     <= s_axi_awaddr;  // ライトアドレスをラッチ
            wr_addr_lat <= 1'b1;
        end
        // --- AXI4-Lite ライトデータチャネルのハンドシェイク ---
        if (s_axi_wvalid && s_axi_wready) begin
            wr_data     <= s_axi_wdata;   // ライトデータをラッチ
            wr_data_lat <= 1'b1;
        end

        // --- レジスタへのライト実行（アドレスとデータが両方揃ったとき） ---
        do_write = wr_addr_lat && wr_data_lat;
        if (do_write) begin
            wr_addr_lat  <= 1'b0;
            wr_data_lat  <= 1'b0;
            s_axi_bvalid <= 1'b1;  // ライトレスポンス送出
            case (wr_addr)
                6'h00: reg_ctrl    <= wr_data;         // 制御レジスタ
                6'h08: reg_lmac_hi <= wr_data[15:0];   // ローカルMAC上位
                6'h0C: reg_lmac_lo <= wr_data;         // ローカルMAC下位
                6'h10: reg_rmac_hi <= wr_data[15:0];   // リモートMAC上位
                6'h14: reg_rmac_lo <= wr_data;         // リモートMAC下位
                6'h18: reg_lip     <= wr_data;         // ローカルIPアドレス
                6'h1C: reg_rip     <= wr_data;         // リモートIPアドレス
                6'h20: reg_lport   <= wr_data[15:0];   // ローカルTCPポート
                6'h24: reg_rport   <= wr_data[15:0];   // リモートTCPポート
                // 0x28 TX_DATA は組み合わせ論理の tx_fifo_wr_en で処理
                default: ;
            endcase
        end

        // --- AXI4-Lite リードチャネル処理 ---
        if (s_axi_arvalid && s_axi_arready && !s_axi_rvalid) begin
            s_axi_rvalid <= 1'b1;  // リードデータ有効
            case (s_axi_araddr)
                6'h00: s_axi_rdata <= reg_ctrl;   // 制御レジスタ読み出し
                6'h04: begin
                    // STATUSレジスタ: ARP MAC有効 | IRQスティッキー | TCP状態
                    s_axi_rdata <= {25'h0, arpmac_axi, irq_sticky, tcp_state_axi};
                    irq_sticky  <= 1'b0;  // 読み出し時にIRQスティッキーをクリア
                end
                6'h08: s_axi_rdata <= {16'h0, reg_lmac_hi};
                6'h0C: s_axi_rdata <= reg_lmac_lo;
                6'h10: s_axi_rdata <= {16'h0, reg_rmac_hi};
                6'h14: s_axi_rdata <= reg_rmac_lo;
                6'h18: s_axi_rdata <= reg_lip;
                6'h1C: s_axi_rdata <= reg_rip;
                6'h20: s_axi_rdata <= {16'h0, reg_lport};
                6'h24: s_axi_rdata <= {16'h0, reg_rport};
                6'h2C: s_axi_rdata <= {24'h0, rx_afifo_dout};  // RXデータ読み出し（1バイト）
                6'h30: s_axi_rdata <= {20'h0, rx_rd_count};    // RXバッファ残バイト数
                default: s_axi_rdata <= '0;
            endcase
        end

        // clk_50側からのIRQをスティッキーフラグにラッチ（STATUSリードまで保持）
        if (irq_axi) irq_sticky <= 1'b1;
    end
end

endmodule
`default_nettype wire
