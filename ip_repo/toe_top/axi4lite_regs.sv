`default_nettype none
// AXI4-Lite register slave + CDC bridge (UDP version).
//
// Register map (32-bit, word-aligned):
//   0x00  CTRL       [0]=send_req  [2]=arp_req  W/R
//   0x04  STATUS     [0]=tx_busy  [5]=arp_mac_valid  R
//   0x08  LOCAL_MAC_HI  [15:0] = local_mac[47:32]   W/R
//   0x0C  LOCAL_MAC_LO  [31:0] = local_mac[31:0]    W/R
//   0x10  REMOTE_MAC_HI [15:0] = remote_mac[47:32]  W/R
//   0x14  REMOTE_MAC_LO [31:0] = remote_mac[31:0]   W/R
//   0x18  LOCAL_IP      [31:0]                       W/R
//   0x1C  REMOTE_IP     [31:0]                       W/R
//   0x20  LOCAL_PORT    [15:0]                       W/R
//   0x24  REMOTE_PORT   [15:0]                       W/R
//   0x28  TX_DATA    [7:0] write = push byte into TX FIFO  W
//   0x2C  RX_DATA    [7:0] read  = pop byte from RX FIFO   R
//   0x30  RX_COUNT   [11:0] bytes available in RX FIFO     R

module axi4lite_regs #(
    parameter AXI_ADDR_W = 6   // 64-byte address space
)(
    // ---- AXI4-Lite slave (PS side) ----------------------------------------
    input  logic        s_axi_aclk,
    input  logic        s_axi_aresetn,

    input  logic [AXI_ADDR_W-1:0] s_axi_awaddr,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,

    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,

    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,

    input  logic [AXI_ADDR_W-1:0] s_axi_araddr,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,

    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    // ---- clk_50 domain outputs (to toe_engine) ---------------------------
    input  logic        clk_50,
    input  logic        rst_50_n,

    output logic [47:0] local_mac,
    output logic [47:0] remote_mac,
    output logic [31:0] local_ip,
    output logic [31:0] remote_ip,
    output logic [15:0] local_port,
    output logic [15:0] remote_port,
    output logic        addr_valid,

    output logic        send_req,
    output logic        arp_send_req,

    // ---- TX data FIFO (to tx_buffer write port, clk_50 domain) ----------
    output logic [7:0]  tx_wr_data,
    output logic        tx_wr_en,
    input  logic        tx_wr_full,

    // ---- RX data FIFO (from rx_buffer read port, clk_50 domain) ---------
    input  logic [7:0]  rx_rd_data,
    input  logic        rx_rd_en_out,   // driven internally
    output logic        rx_rd_en,
    input  logic        rx_rd_empty,
    input  logic [11:0] rx_rd_count,

    // ---- Status from clk_50 domain (to AXI domain via 2FF sync) ---------
    input  logic        tx_busy_50,
    input  logic        arp_mac_valid_50
);

// ---------------------------------------------------------------------------
// AXI-domain registers
// ---------------------------------------------------------------------------
logic [31:0] reg_ctrl      = '0;   // [0]=send_req [2]=arp_req
logic [15:0] reg_lmac_hi   = '0;
logic [31:0] reg_lmac_lo   = '0;
logic [15:0] reg_rmac_hi   = '0;
logic [31:0] reg_rmac_lo   = '0;
logic [31:0] reg_lip       = '0;
logic [31:0] reg_rip       = '0;
logic [15:0] reg_lport     = '0;
logic [15:0] reg_rport     = '0;

// 2FF sync: clk_50 → axi_clk
logic tx_busy_s1,   tx_busy_axi;
logic arpmac_s1,    arp_mac_valid_axi;

always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if (!s_axi_aresetn) begin
        tx_busy_s1 <= '0; tx_busy_axi      <= '0;
        arpmac_s1  <= '0; arp_mac_valid_axi <= '0;
    end else begin
        tx_busy_s1 <= tx_busy_50;       tx_busy_axi      <= tx_busy_s1;
        arpmac_s1  <= arp_mac_valid_50; arp_mac_valid_axi <= arpmac_s1;
    end
end

// 2FF sync: axi_clk → clk_50 (single-bit controls)
logic send_s1, send_50;
logic arp_s1,  arp_50;

always_ff @(posedge clk_50 or negedge rst_50_n) begin
    if (!rst_50_n) begin
        send_s1 <= '0; send_50 <= '0;
        arp_s1  <= '0; arp_50  <= '0;
    end else begin
        send_s1 <= reg_ctrl[0]; send_50 <= send_s1;
        arp_s1  <= reg_ctrl[2]; arp_50  <= arp_s1;
    end
end

assign send_req     = send_50;
assign arp_send_req = arp_50;

// Latch address registers into clk_50 domain (quasi-static, 2FF sync)
// We sync individual bits — these only change before connection.
logic [47:0] lmac_s1, lmac_50;
logic [47:0] rmac_s1, rmac_50;
logic [31:0] lip_s1,  lip_50;
logic [31:0] rip_s1,  rip_50;
logic [15:0] lp_s1,   lp_50;
logic [15:0] rp_s1,   rp_50;
logic        av_s1,   av_50;

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
        lmac_s1 <= {reg_lmac_hi, reg_lmac_lo}; lmac_50 <= lmac_s1;
        rmac_s1 <= {reg_rmac_hi, reg_rmac_lo}; rmac_50 <= rmac_s1;
        lip_s1  <= reg_lip;    lip_50 <= lip_s1;
        rip_s1  <= reg_rip;    rip_50 <= rip_s1;
        lp_s1   <= reg_lport;  lp_50  <= lp_s1;
        rp_s1   <= reg_rport;  rp_50  <= rp_s1;
        // addr_valid: set when all address regs non-zero
        av_s1   <= (reg_lmac_hi != '0 || reg_lmac_lo != '0) &&
                   (reg_rmac_hi != '0 || reg_rmac_lo != '0) &&
                   (reg_lip != '0) && (reg_rip != '0) &&
                   (reg_lport != '0) && (reg_rport != '0);
        av_50   <= av_s1;
    end
end

assign local_mac  = lmac_50;
assign remote_mac = rmac_50;
assign local_ip   = lip_50;
assign remote_ip  = rip_50;
assign local_port = lp_50;
assign remote_port = rp_50;
assign addr_valid  = av_50;

// ---------------------------------------------------------------------------
// TX async FIFO: AXI write → clk_50 domain (tx_buffer write port)
// ---------------------------------------------------------------------------
logic        tx_fifo_wr_en;
logic [7:0]  tx_fifo_din;
logic        tx_fifo_full;
logic        tx_fifo_rd_en;
logic [7:0]  tx_fifo_dout;
logic        tx_fifo_empty;

xpm_fifo_async #(
    .FIFO_MEMORY_TYPE ("block"),
    .FIFO_WRITE_DEPTH (2048),
    .WRITE_DATA_WIDTH (8),
    .READ_DATA_WIDTH  (8),
    .READ_MODE        ("fwft"),
    .CDC_SYNC_STAGES  (2),
    .FIFO_READ_LATENCY(0),
    .USE_ADV_FEATURES ("0000"),
    .DOUT_RESET_VALUE ("0")
) u_tx_afifo (
    .wr_clk        (s_axi_aclk),
    .wr_rst        (~s_axi_aresetn),
    .din           (tx_fifo_din),
    .wr_en         (tx_fifo_wr_en),
    .full          (tx_fifo_full),
    .rd_clk        (clk_50),
    .rd_rst        (~rst_50_n),
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

// clk_50 side: drain TX async FIFO into tx_buffer when not full
assign tx_fifo_rd_en = !tx_fifo_empty && !tx_wr_full;
assign tx_wr_data    = tx_fifo_dout;
assign tx_wr_en      = tx_fifo_rd_en;

// ---------------------------------------------------------------------------
// RX async FIFO: clk_50 (rx_buffer) → AXI read
// ---------------------------------------------------------------------------
logic        rx_afifo_wr_en;
logic [7:0]  rx_afifo_din;
logic        rx_afifo_full;
logic        rx_afifo_rd_en;
logic [7:0]  rx_afifo_dout;
logic        rx_afifo_empty;

xpm_fifo_async #(
    .FIFO_MEMORY_TYPE ("block"),
    .FIFO_WRITE_DEPTH (4096),
    .WRITE_DATA_WIDTH (8),
    .READ_DATA_WIDTH  (8),
    .READ_MODE        ("fwft"),
    .CDC_SYNC_STAGES  (2),
    .FIFO_READ_LATENCY(0),
    .USE_ADV_FEATURES ("0000"),
    .DOUT_RESET_VALUE ("0")
) u_rx_afifo (
    .wr_clk        (clk_50),
    .wr_rst        (~rst_50_n),
    .din           (rx_afifo_din),
    .wr_en         (rx_afifo_wr_en),
    .full          (rx_afifo_full),
    .rd_clk        (s_axi_aclk),
    .rd_rst        (~s_axi_aresetn),
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

// clk_50 side: push from rx_buffer into RX async FIFO when not full
assign rx_rd_en      = !rx_rd_empty && !rx_afifo_full;
assign rx_afifo_din  = rx_rd_data;
assign rx_afifo_wr_en = rx_rd_en;

// ---------------------------------------------------------------------------
// AXI4-Lite write/read FSM
// ---------------------------------------------------------------------------
logic [AXI_ADDR_W-1:0] wr_addr;
logic [31:0]           wr_data;
logic                  wr_addr_lat = 1'b0;
logic                  wr_data_lat = 1'b0;
logic                  do_write;

assign s_axi_awready = !wr_addr_lat;
assign s_axi_wready  = !wr_data_lat;
assign s_axi_bresp   = 2'b00;  // OKAY
assign s_axi_arready = 1'b1;   // always ready for reads
assign s_axi_rresp   = 2'b00;

// TX FIFO write via AXI (TX_DATA register = 0x28)
assign tx_fifo_wr_en = (s_axi_awvalid && s_axi_wvalid &&
                        s_axi_awaddr == 6'h28 && !tx_fifo_full);
assign tx_fifo_din   = s_axi_wdata[7:0];

// RX FIFO pop via AXI (RX_DATA register read = 0x2C)
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
    end else begin
        // Deassert single-cycle strobes
        if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
        if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;

        // --- Write address channel ---
        if (s_axi_awvalid && s_axi_awready) begin
            wr_addr     <= s_axi_awaddr;
            wr_addr_lat <= 1'b1;
        end
        // --- Write data channel ---
        if (s_axi_wvalid && s_axi_wready) begin
            wr_data     <= s_axi_wdata;
            wr_data_lat <= 1'b1;
        end

        // --- Execute write ---
        do_write = wr_addr_lat && wr_data_lat;
        if (do_write) begin
            wr_addr_lat  <= 1'b0;
            wr_data_lat  <= 1'b0;
            s_axi_bvalid <= 1'b1;
            case (wr_addr)
                6'h00: reg_ctrl    <= wr_data;
                6'h08: reg_lmac_hi <= wr_data[15:0];
                6'h0C: reg_lmac_lo <= wr_data;
                6'h10: reg_rmac_hi <= wr_data[15:0];
                6'h14: reg_rmac_lo <= wr_data;
                6'h18: reg_lip     <= wr_data;
                6'h1C: reg_rip     <= wr_data;
                6'h20: reg_lport   <= wr_data[15:0];
                6'h24: reg_rport   <= wr_data[15:0];
                // 0x28 TX_DATA handled by combinatorial tx_fifo_wr_en
                default: ;
            endcase
        end

        // --- Read channel ---
        if (s_axi_arvalid && s_axi_arready && !s_axi_rvalid) begin
            s_axi_rvalid <= 1'b1;
            case (s_axi_araddr)
                6'h00: s_axi_rdata <= reg_ctrl;
                6'h04: s_axi_rdata <= {26'h0, arp_mac_valid_axi, 4'h0, tx_busy_axi};
                6'h08: s_axi_rdata <= {16'h0, reg_lmac_hi};
                6'h0C: s_axi_rdata <= reg_lmac_lo;
                6'h10: s_axi_rdata <= {16'h0, reg_rmac_hi};
                6'h14: s_axi_rdata <= reg_rmac_lo;
                6'h18: s_axi_rdata <= reg_lip;
                6'h1C: s_axi_rdata <= reg_rip;
                6'h20: s_axi_rdata <= {16'h0, reg_lport};
                6'h24: s_axi_rdata <= {16'h0, reg_rport};
                6'h2C: s_axi_rdata <= {24'h0, rx_afifo_dout};
                6'h30: s_axi_rdata <= {20'h0, rx_rd_count};
                default: s_axi_rdata <= '0;
            endcase
        end

    end
end

endmodule
`default_nettype wire
