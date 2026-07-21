`timescale 1ns/1ps
`include "fixed_defs.vh"

// Fixed-point scale/requantize pipeline with a true two-stage signed multiplier,
// rounded shift plus zero point, and selectable INT8/INT16 saturation.
module scale_requant_unit #(
  parameter IN_W = 32,
  parameter SCALE_W = 16,
  parameter OUT_W = 16
)(
  input                         clk,
  input                         rst_n,
  input                         valid_i,
  input signed [IN_W-1:0]       data_i,
  input signed [SCALE_W-1:0]    scale_mant_i,
  input      [5:0]              shift_i,
  input signed [15:0]           zero_point_i,
  input      [1:0]              round_mode_i,
  input      [1:0]              sat_mode_i,
  output reg                    valid_o,
  output reg signed [OUT_W-1:0] data_o
);

  localparam PROD_W = IN_W + SCALE_W;
  localparam MULT_SPLIT_W = (IN_W > 24) ? 24 : (IN_W / 2);
  localparam FORMAT_W = 18;
  localparam signed [FORMAT_W-1:0] INT8_MAX_EXT = 127;
  localparam signed [FORMAT_W-1:0] INT8_MIN_EXT = -128;
  localparam signed [FORMAT_W-1:0] INT16_MAX_EXT = 32767;
  localparam signed [FORMAT_W-1:0] INT16_MIN_EXT = -32768;
  reg valid_s0_q;
  reg metadata_valid_s1_q;
  reg signed [IN_W-1:0] data_s0_q;
  reg signed [SCALE_W-1:0] scale_s0_q;
  reg [5:0] shift_s0_q;
  reg signed [15:0] zp_s0_q;
  reg [1:0] round_s0_q;
  reg [1:0] sat_s0_q;
  reg [5:0] shift_s1_q;
  reg signed [15:0] zp_s1_q;
  reg [1:0] round_s1_q;
  reg [1:0] sat_s1_q;
  reg [5:0] shift_s2_q;
  reg signed [15:0] zp_s2_q;
  reg [1:0] round_s2_q;
  reg [1:0] sat_s2_q;
  reg signed [FORMAT_W-1:0] shifted_s3_q;
  reg [1:0] sat_s3_q;
  reg valid_s3_q;
  wire multiplier_valid_w;
  wire signed [PROD_W-1:0] multiplier_product_w;
  reg signed [63:0] product_extended_w;
  reg signed [63:0] shifted_base_w;
  reg signed [FORMAT_W-1:0] shifted_clamped_w;
  reg signed [FORMAT_W-1:0] biased_w;
  reg guard_w;
  reg sticky_w;
  reg round_increment_w;
  integer discarded_bit;

  // Shift before rounding and clamp to the only range that a signed 16-bit zero
  // point can bring back into INT16. The remaining add is 18 bits instead of a
  // PROD_W-wide carry chain, which bounds this path for all configured widths.
  always @(*) begin
    product_extended_w =
        {{(64-PROD_W){multiplier_product_w[PROD_W-1]}}, multiplier_product_w};
    shifted_base_w = $signed(product_extended_w) >>> shift_s2_q;
    guard_w = 1'b0;
    sticky_w = 1'b0;
    if (shift_s2_q != 0) begin
      guard_w = product_extended_w[shift_s2_q-1'b1];
      for (discarded_bit = 0; discarded_bit < 63;
           discarded_bit = discarded_bit + 1)
        if (discarded_bit < {26'd0, (shift_s2_q-1'b1)})
          sticky_w = sticky_w | product_extended_w[discarded_bit];
    end
    round_increment_w = round_s2_q == `ATTN_ROUND_NEAREST && guard_w &&
        (!product_extended_w[63] || sticky_w);

    if (shifted_base_w > 64'sd65535)
      shifted_clamped_w = 18'sd65535;
    else if (shifted_base_w < -64'sd65536)
      shifted_clamped_w = -18'sd65536;
    else
      shifted_clamped_w = shifted_base_w[FORMAT_W-1:0];

    biased_w = shifted_clamped_w +
        {{(FORMAT_W-16){zp_s2_q[15]}}, zp_s2_q} +
        {{(FORMAT_W-1){1'b0}}, round_increment_w};
  end

  fa_signed_mult_pipe2 #(
    .A_W(IN_W), .B_W(SCALE_W), .SPLIT_W(MULT_SPLIT_W)
  ) u_scale_multiplier (
    .clk(clk), .rst_n(rst_n), .valid_i(valid_s0_q),
    .a_i(data_s0_q), .b_i(scale_s0_q),
    .valid_o(multiplier_valid_w), .product_o(multiplier_product_w)
  );

  // Valid and all formatting controls are pipelined with the corresponding data.
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
        zp_s0_q <= zero_point_i;
        round_s0_q <= round_mode_i;
        sat_s0_q <= sat_mode_i;
      end
      if (valid_s0_q) begin
        shift_s1_q <= shift_s0_q;
        zp_s1_q <= zp_s0_q;
        round_s1_q <= round_s0_q;
        sat_s1_q <= sat_s0_q;
      end
      if (metadata_valid_s1_q) begin
        shift_s2_q <= shift_s1_q;
        zp_s2_q <= zp_s1_q;
        round_s2_q <= round_s1_q;
        sat_s2_q <= sat_s1_q;
      end
      if (multiplier_valid_w) begin
        shifted_s3_q <= biased_w;
        sat_s3_q <= sat_s2_q;
      end
      if (valid_s3_q) begin
        if (sat_s3_q == `ATTN_SAT_INT8) begin
          if (shifted_s3_q > INT8_MAX_EXT) data_o <= {{(OUT_W-8){1'b0}}, 8'h7f};
          else if (shifted_s3_q < INT8_MIN_EXT) data_o <= {{(OUT_W-8){1'b1}}, 8'h80};
          else data_o <= {{(OUT_W-8){shifted_s3_q[7]}}, shifted_s3_q[7:0]};
        end else begin
          if (shifted_s3_q > INT16_MAX_EXT) data_o <= {{(OUT_W-16){1'b0}}, 16'h7fff};
          else if (shifted_s3_q < INT16_MIN_EXT) data_o <= {{(OUT_W-16){1'b1}}, 16'h8000};
          else data_o <= shifted_s3_q[OUT_W-1:0];
        end
      end
    end
  end

endmodule
