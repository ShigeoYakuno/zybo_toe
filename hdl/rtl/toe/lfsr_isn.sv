`default_nettype none
// 32-bit Fibonacci LFSR — Initial Sequence Number generator
// Polynomial: x^32 + x^30 + x^26 + x^25 + 1  (Galois form, period = 2^32-1)
module lfsr_isn (
    input  logic        clk,
    output logic [31:0] isn
);
    logic [31:0] lfsr = 32'hABCD_1234;

    always_ff @(posedge clk) begin
        if (lfsr == '0)
            lfsr <= 32'hABCD_1234;
        else
            lfsr <= {lfsr[30:0], lfsr[31] ~^ lfsr[29] ~^ lfsr[25] ~^ lfsr[24]};
    end

    assign isn = lfsr;
endmodule
`default_nettype wire
