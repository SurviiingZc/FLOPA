`timescale 1ns/1ps

// Common combinational multiplier boundaries. ASIC synthesis uses explicit
// DesignWare arithmetic so resource reports prove the selected implementation;
// simulation and FPGA builds retain portable '*' inference for DSP mapping.
module fa_signed_mult_comb #(
  parameter integer A_W = 16,
  parameter integer B_W = 16
)(
  input  signed [A_W-1:0]       a_i,
  input  signed [B_W-1:0]       b_i,
  output signed [A_W+B_W-1:0]   product_o
);

  wire [A_W+B_W-1:0] product_w;

`ifdef ATTN_ASIC
  DW02_mult #(
    .A_width(A_W), .B_width(B_W)
  ) u_dw_mult (
    .A(a_i), .B(b_i), .TC(1'b1), .PRODUCT(product_w)
  );
`else
  assign product_w = $signed(a_i) * $signed(b_i);
`endif

  assign product_o = $signed(product_w);

endmodule

module fa_unsigned_mult_comb #(
  parameter integer A_W = 16,
  parameter integer B_W = 16
)(
  input      [A_W-1:0]       a_i,
  input      [B_W-1:0]       b_i,
  output     [A_W+B_W-1:0]   product_o
);

`ifdef ATTN_ASIC
  DW02_mult #(
    .A_width(A_W), .B_width(B_W)
  ) u_dw_mult (
    .A(a_i), .B(b_i), .TC(1'b0), .PRODUCT(product_o)
  );
`else
  assign product_o = a_i * b_i;
`endif

endmodule
