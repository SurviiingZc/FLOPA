`timescale 1ns/1ps

// One physically independent copy of a high-fanout control token.  The module
// boundary prevents cross-group merging while leaving the flop itself free to
// map to the selected standard-cell library.
(* keep_hierarchy = "yes" *) module fa_clear_replica (
  input  clk,
  input  rst_n,
  input  clear_i,
  input  token_i,
  output reg token_o
);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) token_o <= 1'b0;
    else if (clear_i) token_o <= 1'b0;
    else token_o <= token_i;
  end

endmodule
