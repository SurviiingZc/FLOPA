`timescale 1ns/1ps

// Dedicated score scaling path used before PWL exp. Zero point, rounding mode,
// and saturation policy are fixed by the FlashAttention score format, avoiding
// 32 copies of unused generic requantization controls and constant networks.
module score_scale_pipe #(
  parameter integer IN_W = 32,
  parameter integer SCALE_W = 16,
  parameter integer OUT_W = 16
)(
  input                              clk,
  input                              rst_n,
  input                              valid_i,
  input signed [IN_W-1:0]            data_i,
  input signed [SCALE_W-1:0]         scale_mant_i,
  input        [5:0]                 shift_i,
  output reg                         valid_o,
  output reg signed [OUT_W-1:0]      data_o
);

  localparam integer PROD_W = IN_W + SCALE_W;
  localparam integer MULT_SPLIT_W = (IN_W > 24) ? 24 : (IN_W / 2);
  localparam integer FORMAT_W = OUT_W + 2;
  localparam signed [FORMAT_W-1:0] OUT_MAX =
      {2'b00, 1'b0, {(OUT_W-1){1'b1}}};
  localparam signed [FORMAT_W-1:0] OUT_MIN =
      {2'b11, 1'b1, {(OUT_W-1){1'b0}}};

  reg valid_s0_q;
  reg metadata_valid_s1_q;
  reg valid_s3_q;
  reg signed [IN_W-1:0] data_s0_q;
  reg signed [SCALE_W-1:0] scale_s0_q;
  reg [5:0] shift_s0_q;
  reg [5:0] shift_s1_q;
  reg [5:0] shift_s2_q;
  reg signed [FORMAT_W-1:0] formatted_s3_q;

  wire multiplier_valid_w;
  wire signed [PROD_W-1:0] multiplier_product_w;
  wire signed [63:0] product_extended_w =
      $signed({{(64-PROD_W){multiplier_product_w[PROD_W-1]}},
               multiplier_product_w});
  wire signed [63:0] shifted_base_w =
      $signed(product_extended_w) >>> shift_s2_q;

  reg guard_w;
  reg sticky_w;
  reg round_increment_w;
  reg signed [FORMAT_W-1:0] shifted_clamped_w;
  reg signed [FORMAT_W-1:0] formatted_w;
  integer discarded_bit;

  // Round to nearest, with negative exact ties remaining at the arithmetic-shift
  // value (away from zero). Clamp before the narrow registered saturation stage.
  always @(*) begin
    guard_w = 1'b0;
    sticky_w = 1'b0;
    if (shift_s2_q != 0) begin
      guard_w = product_extended_w[shift_s2_q-1'b1];
      for (discarded_bit = 0; discarded_bit < 63;
           discarded_bit = discarded_bit + 1)
        if ($unsigned(discarded_bit) <
            $unsigned({26'd0, (shift_s2_q-1'b1)}))
          sticky_w = sticky_w | product_extended_w[discarded_bit];
    end
    round_increment_w = guard_w &&
        (!product_extended_w[63] || sticky_w);

    if (shifted_base_w > 64'sd65535)
      shifted_clamped_w = $signed({2'b00, {OUT_W{1'b1}}});
    else if (shifted_base_w < -64'sd65536)
      shifted_clamped_w = $signed({2'b10, {OUT_W{1'b0}}});
    else
      shifted_clamped_w = $signed(shifted_base_w[FORMAT_W-1:0]);
    formatted_w = $signed(shifted_clamped_w) +
        $signed({{(FORMAT_W-1){1'b0}}, round_increment_w});
  end

  fa_signed_mult_pipe2 #(
    .A_W(IN_W), .B_W(SCALE_W), .SPLIT_W(MULT_SPLIT_W)
  ) u_scale_multiplier (
    .clk(clk), .rst_n(rst_n), .valid_i(valid_s0_q),
    .a_i(data_s0_q), .b_i(scale_s0_q),
    .valid_o(multiplier_valid_w), .product_o(multiplier_product_w)
  );

  // Five-cycle latency from valid_i to valid_o, with one request accepted per
  // cycle. Only valid state is reset; valid-qualified arithmetic payload is not.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s0_q <= 1'b0;
      metadata_valid_s1_q <= 1'b0;
      valid_s3_q <= 1'b0;
      valid_o <= 1'b0;
    end else begin
      valid_s0_q <= valid_i;
      metadata_valid_s1_q <= valid_s0_q;
      valid_s3_q <= multiplier_valid_w;
      valid_o <= valid_s3_q;

      if (valid_i) begin
        data_s0_q <= data_i;
        scale_s0_q <= scale_mant_i;
        shift_s0_q <= shift_i;
      end
      if (valid_s0_q)
        shift_s1_q <= shift_s0_q;
      if (metadata_valid_s1_q)
        shift_s2_q <= shift_s1_q;
      if (multiplier_valid_w)
        formatted_s3_q <= formatted_w;
      if (valid_s3_q) begin
        if (formatted_s3_q > OUT_MAX)
          data_o <= $signed({1'b0, {(OUT_W-1){1'b1}}});
        else if (formatted_s3_q < OUT_MIN)
          data_o <= $signed({1'b1, {(OUT_W-1){1'b0}}});
        else
          data_o <= $signed(formatted_s3_q[OUT_W-1:0]);
      end
    end
  end

endmodule
