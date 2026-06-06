`default_nettype none
// TCP RX header decoder.
// Receives raw Ethernet frames (from frame_mux, EtherType 0x0800 only).
// Validates: IP version, protocol=TCP, addresses, ports, checksums.
// Extracts: seq, ack, flags, window, payload.
// Writes valid payload bytes to rx_buffer.
// Ports: input byte stream (no backpressure), output to tcp_state_ctrl + rx_buffer.

module tcp_rx_hdr_dec (
    input  logic        clk,
    input  logic        rst_n,

    // ---- RX byte stream (IP-only frames from frame_mux) ------------------
    input  logic [7:0]  rx_tdata,
    input  logic        rx_tvalid,
    input  logic        rx_tlast,
    input  logic        rx_tuser,   // 1 = CRC error

    // ---- Expected addresses (from tcp_state_ctrl / axi4lite_regs) ---------
    input  logic [47:0] local_mac,
    input  logic [47:0] remote_mac,
    input  logic [31:0] local_ip,
    input  logic [31:0] remote_ip,
    input  logic [15:0] local_port,
    input  logic [15:0] remote_port,
    input  logic        addr_valid,  // addresses are configured

    // ---- Decoded packet info (to tcp_state_ctrl) -------------------------
    output logic        pkt_valid,
    output logic        rx_syn,
    output logic        rx_ack,
    output logic        rx_fin,
    output logic        rx_rst,
    output logic [31:0] rx_seq_num,
    output logic [31:0] rx_ack_num,
    output logic [15:0] rx_win_size,
    output logic [15:0] rx_payload_len,

    // ---- Payload → rx_buffer ---------------------------------------------
    output logic [7:0]  pl_data,
    output logic        pl_wr_en,
    input  logic        pl_full
);

// ---- Byte counter and captured header fields ------------------------------
logic [7:0]  byte_cnt = '0;  // position within current frame
logic        crc_err  = 1'b0;

// Eth header captures
logic [47:0] cap_dst_mac = '0;
logic [47:0] cap_src_mac = '0;
logic [15:0] cap_eth_type = '0;

// IP header captures (bytes 14-33)
logic [3:0]  cap_ihl    = 4'd5;
logic [15:0] cap_ip_total_len = '0;
logic [7:0]  cap_ip_proto = '0;
logic [31:0] cap_src_ip = '0;
logic [31:0] cap_dst_ip = '0;
logic [7:0]  ip_hdr_byte = '0; // staging for even-byte pairs

// TCP header captures (bytes 34+, offset=14+IHL*4)
// For fixed IHL=5, TCP starts at byte 34
logic [15:0] cap_src_port = '0;
logic [15:0] cap_dst_port = '0;
logic [31:0] cap_seq_num  = '0;
logic [31:0] cap_ack_num  = '0;
logic [3:0]  cap_data_off = 4'd5;
logic [7:0]  cap_flags    = '0;
logic [15:0] cap_win_size = '0;
logic [15:0] cap_payload_len = '0;
logic [7:0]  prev_byte    = '0;  // for 16-bit field assembly

// State machine
typedef enum logic [2:0] {
    S_ETH, S_IP, S_TCP_HDR, S_PAYLOAD, S_DRAIN
} state_t;
state_t state = S_ETH;

// TCP start byte (= 14 + ihl*4)
logic [7:0] tcp_start;
assign tcp_start = 8'd14 + {4'h0, cap_ihl, 2'b00};

// TCP payload start (= tcp_start + data_off*4)
logic [7:0] pl_start;
assign pl_start = tcp_start + {4'h0, cap_data_off, 2'b00};

// Payload write
assign pl_wr_en = rx_tvalid && (state == S_PAYLOAD) && !crc_err && !pl_full;
assign pl_data  = rx_tdata;

// Temporaries used inside always_ff (must be module-level for Vivado)
logic [15:0] tcp_len_val;
logic [16:0] sum;
logic [31:0] ps_sum;

// ---- IP checksum (1's complement running sum) -----------------------------
// We compute over IP header (bytes 14 to tcp_start-1).
// A valid header gives checksum = 0xFFFF.
logic [16:0] ip_csum  = '0;  // 17-bit to hold carry
logic        ip_csum_valid = 1'b0;

// ---- TCP checksum (pseudo-header + TCP header + payload) ------------------
logic [16:0] tcp_csum = '0;
logic        tcp_phase = 1'b0;  // 0=high, 1=low byte of 16-bit word
logic        tcp_csum_valid = 1'b0;

// ---- Main byte processing -------------------------------------------------
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        byte_cnt     <= '0;
        state        <= S_ETH;
        crc_err      <= 1'b0;
        pkt_valid    <= 1'b0;
        cap_payload_len <= '0;
        ip_csum      <= '0;
        tcp_csum     <= '0;
        tcp_phase    <= 1'b0;
    end else begin
        pkt_valid <= 1'b0;

        if (rx_tvalid) begin
            if (rx_tuser) crc_err <= 1'b1;
            prev_byte <= rx_tdata;

            case (state)

            // ---- Ethernet header (bytes 0-13) ----------------------------
            S_ETH: begin
                case (byte_cnt)
                    // Dst MAC [0-5]
                    8'd0: cap_dst_mac[47:40] <= rx_tdata;
                    8'd1: cap_dst_mac[39:32] <= rx_tdata;
                    8'd2: cap_dst_mac[31:24] <= rx_tdata;
                    8'd3: cap_dst_mac[23:16] <= rx_tdata;
                    8'd4: cap_dst_mac[15:8]  <= rx_tdata;
                    8'd5: cap_dst_mac[7:0]   <= rx_tdata;
                    // Src MAC [6-11]
                    8'd6:  cap_src_mac[47:40] <= rx_tdata;
                    8'd7:  cap_src_mac[39:32] <= rx_tdata;
                    8'd8:  cap_src_mac[31:24] <= rx_tdata;
                    8'd9:  cap_src_mac[23:16] <= rx_tdata;
                    8'd10: cap_src_mac[15:8]  <= rx_tdata;
                    8'd11: cap_src_mac[7:0]   <= rx_tdata;
                    // EtherType [12-13]
                    8'd12: cap_eth_type[15:8] <= rx_tdata;
                    8'd13: begin
                        cap_eth_type[7:0] <= rx_tdata;
                        // reset IP checksum accumulator
                        ip_csum  <= '0;
                        tcp_csum <= '0;
                    end
                    default: ;
                endcase
                if (byte_cnt == 8'd13) begin
                    state     <= S_IP;
                    byte_cnt  <= '0;
                end else
                    byte_cnt <= byte_cnt + 1'b1;
            end

            // ---- IP header (bytes 14+, indexed relative to IP start) -----
            S_IP: begin
                case (byte_cnt)
                    8'd0: begin
                        cap_ihl           <= rx_tdata[3:0];
                        // init TCP checksum with protocol (byte 0 of pseudo-hdr)
                        tcp_csum <= '0;
                    end
                    8'd2:  cap_ip_total_len[15:8] <= rx_tdata;
                    8'd3:  cap_ip_total_len[7:0]  <= rx_tdata;
                    8'd9:  cap_ip_proto           <= rx_tdata;
                    8'd12: cap_src_ip[31:24] <= rx_tdata;
                    8'd13: cap_src_ip[23:16] <= rx_tdata;
                    8'd14: cap_src_ip[15:8]  <= rx_tdata;
                    8'd15: cap_src_ip[7:0]   <= rx_tdata;
                    8'd16: cap_dst_ip[31:24] <= rx_tdata;
                    8'd17: cap_dst_ip[23:16] <= rx_tdata;
                    8'd18: cap_dst_ip[15:8]  <= rx_tdata;
                    8'd19: begin
                        cap_dst_ip[7:0] <= rx_tdata;
                        // Compute TCP pseudo-header checksum contribution:
                        // src_ip + dst_ip + 0x0006 + tcp_len
                        // tcp_len = total_len - ihl*4
                        tcp_len_val = cap_ip_total_len - {6'h0, cap_ihl, 2'b00};
                        // Will be added after IP header
                        cap_payload_len <= tcp_len_val - 16'd20;  // TCP hdr = 20
                    end
                    default: ;
                endcase

                // Accumulate IP checksum over IP header bytes
                if (byte_cnt[0] == 1'b0) begin  // even: save high byte
                    ip_hdr_byte <= rx_tdata;
                end else begin  // odd: add 16-bit word
                    sum     = ip_csum + {1'b0, ip_hdr_byte, rx_tdata};
                    ip_csum <= {1'b0, sum[15:0]} + {16'h0, sum[16]};
                end

                // Transition to TCP header at end of IP header
                if (byte_cnt == ({4'h0, cap_ihl, 2'b00} - 8'd1)) begin
                    // Verify checksum = 0xFFFF
                    ip_csum_valid <= (ip_csum == 17'h0FFFF);
                    // Seed TCP checksum with pseudo-header
                    // proto=6, src_ip, dst_ip, tcp_len (cap_payload_len+20)
                    ps_sum = {16'h0, cap_src_ip[31:16]}
                           + {16'h0, cap_src_ip[15:0]}
                           + {16'h0, cap_dst_ip[31:16]}
                           + {16'h0, cap_dst_ip[15:0]}
                           + 32'h0000_0006
                           + {16'h0, cap_payload_len + 16'd20};
                    // fold
                    tcp_csum <= {1'b0, ps_sum[15:0]} + {16'h0, ps_sum[16:16]}
                              + {16'h0, ps_sum[17:17]};
                    tcp_phase <= 1'b0;
                    state    <= S_TCP_HDR;
                    byte_cnt <= '0;
                end else
                    byte_cnt <= byte_cnt + 1'b1;
            end

            // ---- TCP header (20 bytes, relative to TCP start) ------------
            S_TCP_HDR: begin
                case (byte_cnt)
                    8'd0:  cap_src_port[15:8] <= rx_tdata;
                    8'd1:  cap_src_port[7:0]  <= rx_tdata;
                    8'd2:  cap_dst_port[15:8] <= rx_tdata;
                    8'd3:  cap_dst_port[7:0]  <= rx_tdata;
                    8'd4:  cap_seq_num[31:24] <= rx_tdata;
                    8'd5:  cap_seq_num[23:16] <= rx_tdata;
                    8'd6:  cap_seq_num[15:8]  <= rx_tdata;
                    8'd7:  cap_seq_num[7:0]   <= rx_tdata;
                    8'd8:  cap_ack_num[31:24] <= rx_tdata;
                    8'd9:  cap_ack_num[23:16] <= rx_tdata;
                    8'd10: cap_ack_num[15:8]  <= rx_tdata;
                    8'd11: cap_ack_num[7:0]   <= rx_tdata;
                    8'd12: cap_data_off        <= rx_tdata[7:4];
                    8'd13: cap_flags           <= rx_tdata;
                    8'd14: cap_win_size[15:8]  <= rx_tdata;
                    8'd15: cap_win_size[7:0]   <= rx_tdata;
                    // bytes 16-17: TCP checksum (skip for rx; included in sum)
                    // bytes 18-19: urgent pointer
                    default: ;
                endcase

                // Accumulate TCP checksum over TCP header bytes
                if (tcp_phase == 1'b0) begin
                    ip_hdr_byte <= rx_tdata;
                    tcp_phase   <= 1'b1;
                end else begin
                    sum      = tcp_csum + {1'b0, ip_hdr_byte, rx_tdata};
                    tcp_csum <= {1'b0, sum[15:0]} + {16'h0, sum[16]};
                    tcp_phase <= 1'b0;
                end

                // End of fixed 20-byte TCP header
                if (byte_cnt == 8'd19) begin
                    state    <= (cap_payload_len == '0) ? S_DRAIN : S_PAYLOAD;
                    byte_cnt <= '0;
                end else
                    byte_cnt <= byte_cnt + 1'b1;
            end

            // ---- Payload -------------------------------------------------
            S_PAYLOAD: begin
                // Accumulate checksum
                if (tcp_phase == 1'b0) begin
                    ip_hdr_byte <= rx_tdata;
                    tcp_phase   <= 1'b1;
                end else begin
                    sum      = tcp_csum + {1'b0, ip_hdr_byte, rx_tdata};
                    tcp_csum <= {1'b0, sum[15:0]} + {16'h0, sum[16]};
                    tcp_phase <= 1'b0;
                end
                if (rx_tlast) state <= S_DRAIN;
            end

            S_DRAIN: ; // wait for tlast if not yet reached

            endcase

            // ---- End of frame processing ----------------------------------
            if (rx_tlast) begin
                // Handle odd final byte in checksum
                if (tcp_phase && state == S_PAYLOAD) begin
                    sum      = tcp_csum + {1'b0, ip_hdr_byte, 8'h00};
                    tcp_csum <= {1'b0, sum[15:0]} + {16'h0, sum[16]};
                end
                tcp_csum_valid <= (tcp_csum == 17'h0FFFF);

                // Publish decoded info if all validations pass
                if (!crc_err
                    && cap_eth_type  == 16'h0800
                    && cap_ip_proto  == 8'd6
                    && addr_valid
                    && cap_dst_mac   == local_mac
                    && cap_src_mac   == remote_mac
                    && cap_dst_ip    == local_ip
                    && cap_src_ip    == remote_ip
                    && cap_dst_port  == local_port
                    && cap_src_port  == remote_port
                    && ip_csum_valid
                    && (tcp_csum == 17'h0FFFF)) begin

                    pkt_valid       <= 1'b1;
                    rx_syn          <= cap_flags[1];
                    rx_ack          <= cap_flags[4];
                    rx_fin          <= cap_flags[0];
                    rx_rst          <= cap_flags[2];
                    rx_seq_num      <= cap_seq_num;
                    rx_ack_num      <= cap_ack_num;
                    rx_win_size     <= cap_win_size;
                    rx_payload_len  <= cap_payload_len;
                end

                // Reset for next frame
                state    <= S_ETH;
                byte_cnt <= '0;
                crc_err  <= 1'b0;
                ip_csum  <= '0;
                tcp_csum <= '0;
                tcp_phase <= 1'b0;
            end
        end  // rx_tvalid
    end
end

endmodule
`default_nettype wire
