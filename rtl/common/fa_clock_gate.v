`timescale 1ns/1ps

// Clock-gating boundary retained in the hierarchy for interface stability. The
// current baseline deliberately uses one ungated root clock in every build.
module fa_clock_gate (
  input  clk_i,
  input  enable_i,
  input  test_enable_i,
  output clk_o
);

  // Keep the disabled controls referenced so lint does not report unused ports.
  wire controls_tieoff_w = 1'b0 & (enable_i | test_enable_i);
  assign clk_o = clk_i | controls_tieoff_w;

endmodule
