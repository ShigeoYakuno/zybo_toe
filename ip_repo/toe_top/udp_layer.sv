`default_nettype none
// UDP layer: TX sends fixed 64-byte UDP frames; RX filters incoming UDP
// and pushes payload bytes to FIFO.
// Interface is compatible with the existing axi4lite_regs TX/RX FIFO ports.

module udp_layer #(
    parameter PAYLOAD_BYTES = 64,
    parameter CLK_HZ        = 50_000_000
)(
    input  logic        clk,
    input  logic        rst_n,

    // Quasi-static config (2FF-synced from AXI in axi4lite_regs)
    input  logic [47:0] local_mac,
    input  logic [47:0] remote_mac,
    input  logic [31:0] local_ip,
    input  logic [31:0] remote_ip,
    input  logic [15:0] local_port,
    input  logic [15:0] remote_port,

    // ARM control: rising edge triggers one TX
    input  logic        send_req,

    // TX byte stream (from xpm_fifo_async in axi4lite_regs, clk domain)
    input  logic [7:0]  tx_wr_data,
    input  logic        tx_wr_en,
    output logic        tx_wr_full,

    // RX byte stream (to xpm_fifo_async in axi4lite_regs, clk domain)
    output logic [7:0]  rx_rd_data,
    input  logic        rx_rd_en,
    output logic        rx_rd_empty,
    output logic [11:0] rx_rd_count,

    // Status
    output logic        tx_busy,

    // RX from MAC (no backpressure)
    input  logic [7:0]  rx_tdata,
    input  logic        rx_tvalid,
    input  logic        rx_tlast,
    input  logic        rx_tuser,   // 1 = CRC error

    // TX to MAC (with backpressure)
    output logic [7:0]  tx_tdata,
    output logic        tx_tvalid,
    input  logic        tx_tready,
    output logic        tx_tlast
);

// ---------------------------------------------------------------------------
// TX staging buffer
// ---------------------------------------------------------------------------
logic [7:0] tx_buf [0:PAYLOAD_BYTES-1];
logic [6:0] tx_fill   = '0;
logic       tx_sending = 1'b0;

assign tx_wr_full = tx_sending || (tx_fill >= 7'(PAYLOAD_BYTES));

// last byte index: Eth(14)+IP(20)+UDP(8)+payload-1 = 105
localparam [6:0] TX_LAST = 7'(14 + 20 + 8 + PAYLOAD_BYTES - 1);

logic [6:0] tx_ptr  = '0;
logic       tx_done_c;
assign tx_done_c = tx_sending && tx_tready && (tx_ptr == TX_LAST);

always_ff @(posedge clk or negedge rst_n) begin : p_txbuf
    if (!rst_n) begin
        tx_fill <= '0;
    end else begin
        if (tx_wr_en && !tx_wr_full) begin
            tx_buf[tx_fill] <= tx_wr_data;
            tx_fill <= tx_fill + 1'b1;
        end
        if (tx_done_c)
            tx_fill <= '0;   // safe: tx_wr_full=1 while sending
    end
end

// ---------------------------------------------------------------------------
// IP checksum (combinatorial)
//   Constant: 0x4500+0x005C+0x0000+0x4000+0x4011 = 0xC56D
// ---------------------------------------------------------------------------
logic [31:0] ip_sum_c;
logic [16:0] ip_fold;
logic [15:0] ip_csum;

assign ip_sum_c = 32'hC56D
                + {16'h0, local_ip[31:16]}
                + {16'h0, local_ip[15:0]}
                + {16'h0, remote_ip[31:16]}
                + {16'h0, remote_ip[15:0]};
assign ip_fold  = {1'b0, ip_sum_c[15:0]} + {1'b0, ip_sum_c[31:16]};
assign ip_csum  = ~(ip_fold[15:0] + {15'h0, ip_fold[16]});

// ---------------------------------------------------------------------------
// TX FSM
// ---------------------------------------------------------------------------
logic send_prev = 1'b0;

always_ff @(posedge clk or negedge rst_n) begin : p_tx
    if (!rst_n) begin
        tx_sending <= 1'b0;
        tx_ptr     <= '0;
        send_prev  <= 1'b0;
    end else begin
        send_prev <= send_req;
        if (!tx_sending) begin
            if (send_req && !send_prev && tx_fill >= 7'(PAYLOAD_BYTES)) begin
                tx_sending <= 1'b1;
                tx_ptr     <= '0;
            end
        end else begin
            if (tx_tready) begin
                if (tx_ptr == TX_LAST)
                    tx_sending <= 1'b0;
                else
                    tx_ptr <= tx_ptr + 1'b1;
            end
        end
    end
end

// Byte mux: fully combinatorial — no registered tlast, avoids the tlast-timing bug
always_comb begin : p_txmux
    case (tx_ptr)
        7'd0:  tx_tdata = remote_mac[47:40];
        7'd1:  tx_tdata = remote_mac[39:32];
        7'd2:  tx_tdata = remote_mac[31:24];
        7'd3:  tx_tdata = remote_mac[23:16];
        7'd4:  tx_tdata = remote_mac[15:8];
        7'd5:  tx_tdata = remote_mac[7:0];
        7'd6:  tx_tdata = local_mac[47:40];
        7'd7:  tx_tdata = local_mac[39:32];
        7'd8:  tx_tdata = local_mac[31:24];
        7'd9:  tx_tdata = local_mac[23:16];
        7'd10: tx_tdata = local_mac[15:8];
        7'd11: tx_tdata = local_mac[7:0];
        7'd12: tx_tdata = 8'h08;            // EtherType 0x0800
        7'd13: tx_tdata = 8'h00;
        7'd14: tx_tdata = 8'h45;            // IPv4, IHL=5
        7'd15: tx_tdata = 8'h00;
        7'd16: tx_tdata = 8'h00;            // total length = 92 = 0x005C
        7'd17: tx_tdata = 8'h5C;
        7'd18: tx_tdata = 8'h00;            // IP ID
        7'd19: tx_tdata = 8'h00;
        7'd20: tx_tdata = 8'h40;            // DF flag
        7'd21: tx_tdata = 8'h00;
        7'd22: tx_tdata = 8'h40;            // TTL = 64
        7'd23: tx_tdata = 8'h11;            // Protocol = UDP
        7'd24: tx_tdata = ip_csum[15:8];
        7'd25: tx_tdata = ip_csum[7:0];
        7'd26: tx_tdata = local_ip[31:24];
        7'd27: tx_tdata = local_ip[23:16];
        7'd28: tx_tdata = local_ip[15:8];
        7'd29: tx_tdata = local_ip[7:0];
        7'd30: tx_tdata = remote_ip[31:24];
        7'd31: tx_tdata = remote_ip[23:16];
        7'd32: tx_tdata = remote_ip[15:8];
        7'd33: tx_tdata = remote_ip[7:0];
        7'd34: tx_tdata = local_port[15:8]; // UDP src port
        7'd35: tx_tdata = local_port[7:0];
        7'd36: tx_tdata = remote_port[15:8];// UDP dst port
        7'd37: tx_tdata = remote_port[7:0];
        7'd38: tx_tdata = 8'h00;            // UDP length = 72 = 0x0048
        7'd39: tx_tdata = 8'h48;
        7'd40: tx_tdata = 8'h00;            // UDP checksum = 0 (disabled)
        7'd41: tx_tdata = 8'h00;
        default: tx_tdata = tx_buf[tx_ptr - 7'd42]; // payload bytes 0..63
    endcase
end

assign tx_tvalid = tx_sending;
assign tx_tlast  = tx_sending && (tx_ptr == TX_LAST);
assign tx_busy   = tx_sending;

// ---------------------------------------------------------------------------
// RX FSM: filter by IP proto=0x11, dst_ip, dst_port; push payload to FIFO
// ---------------------------------------------------------------------------
logic [7:0] rx_b_cnt    = '0;
logic       rx_proto_ok = 1'b0;
logic       rx_ip_ok    = 1'b0;
logic       rx_port_ok  = 1'b0;
logic [7:0] rx_ip3='0, rx_ip2='0, rx_ip1='0;
logic [7:0] rx_pt1 = '0;
logic [6:0] rx_pay_cnt = '0;

logic rx_accept;
assign rx_accept = rx_proto_ok && rx_ip_ok && rx_port_ok;

logic rx_fifo_wr_en, rx_fifo_full;
assign rx_fifo_wr_en = rx_tvalid && !rx_tuser && rx_accept
                     && (rx_b_cnt >= 8'd42)
                     && (rx_pay_cnt < 7'(PAYLOAD_BYTES))
                     && !rx_fifo_full;

always_ff @(posedge clk or negedge rst_n) begin : p_rx
    if (!rst_n) begin
        rx_b_cnt    <= '0;
        rx_proto_ok <= 1'b0; rx_ip_ok  <= 1'b0; rx_port_ok <= 1'b0;
        rx_ip3 <= '0; rx_ip2 <= '0; rx_ip1 <= '0; rx_pt1 <= '0;
        rx_pay_cnt  <= '0;
    end else if (rx_tvalid) begin
        if (rx_tlast) begin
            rx_b_cnt    <= '0;
            rx_proto_ok <= 1'b0; rx_ip_ok <= 1'b0; rx_port_ok <= 1'b0;
            rx_pay_cnt  <= '0;
        end else begin
            if (rx_b_cnt != 8'd255) rx_b_cnt <= rx_b_cnt + 1'b1;
            case (rx_b_cnt)
                8'd23: rx_proto_ok <= (rx_tdata == 8'h11);
                8'd30: rx_ip3      <= rx_tdata;
                8'd31: rx_ip2      <= rx_tdata;
                8'd32: rx_ip1      <= rx_tdata;
                8'd33: rx_ip_ok    <= (rx_tdata == local_ip[7:0])
                                   && (rx_ip1   == local_ip[15:8])
                                   && (rx_ip2   == local_ip[23:16])
                                   && (rx_ip3   == local_ip[31:24]);
                8'd36: rx_pt1      <= rx_tdata;
                8'd37: rx_port_ok  <= (rx_tdata == local_port[7:0])
                                   && (rx_pt1   == local_port[15:8]);
                default: ;
            endcase
            if (rx_fifo_wr_en) rx_pay_cnt <= rx_pay_cnt + 1'b1;
        end
    end
end

// ---------------------------------------------------------------------------
// RX FIFO (xpm_fifo_sync, clk domain; CDC handled by axi4lite_regs)
// ---------------------------------------------------------------------------
xpm_fifo_sync #(
    .FIFO_MEMORY_TYPE ("block"),
    .FIFO_WRITE_DEPTH (512),
    .WRITE_DATA_WIDTH (8),
    .READ_DATA_WIDTH  (8),
    .READ_MODE        ("fwft"),
    .FIFO_READ_LATENCY(0),
    .USE_ADV_FEATURES ("0000"),
    .DOUT_RESET_VALUE ("0")
) u_rx_fifo (
    .clk          (clk),
    .rst          (~rst_n),
    .din          (rx_tdata),
    .wr_en        (rx_fifo_wr_en),
    .full         (rx_fifo_full),
    .dout         (rx_rd_data),
    .rd_en        (rx_rd_en),
    .empty        (rx_rd_empty),
    .rd_data_count(),
    .wr_data_count(),
    .prog_empty   (),
    .prog_full    (),
    .overflow     (),
    .underflow    (),
    .wr_rst_busy  (),
    .rd_rst_busy  (),
    .sbiterr      (),
    .dbiterr      (),
    .sleep        (1'b0),
    .injectdbiterr(1'b0),
    .injectsbiterr(1'b0)
);

// Byte counter (maintained separately; safe because rx_rd_en only fires when !empty)
logic [11:0] rx_cnt = '0;
always_ff @(posedge clk or negedge rst_n) begin : p_rxcnt
    if (!rst_n) begin
        rx_cnt <= '0;
    end else begin
        unique case ({rx_fifo_wr_en, rx_rd_en && !rx_rd_empty})
            2'b10:   rx_cnt <= rx_cnt + 1'b1;
            2'b01:   rx_cnt <= rx_cnt - 1'b1;
            default: ;
        endcase
    end
end
assign rx_rd_count = rx_cnt;

endmodule
`default_nettype wire
