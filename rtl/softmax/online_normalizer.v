`timescale 1ns/1ps
`include "attention_defines.vh"

// Final eight-row normalization pipeline: O/l, output requantization, rounding,
// and signed INT8 saturation. One stripe/feature tag is preserved end to end.
module online_normalizer #(
  parameter integer LANES = 8,
  parameter integer ACC_W = `ATTN_ACC_W,
  parameter integer LSE_W = `ATTN_LSE_W,
  parameter integer OUT_W = `ATTN_OUT_W,
  parameter integer TAG_W = 8
)(
  input                         clk,
  input                         rst_n,
  input                         clock_en_i,
  input                         valid_i,
  input      [LANES*ACC_W-1:0]  acc_rows_i,
  input      [LANES*LSE_W-1:0]  l_rows_i,
  input      [31:0]             out_scale_i,
  input      [TAG_W-1:0]        tag_i,
  output reg                    valid_o,
  output     [LANES*OUT_W-1:0]  out_rows_o,
  output reg [TAG_W-1:0]        tag_o
);

  localparam integer NORM_REDUCED_W = 48;

  // Round signed two's-complement values to nearest with ties away from zero.
  // For negative values, an arithmetic shift already rounds toward -infinity,
  // so it is corrected toward zero only when the discarded magnitude is < 0.5.
  function round_increment;
    input [63:0] value;
    input [5:0] shift;
    integer bit_index;
    reg guard_bit;
    reg sticky_bit;
    begin
      guard_bit = 1'b0;
      sticky_bit = 1'b0;
      if (shift != 0) begin
        guard_bit = value[shift-1'b1];
        for (bit_index = 0; bit_index < 63; bit_index = bit_index + 1)
          if ($unsigned(bit_index) < {26'd0, (shift-1'b1)})
            sticky_bit = sticky_bit | value[bit_index];
      end
      round_increment = guard_bit && (!value[63] || sticky_bit);
    end
  endfunction

  wire gated_clk_w;
  fa_clock_gate u_clock_gate (
    .clk_i(clk), .enable_i(clock_en_i), .test_enable_i(1'b0),
    .clk_o(gated_clk_w)
  );

  wire [LANES-1:0] reciprocal_valid_w;
  wire [LANES*32-1:0] reciprocal_w;
  wire all_reciprocal_valid_w = &reciprocal_valid_w;
  reg [LANES*ACC_W-1:0] acc_s0_q;
  reg [LANES*ACC_W-1:0] acc_s1_q;
  reg [LANES*ACC_W-1:0] acc_s2_q;
  reg [31:0] scale_s0_q;
  reg [31:0] scale_s1_q;
  reg [31:0] scale_s2_q;
  reg [TAG_W-1:0] tag_s0_q;
  reg [TAG_W-1:0] tag_s1_q;
  reg [TAG_W-1:0] tag_s2_q;
  reg [TAG_W-1:0] norm_tag_q;
  reg [TAG_W-1:0] mult_tag_s1_q;
  reg [TAG_W-1:0] mult_tag_s2_q;
  reg norm_valid_q;
  reg mult_metadata_valid_s1_q;
  wire [LANES-1:0] scale_product_valid_w;
  wire all_scale_product_valid_w = &scale_product_valid_w;

  // Each lane owns a reciprocal and two multipliers so all rows in a stripe are
  // normalized together while features stream one per cycle.
  generate
    genvar lane;
    for (lane = 0; lane < LANES; lane = lane + 1) begin : g_lane
      reg signed [63:0] norm_product_q;
      wire signed [63:0] norm_shifted_full_w;
      wire signed [NORM_REDUCED_W-1:0] norm_reduced_w;
      wire signed [63:0] scale_product_w;
      reg signed [15:0] scale_mant_q;
      reg [5:0] scale_shift_q;
      reg [5:0] scale_shift_s1_q;
      reg [5:0] result_shift_q;
      reg signed [63:0] shifted_w;
      reg round_increment_w;
      wire round_increment_value_w;
      reg signed [8:0] rounded_narrow_w;
      reg signed [OUT_W-1:0] result_q;

      reciprocal_lut u_reciprocal (
        .clk(gated_clk_w), .rst_n(rst_n), .valid_i(valid_i),
        .value_i(l_rows_i[lane*LSE_W +: LSE_W]),
        .valid_o(reciprocal_valid_w[lane]),
        .reciprocal_o(reciprocal_w[lane*32 +: 32])
      );

      assign out_rows_o[lane*OUT_W +: OUT_W] = $unsigned(result_q);
      assign norm_shifted_full_w =
          $signed(norm_product_q) >>> `ATTN_BETA_FRAC;
      assign norm_reduced_w =
          $signed(norm_shifted_full_w[NORM_REDUCED_W-1:0]);
      assign round_increment_value_w =
          round_increment(scale_product_w, result_shift_q);

      fa_signed_mult_pipe2 #(
        .A_W(NORM_REDUCED_W), .B_W(16), .SPLIT_W(24)
      ) u_output_scale_multiplier (
        .clk(gated_clk_w), .rst_n(rst_n), .valid_i(norm_valid_q),
        .a_i(norm_reduced_w), .b_i(scale_mant_q),
        .valid_o(scale_product_valid_w[lane]), .product_o(scale_product_w)
      );

