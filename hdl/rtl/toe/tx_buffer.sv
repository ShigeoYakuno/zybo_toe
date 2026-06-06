`default_nettype none
// TX circular buffer — 8 KB XPM true-dual-port BRAM.
//
// Write port  (clk_50):  application data → wr_data/wr_en/wr_full
// Read port   (clk_50):  TCP engine reads segments for (re)transmission
//   send_start / send_len  → pulse when a segment must be sent
//   rd_valid / rd_data     → streamed bytes for that segment (no backpressure)
//   ack_ptr_in / ack_advance → advance ack (free buffer space)
//
// Retransmit: assert retrans_req; next send reads from unack_ptr.
module tx_buffer #(
    parameter  DEPTH_LOG2 = 13    // 8 KB
)(
    input  logic        clk,
    input  logic        rst_n,

    // ---- Application write interface (from AXI async FIFO) ----------------
    input  logic [7:0]  wr_data,
    input  logic        wr_en,
    output logic        wr_full,   // nearly full (hold off ARM)
    output logic [13:0] wr_count,  // bytes in buffer (for TX_COUNT register)

    // ---- TCP engine send control ------------------------------------------
    input  logic        send_req,  // 1-cycle pulse: send next segment
    input  logic [10:0] send_len,  // segment payload length in bytes
    output logic        send_busy, // high while segment is streaming
    output logic [7:0]  rd_data,   // streamed payload byte
    output logic        rd_valid,  // rd_data is valid this cycle
    output logic        rd_last,   // last byte of segment

    // ---- ACK advance (from tcp_state_ctrl) --------------------------------
    input  logic        ack_advance,  // pulse: acked bytes = ack_delta
    input  logic [10:0] ack_delta,    // bytes newly acknowledged

    // ---- Retransmit control -----------------------------------------------
    input  logic        retrans_req   // reset send pointer to unack pointer
);

localparam DEPTH = 1 << DEPTH_LOG2;  // 8192

// ---- Pointers (wrap-around arithmetic) ------------------------------------
logic [DEPTH_LOG2-1:0] wr_ptr   = '0;  // next write location
logic [DEPTH_LOG2-1:0] ack_ptr  = '0;  // oldest unACK'd byte
logic [DEPTH_LOG2-1:0] send_ptr = '0;  // next byte to transmit

logic [DEPTH_LOG2:0] used;  // bytes written but not yet ACK'd
assign used = {1'b0, wr_ptr} - {1'b0, ack_ptr};  // wrapping subtraction

logic [DEPTH_LOG2:0] free;
assign free = DEPTH[DEPTH_LOG2:0] - used;
assign wr_full  = (free <= (DEPTH >> 2));  // "almost full" at 75%
assign wr_count = used[DEPTH_LOG2-1:0];

// ---- XPM TDPRAM -----------------------------------------------------------
logic [7:0] bram_dout_b;
logic [DEPTH_LOG2-1:0] rd_addr_r = '0;

xpm_memory_tdpram #(
    .ADDR_WIDTH_A       (DEPTH_LOG2),
    .ADDR_WIDTH_B       (DEPTH_LOG2),
    .BYTE_WRITE_WIDTH_A (8),
    .BYTE_WRITE_WIDTH_B (8),
    .CLOCKING_MODE      ("common_clock"),
    .MEMORY_PRIMITIVE   ("block"),
    .MEMORY_SIZE        (DEPTH * 8),
    .READ_DATA_LATENCY_A(1),
    .READ_DATA_LATENCY_B(1),
    .WRITE_DATA_WIDTH_A (8),
    .WRITE_DATA_WIDTH_B (8),
    .WRITE_MODE_A       ("no_change"),
    .WRITE_MODE_B       ("no_change"),
    .USE_MEM_INIT       (0)
) u_bram (
    .clka  (clk),        .clkb  (clk),
    .addra (wr_ptr),     .addrb (rd_addr_r),
    .dina  (wr_data),    .dinb  (8'h00),
    .wea   (wr_en & ~wr_full),
    .web   (1'b0),
    .ena   (1'b1),       .enb   (1'b1),
    .douta (),           .doutb (bram_dout_b),
    .rsta  (1'b0),       .rstb  (1'b0),
    .injectdbiterra(1'b0), .injectsbiterra(1'b0),
    .injectdbiterrb(1'b0), .injectsbiterrb(1'b0),
    .regcea(1'b1),       .regceb(1'b1),
    .sleep (1'b0)
);

// ---- Write pointer update -------------------------------------------------
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        wr_ptr <= '0;
    else if (wr_en && !wr_full)
        wr_ptr <= wr_ptr + 1'b1;
end

// ---- ACK pointer advance --------------------------------------------------
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        ack_ptr <= '0;
    else if (ack_advance)
        ack_ptr <= ack_ptr + ack_delta[DEPTH_LOG2-1:0];
end

// ---- Send state machine ---------------------------------------------------
typedef enum logic [1:0] { S_IDLE, S_WAIT, S_SEND } state_t;
state_t state = S_IDLE;
logic [10:0] cnt;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state    <= S_IDLE;
        send_ptr <= '0;
        cnt      <= '0;
        rd_valid <= 1'b0;
        rd_last  <= 1'b0;
        send_busy <= 1'b0;
    end else begin
        rd_valid  <= 1'b0;
        rd_last   <= 1'b0;

        if (retrans_req)
            send_ptr <= ack_ptr;

        case (state)
        S_IDLE: begin
            send_busy <= 1'b0;
            if (send_req && send_len != '0) begin
                cnt       <= send_len - 1'b1;
                rd_addr_r <= send_ptr;
                send_ptr  <= send_ptr + 1'b1;
                send_busy <= 1'b1;
                state     <= S_WAIT;  // 1 cycle BRAM read latency
            end
        end
        S_WAIT: begin
            // absorb 1-cycle BRAM latency
            rd_addr_r <= send_ptr;
            send_ptr  <= send_ptr + 1'b1;
            state     <= S_SEND;
        end
        S_SEND: begin
            rd_data  <= bram_dout_b;
            rd_valid <= 1'b1;
            if (cnt == '0) begin
                rd_last   <= 1'b1;
                send_busy <= 1'b0;
                state     <= S_IDLE;
            end else begin
                cnt       <= cnt - 1'b1;
                rd_addr_r <= send_ptr;
                send_ptr  <= send_ptr + 1'b1;
            end
        end
        endcase
    end
end

endmodule
`default_nettype wire
