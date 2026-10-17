`timescale 1ns/1ps

// Technology ICG in synthesis; the RTL model uses the same low-level latch.
module fa_clock_gate (
    input clk_i,
    input enable_i,
    input test_enable_i,
    output clk_o
);
`ifdef SYNTHESIS
    CKLNQD1BWP12T30P140 u_icg (
        .CP(clk_i), .E(enable_i), .TE(test_enable_i), .Q(clk_o)
    );
`else
    reg enable_latched_q;
    always @* begin
        if (!clk_i)
            enable_latched_q = enable_i || test_enable_i;
    end
    assign clk_o = clk_i && enable_latched_q;
`endif
endmodule
