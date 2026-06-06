`default_nettype none
// UDP engine top-level.
// Instantiates: frame_mux, arp_engine, udp_layer, TX arbiter.

module toe_engine #(
    parameter PAYLOAD_BYTES = 64,
    parameter CLK_HZ        = 50_000_000
)(
    input  logic        clk,
    input  logic        rst_n,

    // Config (clk domain, from axi4lite_regs)
    input  logic [47:0] local_mac,
    input  logic [47:0] remote_mac,
    input  logic [31:0] local_ip,
    input  logic [31:0] remote_ip,
    input  logic [15:0] local_port,
    input  logic [15:0] remote_port,
    input  logic        addr_valid,

    // ARM control (2FF-synced, clk domain)
    input  logic        send_req,

    // ARP
    input  logic        arp_send_req,
    output logic        arp_mac_valid,
    output logic [47:0] arp_mac_o,

    // TX data from ARM (clk domain, via async FIFO in axi4lite_regs)
    input  logic [7:0]  tx_wr_data,
    input  logic        tx_wr_en,
    output logic        tx_wr_full,

    // RX data to ARM (clk domain, async FIFO in axi4lite_regs)
    output logic [7:0]  rx_rd_data,
    input  logic        rx_rd_en,
    output logic        rx_rd_empty,
    output logic [11:0] rx_rd_count,

    // RX from MAC (AXI-Stream, no backpressure)
    input  logic [7:0]  mac_rx_tdata,
    input  logic        mac_rx_tvalid,
    input  logic        mac_rx_tlast,
    input  logic        mac_rx_tuser,

    // TX to MAC (AXI-Stream with backpressure)
    output logic [7:0]  mac_tx_tdata,
    output logic        mac_tx_tvalid,
    input  logic        mac_tx_tready,
    output logic        mac_tx_tlast,

    // Status
    output logic        tx_busy
);

// ---- RX frame mux -----------------------------------------------------------
logic [7:0]  arp_rx_tdata,  udp_rx_tdata;
logic        arp_rx_tvalid, udp_rx_tvalid;
logic        arp_rx_tlast,  udp_rx_tlast;
logic        arp_rx_tuser,  udp_rx_tuser;

frame_mux u_mux (
    .clk        (clk),
    .rst_n      (rst_n),
    .rx_tdata   (mac_rx_tdata),
    .rx_tvalid  (mac_rx_tvalid),
    .rx_tlast   (mac_rx_tlast),
    .rx_tuser   (mac_rx_tuser),
    .arp_tdata  (arp_rx_tdata),
    .arp_tvalid (arp_rx_tvalid),
    .arp_tlast  (arp_rx_tlast),
    .arp_tuser  (arp_rx_tuser),
    .tcp_tdata  (udp_rx_tdata),
    .tcp_tvalid (udp_rx_tvalid),
    .tcp_tlast  (udp_rx_tlast),
    .tcp_tuser  (udp_rx_tuser)
);

// ---- ARP engine -------------------------------------------------------------
logic [7:0]  arp_tx_tdata;
logic        arp_tx_tvalid, arp_tx_tlast;

arp_engine #(
    .CLK_HZ (CLK_HZ)
) u_arp (
    .clk              (clk),
    .rst_n            (rst_n),
    .local_mac        (local_mac),
    .local_ip         (local_ip),
    .target_ip        (remote_ip),
    .send_req         (arp_send_req),
    .target_mac_valid (arp_mac_valid),
    .target_mac_o     (arp_mac_o),
    .rx_tdata         (arp_rx_tdata),
    .rx_tvalid        (arp_rx_tvalid),
    .rx_tlast         (arp_rx_tlast),
    .rx_tuser         (arp_rx_tuser),
    .tx_tdata         (arp_tx_tdata),
    .tx_tvalid        (arp_tx_tvalid),
    .tx_tready        (arp_tx_tvalid ? mac_tx_tready : 1'b0),
    .tx_tlast         (arp_tx_tlast)
);

// ---- UDP layer --------------------------------------------------------------
logic [7:0]  udp_tx_tdata;
logic        udp_tx_tvalid, udp_tx_tlast;

udp_layer #(
    .PAYLOAD_BYTES (PAYLOAD_BYTES),
    .CLK_HZ        (CLK_HZ)
) u_udp (
    .clk          (clk),
    .rst_n        (rst_n),
    .local_mac    (local_mac),
    .remote_mac   (remote_mac),
    .local_ip     (local_ip),
    .remote_ip    (remote_ip),
    .local_port   (local_port),
    .remote_port  (remote_port),
    .send_req     (send_req),
    .tx_wr_data   (tx_wr_data),
    .tx_wr_en     (tx_wr_en),
    .tx_wr_full   (tx_wr_full),
    .rx_rd_data   (rx_rd_data),
    .rx_rd_en     (rx_rd_en),
    .rx_rd_empty  (rx_rd_empty),
    .rx_rd_count  (rx_rd_count),
    .tx_busy      (tx_busy),
    .rx_tdata     (udp_rx_tdata),
    .rx_tvalid    (udp_rx_tvalid),
    .rx_tlast     (udp_rx_tlast),
    .rx_tuser     (udp_rx_tuser),
    .tx_tdata     (udp_tx_tdata),
    .tx_tvalid    (udp_tx_tvalid),
    .tx_tready    (arp_tx_tvalid ? 1'b0 : mac_tx_tready),
    .tx_tlast     (udp_tx_tlast)
);

// ---- TX arbiter: ARP has priority ------------------------------------------
always_comb begin
    if (arp_tx_tvalid) begin
        mac_tx_tdata  = arp_tx_tdata;
        mac_tx_tvalid = arp_tx_tvalid;
        mac_tx_tlast  = arp_tx_tlast;
    end else begin
        mac_tx_tdata  = udp_tx_tdata;
        mac_tx_tvalid = udp_tx_tvalid;
        mac_tx_tlast  = udp_tx_tlast;
    end
end

endmodule
`default_nettype wire