`ifndef SYNTHESIS
      // ACC32 times the bounded reciprocal is below 2^61 in magnitude; after the
      // Q1.15 shift it must be a sign extension of this conservative 48-bit slice.
      always @(posedge gated_clk_w)
        if (rst_n && norm_valid_q &&
            norm_shifted_full_w !=
            {{(64-NORM_REDUCED_W){norm_reduced_w[NORM_REDUCED_W-1]}},
             norm_reduced_w})
          $fatal(1, "online_normalizer reduced operand overflow lane=%0d", lane);
`endif

      // Shift first, then round only the 9-bit saturation candidate. This removes
      // the former 64-bit rounding-bias adder and its reported ripple carry path.
      always @(*) begin
        shifted_w = $signed(scale_product_w) >>> result_shift_q;
        round_increment_w = round_increment_value_w;
        rounded_narrow_w =
            $signed({shifted_w[OUT_W-1], shifted_w[OUT_W-1:0]}) +
            $signed({{8{1'b0}}, round_increment_w});
      end

      // Payload registers are valid-qualified and intentionally unreset. The first
      // multiply is 32x33; the exact 48x16 scale uses the shared two-stage wrapper.
      always @(posedge gated_clk_w) begin
        if (all_reciprocal_valid_w) begin
          norm_product_q <=
              $signed({{(64-ACC_W){acc_s2_q[lane*ACC_W+ACC_W-1]}},
                       acc_s2_q[lane*ACC_W +: ACC_W]}) *
              $signed({1'b0, reciprocal_w[lane*32 +: 32]});
          scale_mant_q <= $signed(scale_s2_q[15:0]);
          scale_shift_q <= scale_s2_q[21:16];
        end
        if (norm_valid_q)
          scale_shift_s1_q <= scale_shift_q;
        if (mult_metadata_valid_s1_q)
          result_shift_q <= scale_shift_s1_q;
        if (scale_product_valid_w[lane]) begin
          if (shifted_w > 64'sd127 || rounded_narrow_w > 9'sd127)
            result_q <= 8'sd127;
          else if (shifted_w < -64'sd128 || rounded_narrow_w < -9'sd128)
            result_q <= -8'sd128;
          else
            result_q <= $signed(rounded_narrow_w[OUT_W-1:0]);
        end
      end
    end
  endgenerate

  // Delay O, scale, and tag to match reciprocal latency before the lane pipelines.
  always @(posedge gated_clk_w or negedge rst_n) begin
    if (!rst_n) begin
      norm_valid_q <= 1'b0;
      mult_metadata_valid_s1_q <= 1'b0;
      valid_o <= 1'b0;
    end else begin
      acc_s0_q <= acc_rows_i;
      acc_s1_q <= acc_s0_q;
      acc_s2_q <= acc_s1_q;
      scale_s0_q <= out_scale_i;
      scale_s1_q <= scale_s0_q;
      scale_s2_q <= scale_s1_q;
      tag_s0_q <= tag_i;
      tag_s1_q <= tag_s0_q;
      tag_s2_q <= tag_s1_q;
      norm_valid_q <= all_reciprocal_valid_w;
      mult_metadata_valid_s1_q <= norm_valid_q;
      valid_o <= all_scale_product_valid_w;
      if (all_reciprocal_valid_w)
        norm_tag_q <= tag_s2_q;
      if (norm_valid_q)
        mult_tag_s1_q <= norm_tag_q;
      if (mult_metadata_valid_s1_q)
        mult_tag_s2_q <= mult_tag_s1_q;
      if (all_scale_product_valid_w)
        tag_o <= mult_tag_s2_q;
    end
  end

endmodule
