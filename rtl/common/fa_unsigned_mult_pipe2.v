`timescale 1ns/1ps

// Exact unsigned multiplier with latency 2 and initiation interval 1. Splitting
// operand A creates a registered partial-product boundary that maps to either
// DesignWare arithmetic or FPGA DSP blocks without a single long multiply.
module fa_unsigned_mult_pipe2 #(
  parameter integer A_W = 32,
  parameter integer B_W = 16,
  parameter integer SPLIT_W = 16
)(
  input                         clk,
  input                         rst_n,
  input                         valid_i,
  input      [A_W-1:0]          a_i,
  input      [B_W-1:0]          b_i,
  output reg                    valid_o,
  output reg [A_W+B_W-1:0]      product_o
);

  localparam integer HI_W = A_W - SPLIT_W;
  localparam integer PRODUCT_W = A_W + B_W;
  localparam integer HI_PRODUCT_W = HI_W + B_W;
  localparam integer LO_PRODUCT_W = SPLIT_W + B_W;

  wire [HI_W-1:0] a_hi_w = a_i[A_W-1:SPLIT_W];
  wire [SPLIT_W-1:0] a_lo_w = a_i[SPLIT_W-1:0];
  reg [HI_PRODUCT_W-1:0] hi_product_s1_q;
  reg [LO_PRODUCT_W-1:0] lo_product_s1_q;
  reg valid_s1_q;
  wire [HI_PRODUCT_W-1:0] hi_product_w;
  wire [LO_PRODUCT_W-1:0] lo_product_w;

  fa_unsigned_mult_comb #(
    .A_W(HI_W), .B_W(B_W)
  ) u_hi_multiplier (
    .a_i(a_hi_w), .b_i(b_i), .product_o(hi_product_w)
  );

  fa_unsigned_mult_comb #(
    .A_W(SPLIT_W), .B_W(B_W)
  ) u_lo_multiplier (
    .a_i(a_lo_w), .b_i(b_i), .product_o(lo_product_w)
  );

  wire [PRODUCT_W-1:0] hi_product_extended_w =
      {{(PRODUCT_W-HI_PRODUCT_W){1'b0}}, hi_product_s1_q};
  wire [PRODUCT_W-1:0] lo_product_extended_w =
      {{(PRODUCT_W-LO_PRODUCT_W){1'b0}}, lo_product_s1_q};
  wire [PRODUCT_W-1:0] combined_product_w =
      (hi_product_extended_w << SPLIT_W) + lo_product_extended_w;

`ifndef SYNTHESIS
  initial begin
    if (A_W <= SPLIT_W)
      $fatal(1, "fa_unsigned_mult_pipe2 requires A_W > SPLIT_W");
    if (SPLIT_W < 1 || B_W < 1)
      $fatal(1, "fa_unsigned_mult_pipe2 has invalid operand widths");
  end
`endif

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s1_q <= 1'b0;
      valid_o <= 1'b0;
    end else begin
      valid_s1_q <= valid_i;
      valid_o <= valid_s1_q;
    end
  end

  // Payload is valid-qualified and intentionally unreset to keep it off the
  // reset tree. Explicit result contexts retain every product bit.
  always @(posedge clk) begin
    if (rst_n) begin
      if (valid_i) begin
        hi_product_s1_q <= hi_product_w;
        lo_product_s1_q <= lo_product_w;
      end
      if (valid_s1_q)
        product_o <= combined_product_w;
    end
  end

endmodule
