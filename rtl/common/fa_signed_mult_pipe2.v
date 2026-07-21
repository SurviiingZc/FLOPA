`timescale 1ns/1ps

// Exact signed multiplier with two registered stages and initiation interval 1.
// Stage 1 computes two smaller partial products in parallel; stage 2 shifts and
// combines them. Splitting A at SPLIT_W maps naturally to two FPGA DSP blocks
// and gives ASIC synthesis a real arithmetic boundary instead of input/output
// registers around one long multiply.
module fa_signed_mult_pipe2 #(
  parameter integer A_W = 48,
  parameter integer B_W = 16,
  parameter integer SPLIT_W = 24
)(
  input                              clk,
  input                              rst_n,
  input                              valid_i,
  input signed [A_W-1:0]             a_i,
  input signed [B_W-1:0]             b_i,
  output reg                         valid_o,
  output reg signed [A_W+B_W-1:0]    product_o
);

  localparam integer HI_W = A_W - SPLIT_W;
  localparam integer LO_OPERAND_W = SPLIT_W + 1;
  localparam integer HI_PRODUCT_W = HI_W + B_W;
  localparam integer LO_PRODUCT_W = LO_OPERAND_W + B_W;
  localparam integer PRODUCT_W = A_W + B_W;

  wire signed [HI_W-1:0] a_hi_w = $signed(a_i[A_W-1:SPLIT_W]);
  wire signed [LO_OPERAND_W-1:0] a_lo_w =
      $signed({1'b0, a_i[SPLIT_W-1:0]});
  reg signed [HI_PRODUCT_W-1:0] hi_product_s1_q;
  reg signed [LO_PRODUCT_W-1:0] lo_product_s1_q;
  reg valid_s1_q;

  wire signed [PRODUCT_W-1:0] hi_product_extended_w =
      $signed({{(PRODUCT_W-HI_PRODUCT_W){
                    hi_product_s1_q[HI_PRODUCT_W-1]}}, hi_product_s1_q});
  wire signed [PRODUCT_W-1:0] lo_product_extended_w =
      $signed({{(PRODUCT_W-LO_PRODUCT_W){
                    lo_product_s1_q[LO_PRODUCT_W-1]}}, lo_product_s1_q});
  wire signed [PRODUCT_W-1:0] combined_product_w =
      $signed(hi_product_extended_w <<< SPLIT_W) +
      $signed(lo_product_extended_w);

`ifndef SYNTHESIS
  initial begin
    if (A_W <= SPLIT_W)
      $fatal(1, "fa_signed_mult_pipe2 requires A_W > SPLIT_W");
    if (SPLIT_W < 1 || B_W < 2)
      $fatal(1, "fa_signed_mult_pipe2 has invalid operand widths");
  end
`endif

  // Valid state is reset; valid-qualified arithmetic payload is deliberately
  // unreset to avoid adding multiplier datapath bits to the reset tree.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s1_q <= 1'b0;
      valid_o <= 1'b0;
    end else begin
      valid_s1_q <= valid_i;
      valid_o <= valid_s1_q;
    end
  end

  always @(posedge clk) begin
    if (rst_n) begin
      if (valid_i) begin
        // Explicit result contexts prevent Verilog from truncating mixed-width
        // products while retaining the effective HI_WxB_W and (SPLIT_W+1)xB_W
        // variable operands after constant sign-extension is optimized.
        hi_product_s1_q <=
            $signed({{B_W{a_hi_w[HI_W-1]}}, a_hi_w}) * $signed(b_i);
        lo_product_s1_q <=
            $signed({{B_W{a_lo_w[LO_OPERAND_W-1]}}, a_lo_w}) * $signed(b_i);
      end
      if (valid_s1_q)
        product_o <= combined_product_w;
    end
  end

endmodule
