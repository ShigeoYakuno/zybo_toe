`default_nettype none
// RX frame demultiplexer.
// Receives all frames from MAC (post-CRC removal, AXI-Stream byte-by-byte).
// Inspects EtherType at bytes 12-13, then routes:
//   0x0806 → arp_engine (ARP)
//   0x0800 → tcp_layer  (IPv4/TCP)
//   other  → dropped silently
// Both outputs share the same stream — only one packet in flight at a time.
// Since the input has no backpressure (MAC always produces), we fanout to
// both consumers simultaneously; each consumer ignores frames not for it
// (arp_engine checks its own EtherType, tcp_rx_hdr_dec checks addresses).

module frame_mux (
    input  logic        clk,
    input  logic        rst_n,

    // ---- Input from rmii_mac RX (no backpressure) -------------------------
    input  logic [7:0]  rx_tdata,
    input  logic        rx_tvalid,
    input  logic        rx_tlast,
    input  logic        rx_tuser,   // 1 = CRC error

    // ---- Output to arp_engine ---------------------------------------------
    output logic [7:0]  arp_tdata,
    output logic        arp_tvalid,
    output logic        arp_tlast,
    output logic        arp_tuser,

    // ---- Output to tcp_layer (tcp_rx_hdr_dec) -----------------------------
    output logic [7:0]  tcp_tdata,
    output logic        tcp_tvalid,
    output logic        tcp_tlast,
    output logic        tcp_tuser
);

// Capture EtherType from bytes 12-13
logic [7:0]  eth_type_hi = '0;
logic [7:0]  byte_cnt_low;
logic [7:0]  b_cnt = '0;
logic [15:0] etype;          // assembled EtherType (used in always_ff)

// Route select: latched at byte 13
typedef enum logic [1:0] {
    ROUTE_NONE,
    ROUTE_ARP,
    ROUTE_TCP
} route_t;

route_t route = ROUTE_NONE;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        b_cnt      <= '0;
        route      <= ROUTE_NONE;
        eth_type_hi <= '0;
    end else begin
        if (rx_tvalid) begin
            case (b_cnt)
                8'd12: eth_type_hi <= rx_tdata;
                8'd13: begin
                    etype = {eth_type_hi, rx_tdata};
                    if      (etype == 16'h0806) route <= ROUTE_ARP;
                    else if (etype == 16'h0800) route <= ROUTE_TCP;
                    else                        route <= ROUTE_NONE;
                end
                default: ;
            endcase

            if (rx_tlast) begin
                b_cnt <= '0;
                route <= ROUTE_NONE;
            end else if (b_cnt < 8'd255)
                b_cnt <= b_cnt + 1'b1;
        end
    end
end

// Fanout with route gating
always_comb begin
    // ARP path
    arp_tdata  = rx_tdata;
    arp_tlast  = rx_tlast;
    arp_tuser  = rx_tuser;
    // rx_tlast is always forwarded so consumers can reset their byte counters
    // even for non-routed frames (e.g. IPv6), preventing rx_idx desync.
    arp_tvalid = rx_tvalid && (route == ROUTE_ARP || b_cnt <= 8'd13 || rx_tlast);

    // TCP path
    tcp_tdata  = rx_tdata;
    tcp_tlast  = rx_tlast;
    tcp_tuser  = rx_tuser;
    tcp_tvalid = rx_tvalid && (route == ROUTE_TCP || b_cnt <= 8'd13 || rx_tlast);
end

endmodule
`default_nettype wire
