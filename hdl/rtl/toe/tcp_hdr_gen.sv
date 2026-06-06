`default_nettype none
// TCP TX header generator.
// Receives send request from tcp_state_ctrl, generates Ethernet+IP+TCP frame
// (header + optional payload from tx_buffer) on AXI-Stream to TX arbiter.
//
// Two-pass for data segments:
//   Pass 1 (CSUM_PASS): stream payload bytes from tx_buffer, accumulate checksum
//   Pass 2 (STREAM): send header then payload
//
// Control packets (SYN / ACK / FIN, payload_len=0): single pass — checksum
// computed combinatorially.

module tcp_hdr_gen #(
    parameter WIN_SIZE = 16'd4096  // advertised receive window
)(
    input  logic        clk,
    input  logic        rst_n,

    // ---- Header fields from tcp_state_ctrl --------------------------------
    input  logic        send_req,      // 1-cycle pulse
    input  logic [8:0]  flags,         // NS|CWR|ECE|URG|ACK|PSH|RST|SYN|FIN
    input  logic [31:0] seq_num,
    input  logic [31:0] ack_num,
    input  logic [10:0] payload_len,   // 0 for control packets
    input  logic        payload_en,    // fetch from tx_buffer
    output logic        gen_busy,      // high while generating

    // ---- Addresses (latched from axi4lite_regs on send_req) ---------------
    input  logic [47:0] local_mac,
    input  logic [47:0] remote_mac,
    input  logic [31:0] local_ip,
    input  logic [31:0] remote_ip,
    input  logic [15:0] local_port,
    input  logic [15:0] remote_port,

    // ---- Payload from tx_buffer -------------------------------------------
    // Pass 1: we drive send_req_buf and get rd_data streaming
    output logic        buf_send_req,  // pulse to tx_buffer
    output logic [10:0] buf_send_len,
    input  logic        buf_busy,
    input  logic [7:0]  buf_rd_data,
    input  logic        buf_rd_valid,
    input  logic        buf_rd_last,

    // ---- TX AXI-Stream output to arbiter ----------------------------------
    output logic [7:0]  tx_tdata,
    output logic        tx_tvalid,
    input  logic        tx_tready,
    output logic        tx_tlast
);

// ---- Parameters -----------------------------------------------------------
localparam HDR_LEN = 8'd54;   // Eth(14) + IP(20) + TCP(20)
localparam MIN_LEN = 8'd60;   // Ethernet minimum

// ---- State machine --------------------------------------------------------
typedef enum logic [2:0] {
    S_IDLE,
    S_CSUM_PAYLOAD,   // pass 1: accumulate TCP payload checksum
    S_BUILD,          // compute final checksums → fill hdr_buf
    S_SEND_HDR,       // stream header bytes
    S_SEND_PAYLOAD,   // pass 2: re-stream payload
    S_SEND_PAD        // zero-pad to 60 bytes minimum
} state_t;
state_t state = S_IDLE;

// ---- Latched parameters ---------------------------------------------------
logic [47:0] l_dst_mac, l_src_mac;
logic [31:0] l_src_ip, l_dst_ip;
logic [15:0] l_src_port, l_dst_port;
logic [31:0] l_seq, l_ack;
logic [8:0]  l_flags;
logic [10:0] l_plen;
logic        l_pload;

// ---- Partial TCP checksum (pseudo-hdr + TCP fixed header) -----------------
// Computed combinatorially from latched parameters.
function automatic [31:0] tcp_partial_csum;
    input [31:0] src_ip, dst_ip;
    input [15:0] src_port, dst_port;
    input [31:0] seq, ack;
    input [8:0]  flags;
    input [15:0] payload_len;
    logic [31:0] s;
    begin
        // Pseudo-header
        s = src_ip[31:16] + src_ip[15:0]
          + dst_ip[31:16] + dst_ip[15:0]
          + 32'h0000_0006                      // proto=6
          + {16'h0, payload_len + 16'd20};     // TCP length (hdr + payload)
        // TCP header (checksum field = 0, urgent = 0)
        s += {16'h0, src_port};
        s += {16'h0, dst_port};
        s += {seq[31:16]};
        s += {seq[15:0]};
        s += {ack[31:16]};
        s += {ack[15:0]};
        s += 32'h0000_5000;   // data_off=5, reserved=0 → 0x50 in high byte
        s += {16'h0, 7'h0, flags[7:0]};
        s += {16'h0, WIN_SIZE};
        // urgent = 0
        tcp_partial_csum = s;
    end
endfunction

function automatic [15:0] fold32;
    input [31:0] s;
    logic [16:0] t;
    begin
        t     = {1'b0, s[31:16]} + {1'b0, s[15:0]};
        fold32 = t[15:0] + {15'h0, t[16]};
    end
endfunction

function automatic [15:0] fold17;
    input [16:0] s;
    fold17 = s[15:0] + {15'h0, s[16]};
endfunction

// ---- IP checksum ----------------------------------------------------------
function automatic [15:0] ip_checksum;
    input [31:0] src_ip, dst_ip;
    input [15:0] total_len;
    logic [31:0] s;
    begin
        s = 32'h4500         // ver=4, IHL=5, DSCP=0, ECN=0
          + {16'h0, total_len}
          + 32'h4000         // id=0, DF flag
          + 32'h4006;        // TTL=64, proto=6
        // skip checksum field (=0)
        s += {16'h0, src_ip[31:16]} + {16'h0, src_ip[15:0]};
        s += {16'h0, dst_ip[31:16]} + {16'h0, dst_ip[15:0]};
        ip_checksum = ~fold32(s);
    end
endfunction

// ---- 60-byte header buffer ------------------------------------------------
logic [7:0] hdr_buf [0:59];
logic [6:0] tx_ptr;    // header byte index
logic [10:0] pay_cnt;  // payload byte remaining

// ---- Payload checksum accumulator (pass 1) --------------------------------
logic [31:0] pay_csum_acc = '0;
logic        pay_csum_phase = 1'b0;
logic [7:0]  pay_csum_prev  = '0;

// ---- Build header buffer task (called before streaming) -------------------
task build_hdr;
    logic [15:0] ip_total;
    logic [15:0] ip_csum_val;
    logic [31:0] tcp_base;
    logic [31:0] tcp_with_pay;
    logic [15:0] tcp_csum_val;
    logic [15:0] pay_len16;
    begin
        pay_len16  = {5'h0, l_plen};
        ip_total   = 16'd40 + pay_len16;  // IP(20)+TCP(20)+payload
        ip_csum_val = ip_checksum(l_src_ip, l_dst_ip, ip_total);

        // TCP checksum = partial + payload_csum (already accumulated)
        tcp_base     = tcp_partial_csum(l_src_ip, l_dst_ip, l_src_port, l_dst_port,
                                        l_seq, l_ack, l_flags, pay_len16);
        tcp_with_pay = tcp_base + pay_csum_acc;
        tcp_csum_val = ~fold32(tcp_with_pay);

        // Ethernet header
        hdr_buf[0]  = l_dst_mac[47:40]; hdr_buf[1]  = l_dst_mac[39:32];
        hdr_buf[2]  = l_dst_mac[31:24]; hdr_buf[3]  = l_dst_mac[23:16];
        hdr_buf[4]  = l_dst_mac[15:8];  hdr_buf[5]  = l_dst_mac[7:0];
        hdr_buf[6]  = l_src_mac[47:40]; hdr_buf[7]  = l_src_mac[39:32];
        hdr_buf[8]  = l_src_mac[31:24]; hdr_buf[9]  = l_src_mac[23:16];
        hdr_buf[10] = l_src_mac[15:8];  hdr_buf[11] = l_src_mac[7:0];
        hdr_buf[12] = 8'h08;            hdr_buf[13] = 8'h00;  // EtherType IPv4

        // IP header (20 bytes)
        hdr_buf[14] = 8'h45;  // ver=4, IHL=5
        hdr_buf[15] = 8'h00;  // DSCP/ECN
        hdr_buf[16] = ip_total[15:8];   hdr_buf[17] = ip_total[7:0];
        hdr_buf[18] = 8'h00;            hdr_buf[19] = 8'h00;  // id=0
        hdr_buf[20] = 8'h40;            hdr_buf[21] = 8'h00;  // DF, frag=0
        hdr_buf[22] = 8'd64;            hdr_buf[23] = 8'd6;   // TTL=64, proto=TCP
        hdr_buf[24] = ip_csum_val[15:8];hdr_buf[25] = ip_csum_val[7:0];
        hdr_buf[26] = l_src_ip[31:24];  hdr_buf[27] = l_src_ip[23:16];
        hdr_buf[28] = l_src_ip[15:8];   hdr_buf[29] = l_src_ip[7:0];
        hdr_buf[30] = l_dst_ip[31:24];  hdr_buf[31] = l_dst_ip[23:16];
        hdr_buf[32] = l_dst_ip[15:8];   hdr_buf[33] = l_dst_ip[7:0];

        // TCP header (20 bytes)
        hdr_buf[34] = l_src_port[15:8]; hdr_buf[35] = l_src_port[7:0];
        hdr_buf[36] = l_dst_port[15:8]; hdr_buf[37] = l_dst_port[7:0];
        hdr_buf[38] = l_seq[31:24];     hdr_buf[39] = l_seq[23:16];
        hdr_buf[40] = l_seq[15:8];      hdr_buf[41] = l_seq[7:0];
        hdr_buf[42] = l_ack[31:24];     hdr_buf[43] = l_ack[23:16];
        hdr_buf[44] = l_ack[15:8];      hdr_buf[45] = l_ack[7:0];
        hdr_buf[46] = 8'h50;            // data offset=5, reserved=0
        hdr_buf[47] = {3'h0, l_flags[5:0]};  // flags (URG..FIN lower 6)
        hdr_buf[48] = WIN_SIZE[15:8];   hdr_buf[49] = WIN_SIZE[7:0];
        hdr_buf[50] = tcp_csum_val[15:8]; hdr_buf[51] = tcp_csum_val[7:0];
        hdr_buf[52] = 8'h00;            hdr_buf[53] = 8'h00;  // urgent=0

        // Padding for minimum 60-byte Ethernet frame (only for ctrl packets)
        for (int i = 54; i < 60; i++) hdr_buf[i] = 8'h00;
    end
endtask

// ---- Main state machine ---------------------------------------------------
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state         <= S_IDLE;
        gen_busy      <= 1'b0;
        tx_tvalid     <= 1'b0;
        tx_tlast      <= 1'b0;
        tx_tdata      <= 8'h00;
        tx_ptr        <= '0;
        pay_cnt       <= '0;
        pay_csum_acc  <= '0;
        pay_csum_phase <= 1'b0;
        buf_send_req  <= 1'b0;
        buf_send_len  <= '0;
    end else begin
        tx_tvalid    <= 1'b0;
        tx_tlast     <= 1'b0;
        buf_send_req <= 1'b0;

        case (state)

        S_IDLE: begin
            gen_busy <= 1'b0;
            if (send_req) begin
                // Latch parameters
                l_dst_mac  <= remote_mac;  l_src_mac  <= local_mac;
                l_src_ip   <= local_ip;    l_dst_ip   <= remote_ip;
                l_src_port <= local_port;  l_dst_port <= remote_port;
                l_seq      <= seq_num;     l_ack      <= ack_num;
                l_flags    <= flags;       l_plen     <= payload_len;
                l_pload    <= payload_en;
                gen_busy   <= 1'b1;

                pay_csum_acc   <= '0;
                pay_csum_phase <= 1'b0;

                if (payload_en && payload_len != '0) begin
                    // Start payload checksum pass
                    buf_send_req <= 1'b1;
                    buf_send_len <= payload_len;
                    state <= S_CSUM_PAYLOAD;
                end else begin
                    // Control packet — no payload
                    build_hdr();
                    state  <= S_SEND_HDR;
                    tx_ptr <= 7'd0;
                end
            end
        end

        S_CSUM_PAYLOAD: begin
            if (buf_rd_valid) begin
                if (pay_csum_phase == 1'b0) begin
                    pay_csum_prev  <= buf_rd_data;
                    pay_csum_phase <= 1'b1;
                end else begin
                    pay_csum_acc   <= pay_csum_acc
                                    + {16'h0, pay_csum_prev, buf_rd_data};
                    pay_csum_phase <= 1'b0;
                end
                if (buf_rd_last) begin
                    // Handle odd last byte
                    if (pay_csum_phase == 1'b0)  // was storing high byte
                        pay_csum_acc <= pay_csum_acc
                                      + {16'h0, buf_rd_data, 8'h00};
                    state <= S_BUILD;
                end
            end
        end

        S_BUILD: begin
            // Build header with final checksums (combinatorial helper called)
            build_hdr();
            // Re-arm tx_buffer for second pass
            buf_send_req <= 1'b1;
            buf_send_len <= l_plen;
            pay_cnt      <= l_plen;
            state        <= S_SEND_HDR;
            tx_ptr       <= 7'd0;
        end

        S_SEND_HDR: begin
            tx_tvalid <= 1'b1;
            tx_tdata  <= hdr_buf[tx_ptr];
            if (tx_tready) begin
                if (tx_ptr == 7'd53) begin
                    // Header done
                    if (l_pload && l_plen != '0)
                        state <= S_SEND_PAYLOAD;
                    else if (7'd53 < 7'd59) begin
                        state  <= S_SEND_PAD;
                        tx_ptr <= 7'd54;
                    end else begin
                        tx_tlast <= 1'b1;
                        state    <= S_IDLE;
                    end
                end else
                    tx_ptr <= tx_ptr + 1'b1;
            end
        end

        S_SEND_PAYLOAD: begin
            if (buf_rd_valid) begin
                tx_tdata  <= buf_rd_data;
                tx_tvalid <= 1'b1;
                if (buf_rd_last) begin
                    tx_tlast <= 1'b1;
                    state    <= S_IDLE;
                    gen_busy <= 1'b0;
                end
            end
        end

        S_SEND_PAD: begin
            tx_tvalid <= 1'b1;
            tx_tdata  <= 8'h00;
            if (tx_tready) begin
                if (tx_ptr == 7'd59) begin
                    tx_tlast <= 1'b1;
                    state    <= S_IDLE;
                    gen_busy <= 1'b0;
                end else
                    tx_ptr <= tx_ptr + 1'b1;
            end
        end

        endcase
    end
end

endmodule
`default_nettype wire
