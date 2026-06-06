`default_nettype none
// TCP/IP layer top.
// Instantiates: tcp_rx_hdr_dec, tcp_hdr_gen, tcp_state_ctrl,
//               tx_buffer, rx_buffer, lfsr_isn.
// RX byte stream comes from frame_mux (IPv4/TCP frames only).
// TX AXI-Stream goes to toe_engine TX arbiter.

module tcp_layer #(
    parameter WIN_SIZE = 16'd4096,
    parameter CLK_HZ   = 50_000_000
)(
    input  logic        clk,
    input  logic        rst_n,

    // ---- Addresses from axi4lite_regs ------------------------------------
    input  logic [47:0] local_mac,
    input  logic [47:0] remote_mac,
    input  logic [31:0] local_ip,
    input  logic [31:0] remote_ip,
    input  logic [15:0] local_port,
    input  logic [15:0] remote_port,
    input  logic        addr_valid,

    // ---- ARM control (already in clk domain) -----------------------------
    input  logic        connect_req,
    input  logic        disconnect_req,

    // ---- TX data from ARM (via axi4lite_regs async FIFO) ----------------
    input  logic [7:0]  tx_wr_data,
    input  logic        tx_wr_en,
    output logic        tx_wr_full,

    // ---- RX data to ARM (via axi4lite_regs async FIFO bridge) -----------
    output logic [7:0]  rx_rd_data,
    input  logic        rx_rd_en,
    output logic        rx_rd_empty,
    output logic [11:0] rx_rd_count,

    // ---- RX byte stream from frame_mux (no backpressure) ----------------
    input  logic [7:0]  rx_tdata,
    input  logic        rx_tvalid,
    input  logic        rx_tlast,
    input  logic        rx_tuser,   // 1 = CRC error

    // ---- TX AXI-Stream to arbiter ----------------------------------------
    output logic [7:0]  tx_tdata,
    output logic        tx_tvalid,
    input  logic        tx_tready,
    output logic        tx_tlast,

    // ---- Status to axi4lite_regs -----------------------------------------
    output logic [3:0]  tcp_state,
    output logic        irq
);

// ---- ISN from LFSR --------------------------------------------------------
logic [31:0] isn;
lfsr_isn u_lfsr (
    .clk (clk),
    .isn (isn)
);

// ---- RX buffer ------------------------------------------------------------
logic [7:0]  rxbuf_wr_data;
logic        rxbuf_wr_en;
logic        rxbuf_wr_full;
logic [7:0]  rxbuf_rd_data;
logic        rxbuf_rd_en;
logic        rxbuf_rd_empty;
logic [11:0] rxbuf_rd_count;

rx_buffer u_rx_buf (
    .clk      (clk),
    .rst_n    (rst_n),
    .wr_data  (rxbuf_wr_data),
    .wr_en    (rxbuf_wr_en),
    .wr_full  (rxbuf_wr_full),
    .rd_data  (rxbuf_rd_data),
    .rd_en    (rxbuf_rd_en),
    .rd_empty (rxbuf_rd_empty),
    .rd_count (rxbuf_rd_count)
);

assign rx_rd_data   = rxbuf_rd_data;
assign rx_rd_empty  = rxbuf_rd_empty;
assign rx_rd_count  = rxbuf_rd_count;
assign rxbuf_rd_en  = rx_rd_en;

// ---- TX buffer ------------------------------------------------------------
logic        txbuf_send_req;
logic [10:0] txbuf_send_len;
logic        txbuf_busy;
logic [7:0]  txbuf_rd_data;
logic        txbuf_rd_valid;
logic        txbuf_rd_last;
logic        txbuf_ack_advance;
logic [10:0] txbuf_ack_delta;
logic        txbuf_retrans;

tx_buffer u_tx_buf (
    .clk         (clk),
    .rst_n       (rst_n),
    .wr_data     (tx_wr_data),
    .wr_en       (tx_wr_en),
    .wr_full     (tx_wr_full),
    .send_req    (txbuf_send_req),
    .send_len    (txbuf_send_len),
    .buf_busy    (txbuf_busy),
    .rd_data     (txbuf_rd_data),
    .rd_valid    (txbuf_rd_valid),
    .rd_last     (txbuf_rd_last),
    .ack_advance (txbuf_ack_advance),
    .ack_delta   (txbuf_ack_delta),
    .retrans_req (txbuf_retrans)
);

// ---- RX header decoder ----------------------------------------------------
logic        pkt_valid;
logic        rx_syn, rx_ack, rx_fin, rx_rst;
logic [31:0] rx_seq_num, rx_ack_num;
logic [15:0] rx_win_size, rx_payload_len;

tcp_rx_hdr_dec u_rx_dec (
    .clk            (clk),
    .rst_n          (rst_n),
    .rx_tdata       (rx_tdata),
    .rx_tvalid      (rx_tvalid),
    .rx_tlast       (rx_tlast),
    .rx_tuser       (rx_tuser),
    .local_mac      (local_mac),
    .remote_mac     (remote_mac),
    .local_ip       (local_ip),
    .remote_ip      (remote_ip),
    .local_port     (local_port),
    .remote_port    (remote_port),
    .addr_valid     (addr_valid),
    .pkt_valid      (pkt_valid),
    .rx_syn         (rx_syn),
    .rx_ack         (rx_ack),
    .rx_fin         (rx_fin),
    .rx_rst         (rx_rst),
    .rx_seq_num     (rx_seq_num),
    .rx_ack_num     (rx_ack_num),
    .rx_win_size    (rx_win_size),
    .rx_payload_len (rx_payload_len),
    .pl_data        (rxbuf_wr_data),
    .pl_wr_en       (rxbuf_wr_en),
    .pl_full        (rxbuf_wr_full)
);

// ---- TCP state controller -------------------------------------------------
logic        tx_send_req;
logic [8:0]  tx_flags;
logic [31:0] tx_seq_num, tx_ack_num;
logic [10:0] tx_payload_len;
logic        tx_payload_en;
logic        tx_busy;

tcp_state_ctrl #(
    .CLK_HZ        (CLK_HZ)
) u_state (
    .clk            (clk),
    .rst_n          (rst_n),
    .connect_req    (connect_req),
    .disconnect_req (disconnect_req),
    .pkt_valid      (pkt_valid),
    .rx_syn         (rx_syn),
    .rx_ack         (rx_ack),
    .rx_fin         (rx_fin),
    .rx_rst         (rx_rst),
    .rx_seq_num     (rx_seq_num),
    .rx_ack_num     (rx_ack_num),
    .rx_win_size    (rx_win_size),
    .rx_payload_len (rx_payload_len),
    .isn            (isn),
    .tx_send_req    (tx_send_req),
    .tx_flags       (tx_flags),
    .tx_seq_num     (tx_seq_num),
    .tx_ack_num     (tx_ack_num),
    .tx_payload_len (tx_payload_len),
    .tx_payload_en  (tx_payload_en),
    .tx_busy        (tx_busy),
    .retrans_req    (txbuf_retrans),
    .ack_advance    (txbuf_ack_advance),
    .ack_delta      (txbuf_ack_delta),
    .tcp_state      (tcp_state),
    .irq            (irq)
);

// ---- TX header generator --------------------------------------------------
logic        gen_busy;

tcp_hdr_gen #(
    .WIN_SIZE (WIN_SIZE)
) u_hdr_gen (
    .clk          (clk),
    .rst_n        (rst_n),
    .send_req     (tx_send_req),
    .flags        (tx_flags),
    .seq_num      (tx_seq_num),
    .ack_num      (tx_ack_num),
    .payload_len  (tx_payload_len),
    .payload_en   (tx_payload_en),
    .gen_busy     (gen_busy),
    .local_mac    (local_mac),
    .remote_mac   (remote_mac),
    .local_ip     (local_ip),
    .remote_ip    (remote_ip),
    .local_port   (local_port),
    .remote_port  (remote_port),
    .buf_send_req (txbuf_send_req),
    .buf_send_len (txbuf_send_len),
    .buf_busy     (txbuf_busy),
    .buf_rd_data  (txbuf_rd_data),
    .buf_rd_valid (txbuf_rd_valid),
    .buf_rd_last  (txbuf_rd_last),
    .tx_tdata     (tx_tdata),
    .tx_tvalid    (tx_tvalid),
    .tx_tready    (tx_tready),
    .tx_tlast     (tx_tlast)
);

// Feed gen_busy back to state controller
assign tx_busy = gen_busy;

endmodule
`default_nettype wire
