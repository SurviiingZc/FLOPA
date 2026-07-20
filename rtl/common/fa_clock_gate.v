`timescale 1ns/1ps

// Backend-portable clock boundary. ASIC builds use the characterized latch-based
// ICG cell; FPGA builds keep a single clock domain and rely on register/BRAM/DSP CE.
module fa_clock_gate (
  input  clk_i,
  input  enable_i,
  input  test_enable_i,
  output clk_o
);

`ifdef ATTN_ASIC
  CKLNQD4BWP12T30P140 u_icg (
    .CP(clk_i),
    .E(enable_i),
    .TE(test_enable_i),
    .Q(clk_o)
  );
`else
  assign clk_o = clk_i;
`endif

endmodule
