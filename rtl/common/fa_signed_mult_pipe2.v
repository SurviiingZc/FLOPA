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
  wire signed [HI_PRODUCT_W-1:0] hi_product_w;
  wire signed [LO_PRODUCT_W-1:0] lo_product_w;

  fa_signed_mult_comb #(
    .A_W(HI_W), .B_W(B_W)
  ) u_hi_multiplier (
    .a_i(a_hi_w), .b_i(b_i), .product_o(hi_product_w)
  );

  fa_signed_mult_comb #(
    .A_W(LO_OPERAND_W), .B_W(B_W)
  ) u_lo_multiplier (
    .a_i(a_lo_w), .b_i(b_i), .product_o(lo_product_w)
  );

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
        // Each partial product has an explicit DesignWare boundary in ASIC mode.
        hi_product_s1_q <= hi_product_w;
        lo_product_s1_q <= lo_product_w;
      end
      if (valid_s1_q)
        product_o <= combined_product_w;
    end
  end

endmodule

// Exact latency-3 alternative for a wide B operand. Four small partial
// multipliers replace the long 16x31 partial products in the normalizer.
module fa_signed_mult_pipe3 #(
    parameter integer A_W = 32,
    parameter integer B_W = 31,
    parameter integer SPLIT_W = 16,
    parameter integer B_SPLIT_W = 15
)(
    input clk,
    input rst_n,
    input valid_i,
    input signed [A_W-1:0] a_i,
    input signed [B_W-1:0] b_i,
    output reg valid_o,
    output reg signed [A_W+B_W-1:0] product_o
);
    localparam integer HI_B_W = B_W - B_SPLIT_W;
    localparam integer LO_B_W = B_SPLIT_W + 1;
    localparam integer PRODUCT_W = A_W + B_W;
    wire signed [HI_B_W-1:0] b_hi_w = b_i[B_W-1:B_SPLIT_W];
    wire signed [LO_B_W-1:0] b_lo_w = {1'b0, b_i[B_SPLIT_W-1:0]};
    wire signed [A_W+HI_B_W-1:0] hi_product_w;
    wire signed [A_W+LO_B_W-1:0] lo_product_w;
    wire high_valid_w;
    wire low_valid_w;
    wire signed [PRODUCT_W-1:0] hi_extended_w =
        {{B_SPLIT_W{hi_product_w[A_W+HI_B_W-1]}}, hi_product_w};
    wire signed [PRODUCT_W-1:0] lo_extended_w =
        {{(B_W-LO_B_W){lo_product_w[A_W+LO_B_W-1]}}, lo_product_w};

    fa_signed_mult_pipe2 #(.A_W(A_W), .B_W(HI_B_W), .SPLIT_W(SPLIT_W)) u_high (
        .clk(clk), .rst_n(rst_n), .valid_i(valid_i), .a_i(a_i), .b_i(b_hi_w),
        .valid_o(high_valid_w), .product_o(hi_product_w)
    );
    fa_signed_mult_pipe2 #(.A_W(A_W), .B_W(LO_B_W), .SPLIT_W(SPLIT_W)) u_low (
        .clk(clk), .rst_n(rst_n), .valid_i(valid_i), .a_i(a_i), .b_i(b_lo_w),
        .valid_o(low_valid_w), .product_o(lo_product_w)
    );
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            valid_o <= 1'b0;
        else
            valid_o <= high_valid_w;
    end
    always @(posedge clk) begin
        if (rst_n && high_valid_w)
            product_o <= (hi_extended_w <<< B_SPLIT_W) + lo_extended_w;
    end
`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && high_valid_w != low_valid_w)
            $fatal(1, "fa_signed_mult_pipe3 partial valid mismatch");
    end
`endif
endmodule
