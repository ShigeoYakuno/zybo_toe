`default_nettype none
// ARP engine — handles ARP request (MAC resolution) and ARP reply.
//
// RX interface (push-only from frame_mux, already confirmed EtherType=0x0806):
//   rx_tdata / rx_tvalid / rx_tlast / rx_tuser (CRC error)
//
// TX interface (AXI-Stream to toe_engine TX arbiter):
//   tx_tdata / tx_tvalid / tx_tready / tx_tlast
//
// Control:
//   send_req           — ARM requested ARP (assert once per connection attempt)
//   target_ip          — IP to resolve
//   local_mac / local_ip
//   target_mac_o       — resolved MAC (valid when target_mac_valid)
//   target_mac_valid   — high after ARP reply received

module arp_engine #(
    parameter CLK_HZ = 50_000_000
)(
    input  logic        clk,
    input  logic        rst_n,

    // ---- Configuration (static during operation) --------------------------
    input  logic [47:0] local_mac,
    input  logic [31:0] local_ip,
    input  logic [31:0] target_ip,

    // ---- ARP request trigger ----------------------------------------------
    input  logic        send_req,         // 1-cycle pulse: resolve target_ip
    output logic        target_mac_valid, // resolved MAC is stable
    output logic [47:0] target_mac_o,

    // ---- RX from frame_mux (ARP frames only) ------------------------------
    input  logic [7:0]  rx_tdata,
    input  logic        rx_tvalid,
    input  logic        rx_tlast,
    input  logic        rx_tuser,         // 1 = CRC error (drop)

    // ---- TX to arbiter ----------------------------------------------------
    output logic [7:0]  tx_tdata,
    output logic        tx_tvalid,
    input  logic        tx_tready,
    output logic        tx_tlast
);

// ---- ARP packet layout (after Ethernet header, offset in stream) ----------
// Byte indices in the full Ethernet frame (Dst MAC + Src MAC + EtherType already received by mux):
//  0-5  = Dst MAC (sent in preamble from mux — we skip and re-parse)
// ARP frame starts at byte 0 of what frame_mux sends us:
//  0-13  = Ethernet header (we re-parse Src MAC from bytes 6-11)
//  14-41 = ARP payload

// ---- RX byte capture ------------------------------------------------------
logic [5:0] rx_idx;
logic [5:0] nxt;       // TX pointer next value (used in always_ff)
logic [47:0] rx_sha;   // sender hardware address
logic [31:0] rx_spa;   // sender protocol address
logic [31:0] rx_tpa;   // target protocol address
logic [15:0] rx_oper;
logic        rx_bad;   // CRC error flag

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rx_idx  <= '0;
        rx_sha  <= '0;
        rx_spa  <= '0;
        rx_tpa  <= '0;
        rx_oper <= '0;
        rx_bad  <= 1'b0;
    end else begin
        if (rx_tvalid) begin
            if (rx_tuser) rx_bad <= 1'b1;  // latch CRC error
            case (rx_idx)
                // Bytes 6-11: Src MAC = ARP sender hardware address (in Eth header)
                6'd6:  rx_sha[47:40] <= rx_tdata;
                6'd7:  rx_sha[39:32] <= rx_tdata;
                6'd8:  rx_sha[31:24] <= rx_tdata;
                6'd9:  rx_sha[23:16] <= rx_tdata;
                6'd10: rx_sha[15:8]  <= rx_tdata;
                6'd11: rx_sha[7:0]   <= rx_tdata;
                // ARP OPER bytes 20-21
                6'd20: rx_oper[15:8] <= rx_tdata;
                6'd21: rx_oper[7:0]  <= rx_tdata;
                // ARP SHA bytes 22-27
                6'd22: rx_sha[47:40] <= rx_tdata;
                6'd23: rx_sha[39:32] <= rx_tdata;
                6'd24: rx_sha[31:24] <= rx_tdata;
                6'd25: rx_sha[23:16] <= rx_tdata;
                6'd26: rx_sha[15:8]  <= rx_tdata;
                6'd27: rx_sha[7:0]   <= rx_tdata;
                // ARP SPA bytes 28-31
                6'd28: rx_spa[31:24] <= rx_tdata;
                6'd29: rx_spa[23:16] <= rx_tdata;
                6'd30: rx_spa[15:8]  <= rx_tdata;
                6'd31: rx_spa[7:0]   <= rx_tdata;
                // ARP TPA bytes 38-41
                6'd38: rx_tpa[31:24] <= rx_tdata;
                6'd39: rx_tpa[23:16] <= rx_tdata;
                6'd40: rx_tpa[15:8]  <= rx_tdata;
                6'd41: rx_tpa[7:0]   <= rx_tdata;
                default: ;
            endcase

            if (rx_tlast) begin
                rx_idx <= '0;
                rx_bad <= 1'b0;
            end else if (rx_idx < 6'd63)
                rx_idx <= rx_idx + 1'b1;
        end
    end
end

// ---- ARP frame classifier (registered when rx_tlast arrives) --------------
typedef enum logic [2:0] {
    ARP_IDLE,
    ARP_DO_REQUEST,  // send ARP Request broadcast
    ARP_WAIT_REPLY,  // waiting for ARP Reply
    ARP_DO_REPLY,    // send ARP Reply to requester
    ARP_RESOLVED     // target MAC is cached
} arp_state_t;

arp_state_t arp_state = ARP_IDLE;

// Retransmit timer: 1 second at 50 MHz
localparam RETRY_CNT = CLK_HZ;
logic [25:0] retry_timer = '0;
logic        retry_pulse;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        retry_timer <= '0;
        retry_pulse <= 1'b0;
    end else begin
        retry_pulse <= 1'b0;
        if (arp_state == ARP_WAIT_REPLY) begin
            if (retry_timer == RETRY_CNT[25:0] - 1'b1) begin
                retry_timer <= '0;
                retry_pulse <= 1'b1;
            end else
                retry_timer <= retry_timer + 1'b1;
        end else
            retry_timer <= '0;
    end
end

// Incoming ARP event (evaluated at rx_tlast)
logic rx_is_request; // incoming ARP request for our IP
logic rx_is_reply;   // incoming ARP reply from target
assign rx_is_request = (rx_oper == 16'h0001) && (rx_tpa == local_ip) && !rx_bad;
assign rx_is_reply   = (rx_oper == 16'h0002) && (rx_spa == target_ip) && !rx_bad;

// Pending TX actions
logic do_request = 1'b0;
logic do_reply   = 1'b0;
logic [47:0] reply_dst_mac = '0;
logic [31:0] reply_dst_ip  = '0;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        arp_state       <= ARP_IDLE;
        target_mac_valid <= 1'b0;
        target_mac_o    <= '0;
        do_request      <= 1'b0;
        do_reply        <= 1'b0;
    end else begin
        // Process incoming ARP frames at end-of-frame
        if (rx_tvalid && rx_tlast && !rx_bad) begin
            if (rx_is_reply && (arp_state == ARP_WAIT_REPLY || arp_state == ARP_DO_REQUEST)) begin
                target_mac_o     <= rx_sha;
                target_mac_valid <= 1'b1;
                arp_state        <= ARP_RESOLVED;
            end
            if (rx_is_request) begin
                reply_dst_mac <= rx_sha;
                reply_dst_ip  <= rx_spa;
                do_reply      <= 1'b1;
            end
        end

        // Send request trigger
        if (send_req && arp_state == ARP_IDLE) begin
            target_mac_valid <= 1'b0;
            arp_state        <= ARP_WAIT_REPLY;
            do_request       <= 1'b1;
        end

        // Retransmit request
        if (retry_pulse)
            do_request <= 1'b1;

        // Clear flags after TX starts
        if (tx_send_start) begin
            do_request <= 1'b0;
            do_reply   <= 1'b0;
        end
    end
end

// ---- TX packet assembly ---------------------------------------------------
// ARP Request = 60 bytes, ARP Reply = 60 bytes (Eth min frame)
logic [7:0] pkt_buf [0:59];
logic [5:0] tx_ptr    = '0;
logic       tx_active = 1'b0;
logic       tx_send_start;
logic       is_reply_pkt;

assign tx_send_start = !tx_active && (do_reply || do_request);
assign is_reply_pkt  = do_reply;  // reply has higher priority

// Target MAC for packet header
logic [47:0] pkt_dst_mac;
logic [47:0] pkt_arp_tha;
logic [31:0] pkt_arp_tpa;
assign pkt_dst_mac  = is_reply_pkt ? reply_dst_mac : 48'hFFFF_FFFF_FFFF;
assign pkt_arp_tha  = is_reply_pkt ? reply_dst_mac : 48'h0;
assign pkt_arp_tpa  = is_reply_pkt ? reply_dst_ip  : target_ip;

// Build packet buffer combinatorially from current parameters
always_comb begin
    // Ethernet header
    pkt_buf[0]  = pkt_dst_mac[47:40]; pkt_buf[1]  = pkt_dst_mac[39:32];
    pkt_buf[2]  = pkt_dst_mac[31:24]; pkt_buf[3]  = pkt_dst_mac[23:16];
    pkt_buf[4]  = pkt_dst_mac[15:8];  pkt_buf[5]  = pkt_dst_mac[7:0];
    pkt_buf[6]  = local_mac[47:40];   pkt_buf[7]  = local_mac[39:32];
    pkt_buf[8]  = local_mac[31:24];   pkt_buf[9]  = local_mac[23:16];
    pkt_buf[10] = local_mac[15:8];    pkt_buf[11] = local_mac[7:0];
    pkt_buf[12] = 8'h08;              pkt_buf[13] = 8'h06;   // EtherType ARP
    // ARP header
    pkt_buf[14] = 8'h00; pkt_buf[15] = 8'h01;  // HTYPE Ethernet
    pkt_buf[16] = 8'h08; pkt_buf[17] = 8'h00;  // PTYPE IPv4
    pkt_buf[18] = 8'h06; pkt_buf[19] = 8'h04;  // HLEN=6 PLEN=4
    pkt_buf[20] = 8'h00; pkt_buf[21] = is_reply_pkt ? 8'h02 : 8'h01; // OPER
    // SHA = local MAC
    pkt_buf[22] = local_mac[47:40];   pkt_buf[23] = local_mac[39:32];
    pkt_buf[24] = local_mac[31:24];   pkt_buf[25] = local_mac[23:16];
    pkt_buf[26] = local_mac[15:8];    pkt_buf[27] = local_mac[7:0];
    // SPA = local IP
    pkt_buf[28] = local_ip[31:24];    pkt_buf[29] = local_ip[23:16];
    pkt_buf[30] = local_ip[15:8];     pkt_buf[31] = local_ip[7:0];
    // THA
    pkt_buf[32] = pkt_arp_tha[47:40]; pkt_buf[33] = pkt_arp_tha[39:32];
    pkt_buf[34] = pkt_arp_tha[31:24]; pkt_buf[35] = pkt_arp_tha[23:16];
    pkt_buf[36] = pkt_arp_tha[15:8];  pkt_buf[37] = pkt_arp_tha[7:0];
    // TPA
    pkt_buf[38] = pkt_arp_tpa[31:24]; pkt_buf[39] = pkt_arp_tpa[23:16];
    pkt_buf[40] = pkt_arp_tpa[15:8];  pkt_buf[41] = pkt_arp_tpa[7:0];
    // Padding
    for (int i = 42; i < 60; i++) pkt_buf[i] = 8'h00;
end

// TX streaming state machine
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tx_active <= 1'b0;
        tx_ptr    <= '0;
        tx_tvalid <= 1'b0;
        tx_tlast  <= 1'b0;
        tx_tdata  <= 8'h00;
    end else begin
        if (tx_send_start) begin
            tx_active <= 1'b1;
            tx_ptr    <= 6'd0;
            tx_tdata  <= pkt_buf[0];
            tx_tvalid <= 1'b1;
            tx_tlast  <= 1'b0;
        end else if (tx_active && tx_tready) begin
            if (tx_tlast) begin
                tx_active <= 1'b0;
                tx_tvalid <= 1'b0;
                tx_tlast  <= 1'b0;
            end else begin
                nxt = tx_ptr + 1'b1;
                tx_ptr   <= nxt;
                tx_tdata <= pkt_buf[nxt];
                tx_tvalid <= 1'b1;
                tx_tlast  <= (nxt == 6'd59);
            end
        end
    end
end

endmodule
`default_nettype wire
