`default_nettype none

// Wrapper around mii_mac_rx / mii_mac_tx providing the simplified interface
// expected by toe_top.sv.  The original ebaz4205 rmii_mac had separate TX/RX
// clocks and a bypass AXI-Stream — neither is needed for the TOE design.

module rmii_mac #(
    parameter USE_RMII = 1  // always 1; kept for compatibility
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- RMII RX (from LAN8720) -------------------------------------------
    input  wire [1:0]  rmii_rxd,
    input  wire        rmii_crs_dv,

    // ---- RMII TX (to LAN8720) ---------------------------------------------
    output wire [1:0]  rmii_txd,
    output wire        rmii_tx_en,

    // ---- RX AXI-Stream output (to TOE engine) -----------------------------
    output wire [7:0]  rx_tdata,
    output wire        rx_tvalid,
    output wire        rx_tlast,
    output wire        rx_tuser,   // 1 = CRC error

    // ---- TX AXI-Stream input (from TOE engine) ----------------------------
    input  wire [7:0]  tx_tdata,
    input  wire        tx_tvalid,
    output wire        tx_tready,
    input  wire        tx_tlast
);

// mii_mac_tx outputs 4-bit MII data; RMII uses lower 2 bits
wire [3:0] tx_mii_d;
wire       tx_mii_en;

mii_mac_tx #(
    .USE_RMII (1)
) u_mac_tx (
    .clock                (clk),
    .aresetn              (rst_n),
    .mii_d                (tx_mii_d),
    .mii_en               (tx_mii_en),
    .mii_er               (),
    // Main TX stream
    .saxis_tdata          (tx_tdata),
    .saxis_tvalid         (tx_tvalid),
    .saxis_tready         (tx_tready),
    .saxis_tuser          (1'b0),
    .saxis_tlast          (tx_tlast),
    // Bypass stream — not used, tie off
    .saxis_bypass_tdata   (8'h00),
    .saxis_bypass_tvalid  (1'b0),
    .saxis_bypass_tready  (),
    .saxis_bypass_tuser   (1'b0),
    .saxis_bypass_tlast   (1'b0)
);

assign rmii_txd   = tx_mii_d[1:0];
assign rmii_tx_en = tx_mii_en;

mii_mac_rx #(
    .USE_RMII (1)
) u_mac_rx (
    .clock       (clk),
    .aresetn     (rst_n),
    .mii_d       ({2'b00, rmii_rxd}),
    .mii_dv      (rmii_crs_dv),
    .mii_er      (1'b0),
    .maxis_tdata (rx_tdata),
    .maxis_tvalid(rx_tvalid),
    .maxis_tuser (rx_tuser),
    .maxis_tlast (rx_tlast)
);

endmodule
`default_nettype wire
