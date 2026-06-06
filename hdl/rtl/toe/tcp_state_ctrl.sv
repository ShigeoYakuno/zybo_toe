`default_nettype none
// TCP state machine (Active Open only).
// Ported from StateCtrl.vhd / TxTPUCtrl.vhd (VHDL reference by L.Ratchanon).
//
// States exposed to ARM via STATUS register:
//   0=CLOSED 1=SYN_SENT 2=ESTABLISHED 3=FIN_WAIT_1 4=FIN_WAIT_2
//   5=TIME_WAIT 6=CLOSE_WAIT 7=LAST_ACK
//
// Timeout @ 50 MHz:
//   SYN_SENT timeout   : 3 s    = 150,000,000 clk
//   2MSL (TIME_WAIT)   : 100 ms = 5,000,000   clk
//   Retransmit          : 200 ms = 10,000,000  clk

module tcp_state_ctrl #(
    parameter CLK_HZ       = 50_000_000,
    parameter SYN_TIMEOUT  = CLK_HZ * 3,       // 3 s
    parameter TWAIT_TIMEOUT = CLK_HZ / 10,     // 100 ms
    parameter RETX_TIMEOUT  = CLK_HZ / 5       // 200 ms
)(
    input  logic        clk,
    input  logic        rst_n,

    // ---- ARM PS control (synchronised from AXI domain) -------------------
    input  logic        connect_req,     // rising edge = initiate connection
    input  logic        disconnect_req,  // rising edge = close connection

    // ---- RX path inputs (from tcp_rx_hdr_dec) ----------------------------
    input  logic        pkt_valid,       // valid TCP packet decoded
    input  logic        rx_syn,
    input  logic        rx_ack,
    input  logic        rx_fin,
    input  logic        rx_rst,
    input  logic [31:0] rx_seq_num,
    input  logic [31:0] rx_ack_num,
    input  logic [15:0] rx_win_size,
    input  logic [15:0] rx_payload_len,

    // ---- ISN from LFSR ---------------------------------------------------
    input  logic [31:0] isn,             // initial sequence number

    // ---- TX control (to tcp_hdr_gen) -------------------------------------
    output logic        tx_send_req,     // pulse: send a TCP segment
    output logic [8:0]  tx_flags,        // NS|CWR|ECE|URG|ACK|PSH|RST|SYN|FIN
    output logic [31:0] tx_seq_num,
    output logic [31:0] tx_ack_num,
    output logic [10:0] tx_payload_len,  // 0 for control packets
    output logic        tx_payload_en,   // fetch payload from tx_buffer
    output logic        tx_busy,         // waiting for tx_hdr_gen to finish

    // ---- Retransmit control (to tx_buffer) --------------------------------
    output logic        retrans_req,     // reset tx_buffer send pointer
    output logic        ack_advance,
    output logic [10:0] ack_delta,

    // ---- Status (to axi4lite_regs, clk_50 domain) ------------------------
    output logic [3:0]  tcp_state,       // for STATUS register
    output logic        irq              // state change notification
);

// ---------------------------------------------------------------------------
typedef enum logic [3:0] {
    ST_CLOSED      = 4'd0,
    ST_SYN_SENT    = 4'd1,
    ST_ESTABLISHED = 4'd2,
    ST_FIN_WAIT_1  = 4'd3,
    ST_FIN_WAIT_2  = 4'd4,
    ST_TIME_WAIT   = 4'd5,
    ST_CLOSE_WAIT  = 4'd6,
    ST_LAST_ACK    = 4'd7
} state_t;

state_t state     = ST_CLOSED;
state_t state_r   = ST_CLOSED;

assign tcp_state = state[3:0];

// IRQ: one-cycle pulse on state change
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_CLOSED;
        irq     <= 1'b0;
    end else begin
        state_r <= state;
        irq     <= (state != state_r);
    end
end

// ---- Sequence numbers -----------------------------------------------------
logic [31:0] local_seq;   // our next seq num to send
logic [31:0] local_ack;   // next expected seq from remote (= our ACK)
logic [15:0] remote_win;  // remote receive window

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        local_seq  <= '0;
        local_ack  <= '0;
        remote_win <= 16'd4096;
    end else begin
        if (pkt_valid) begin
            remote_win <= rx_win_size;
            // Update ACK: expected next seq = remote seq + payload_len
            // (+ 1 for SYN or FIN flags)
            if (rx_syn || rx_fin)
                local_ack <= rx_seq_num + 32'd1 + {16'h0, rx_payload_len};
            else if (rx_payload_len != '0)
                local_ack <= rx_seq_num + {16'h0, rx_payload_len};
        end
    end
end

// ---- Timers ---------------------------------------------------------------
logic [27:0] timer = '0;
logic        timer_expire;
logic        timer_en;
logic [28:0] lim;     // timer limit temp (used in always_ff)
logic [31:0] delta;   // ACK delta temp (used in always_ff)

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        timer        <= '0;
        timer_expire <= 1'b0;
    end else begin
        timer_expire <= 1'b0;
        if (!timer_en) begin
            timer <= '0;
        end else begin
            case (state)
                ST_SYN_SENT:  lim = SYN_TIMEOUT[28:0];
                ST_TIME_WAIT: lim = TWAIT_TIMEOUT[28:0];
                default:      lim = RETX_TIMEOUT[28:0];
            endcase
            if (timer == lim[27:0]) begin
                timer        <= '0;
                timer_expire <= 1'b1;
            end else
                timer <= timer + 1'b1;
        end
    end
end
assign timer_en = (state == ST_SYN_SENT) || (state == ST_TIME_WAIT);

// ---- Retransmit timer (separate, runs during established) -----------------
logic [27:0] retx_timer = '0;
logic        retx_expire;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        retx_timer <= '0;
        retx_expire <= 1'b0;
    end else begin
        retx_expire <= 1'b0;
        if (state == ST_ESTABLISHED || state == ST_FIN_WAIT_1 ||
            state == ST_CLOSE_WAIT  || state == ST_LAST_ACK) begin
            if (retx_timer == RETX_TIMEOUT[27:0]) begin
                retx_timer  <= '0;
                retx_expire <= 1'b1;
            end else
                retx_timer <= retx_timer + 1'b1;
        end else
            retx_timer <= '0;
    end
end

// ---- TX request arbiter ---------------------------------------------------
// Serialize: only one TX request at a time
logic tx_req_pending = 1'b0;
logic [8:0]  pend_flags = '0;
logic [10:0] pend_plen  = '0;
logic        pend_pload = 1'b0;

// Accepted ACK tracking for tx_buffer
logic [31:0] last_acked = '0;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        last_acked  <= '0;
        ack_advance <= 1'b0;
        ack_delta   <= '0;
        retrans_req <= 1'b0;
    end else begin
        ack_advance <= 1'b0;
        retrans_req <= 1'b0;
        if (pkt_valid && rx_ack && state == ST_ESTABLISHED) begin
            delta = rx_ack_num - last_acked;
            if (delta != '0 && delta[31] == 1'b0) begin
                last_acked  <= rx_ack_num;
                ack_advance <= 1'b1;
                ack_delta   <= delta[10:0];
            end
        end
        if (retx_expire && state == ST_ESTABLISHED)
            retrans_req <= 1'b1;
    end
end

// ---- Main state machine ---------------------------------------------------
logic  connect_req_r = 1'b0, conn_rise;
logic  disconnect_req_r = 1'b0, disc_rise;
assign conn_rise = connect_req    && !connect_req_r;
assign disc_rise = disconnect_req && !disconnect_req_r;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        connect_req_r    <= 1'b0;
        disconnect_req_r <= 1'b0;
    end else begin
        connect_req_r    <= connect_req;
        disconnect_req_r <= disconnect_req;
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state          <= ST_CLOSED;
        local_seq      <= '0;
        tx_send_req    <= 1'b0;
        tx_flags       <= '0;
        tx_seq_num     <= '0;
        tx_ack_num     <= '0;
        tx_payload_len <= '0;
        tx_payload_en  <= 1'b0;
        tx_busy        <= 1'b0;
        tx_req_pending <= 1'b0;
    end else begin
        tx_send_req <= 1'b0;

        // TX done acknowledgement (tx_busy deasserted by tcp_hdr_gen)
        if (tx_busy && !tx_req_pending)
            tx_busy <= 1'b0;

        case (state)

        // CLOSED: wait for ARM connect request
        ST_CLOSED: begin
            if (conn_rise) begin
                local_seq   <= isn;
                state       <= ST_SYN_SENT;
                // Send SYN
                tx_flags       <= 9'b0_0000_0010;  // SYN only
                tx_seq_num     <= isn;
                tx_ack_num     <= '0;
                tx_payload_len <= '0;
                tx_payload_en  <= 1'b0;
                tx_send_req    <= 1'b1;
                tx_busy        <= 1'b1;
                local_seq      <= isn + 32'd1;      // seq advances past SYN
            end
        end

        // SYN_SENT: waiting for SYN-ACK
        ST_SYN_SENT: begin
            if (pkt_valid && rx_syn && rx_ack && !rx_rst) begin
                state <= ST_ESTABLISHED;
                // Send ACK
                tx_flags       <= 9'b0_0001_0000;  // ACK
                tx_seq_num     <= local_seq;
                tx_ack_num     <= local_ack;
                tx_payload_len <= '0;
                tx_payload_en  <= 1'b0;
                tx_send_req    <= 1'b1;
                tx_busy        <= 1'b1;
            end else if (pkt_valid && rx_rst) begin
                state <= ST_CLOSED;
            end else if (timer_expire) begin
                state <= ST_CLOSED;  // give up after timeout
            end
        end

        // ESTABLISHED: data transfer
        ST_ESTABLISHED: begin
            if (pkt_valid && rx_rst) begin
                state <= ST_CLOSED;
            end else if (pkt_valid && rx_fin) begin
                state <= ST_CLOSE_WAIT;
                // Send ACK for FIN
                tx_flags       <= 9'b0_0001_0000;
                tx_seq_num     <= local_seq;
                tx_ack_num     <= local_ack;
                tx_payload_len <= '0;
                tx_payload_en  <= 1'b0;
                tx_send_req    <= 1'b1;
                tx_busy        <= 1'b1;
            end else if (disc_rise) begin
                state <= ST_FIN_WAIT_1;
                // Send FIN+ACK
                tx_flags       <= 9'b0_0001_0001;
                tx_seq_num     <= local_seq;
                tx_ack_num     <= local_ack;
                tx_payload_len <= '0;
                tx_payload_en  <= 1'b0;
                tx_send_req    <= 1'b1;
                tx_busy        <= 1'b1;
                local_seq      <= local_seq + 32'd1;
            end else if (pkt_valid && rx_ack && rx_payload_len > '0) begin
                // Received data — send ACK
                tx_flags       <= 9'b0_0001_0000;
                tx_seq_num     <= local_seq;
                tx_ack_num     <= local_ack;
                tx_payload_len <= '0;
                tx_payload_en  <= 1'b0;
                tx_send_req    <= 1'b1;
                tx_busy        <= 1'b1;
            end
        end

        // FIN_WAIT_1: we sent FIN, waiting for ACK
        ST_FIN_WAIT_1: begin
            if (pkt_valid && rx_ack && !rx_fin) begin
                state <= ST_FIN_WAIT_2;
            end else if (pkt_valid && rx_fin) begin
                state <= ST_TIME_WAIT;
                tx_flags       <= 9'b0_0001_0000;
                tx_seq_num     <= local_seq;
                tx_ack_num     <= local_ack;
                tx_payload_len <= '0;
                tx_payload_en  <= 1'b0;
                tx_send_req    <= 1'b1;
                tx_busy        <= 1'b1;
            end
        end

        // FIN_WAIT_2: ACK received, waiting for remote FIN
        ST_FIN_WAIT_2: begin
            if (pkt_valid && rx_fin) begin
                state <= ST_TIME_WAIT;
                tx_flags       <= 9'b0_0001_0000;
                tx_seq_num     <= local_seq;
                tx_ack_num     <= local_ack;
                tx_payload_len <= '0;
                tx_payload_en  <= 1'b0;
                tx_send_req    <= 1'b1;
                tx_busy        <= 1'b1;
            end
        end

        // TIME_WAIT: wait 2MSL before CLOSED
        ST_TIME_WAIT: begin
            if (timer_expire) state <= ST_CLOSED;
        end

        // CLOSE_WAIT: remote sent FIN, waiting for app to close
        ST_CLOSE_WAIT: begin
            if (disc_rise) begin
                state <= ST_LAST_ACK;
                tx_flags       <= 9'b0_0001_0001;
                tx_seq_num     <= local_seq;
                tx_ack_num     <= local_ack;
                tx_payload_len <= '0;
                tx_payload_en  <= 1'b0;
                tx_send_req    <= 1'b1;
                tx_busy        <= 1'b1;
                local_seq      <= local_seq + 32'd1;
            end
        end

        // LAST_ACK: we sent FIN, waiting for final ACK
        ST_LAST_ACK: begin
            if (pkt_valid && rx_ack)
                state <= ST_CLOSED;
        end

        default: state <= ST_CLOSED;
        endcase
    end
end

endmodule
`default_nettype wire
