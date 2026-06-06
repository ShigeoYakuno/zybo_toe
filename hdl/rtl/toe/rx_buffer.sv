`default_nettype none
// RX buffer — synchronous FIFO (both ports clk_50 for in-engine use).
// Wraps xpm_fifo_sync with a simple 4096-byte capacity.
// ARM reads via AXI4-Lite RX_DATA register (handled in axi4lite_regs.sv
// with a separate async FIFO crossing to s_axi_aclk domain).
module rx_buffer (
    input  logic        clk,
    input  logic        rst_n,

    // Write side — from TCP RX payload decoder
    input  logic [7:0]  wr_data,
    input  logic        wr_en,
    output logic        wr_full,

    // Read side — to AXI4-Lite async FIFO bridge
    output logic [7:0]  rd_data,
    input  logic        rd_en,
    output logic        rd_empty,
    output logic [11:0] rd_count   // bytes available
);

xpm_fifo_sync #(
    .FIFO_MEMORY_TYPE ("block"),
    .FIFO_WRITE_DEPTH (4096),
    .WRITE_DATA_WIDTH (8),
    .READ_DATA_WIDTH  (8),
    .READ_MODE        ("std"),
    .FIFO_READ_LATENCY(1),
    .RD_DATA_COUNT_WIDTH(12),
    .WR_DATA_COUNT_WIDTH(12),
    .USE_ADV_FEATURES ("0000"),
    .DOUT_RESET_VALUE ("0")
) u_fifo (
    .clk     (clk),
    .rst     (~rst_n),
    .din     (wr_data),
    .wr_en   (wr_en),
    .full    (wr_full),
    .dout    (rd_data),
    .rd_en   (rd_en),
    .empty   (rd_empty),
    .rd_data_count (rd_count),
    .wr_data_count (),
    .prog_empty(),
    .prog_full(),
    .overflow(),
    .underflow(),
    .wr_rst_busy(),
    .rd_rst_busy(),
    .almost_empty(),
    .almost_full(),
    .sleep(1'b0),
    .injectdbiterr(1'b0),
    .injectsbiterr(1'b0),
    .sbiterr(),
    .dbiterr()
);

endmodule
`default_nettype wire
