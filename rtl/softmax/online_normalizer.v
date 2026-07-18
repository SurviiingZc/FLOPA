`timescale 1ns/1ps
`include "attention_defines.vh"

module online_normalizer #(
  parameter integer LANES = `ATTN_ARRAY_COLS,
  parameter integer ACC_W = `ATTN_ACC_W,
  parameter integer OUT_W = `ATTN_OUT_W
)(
  input                         clk,
  input                         rst_n,
  input                         valid_i,
  input      [LANES*ACC_W-1:0]  acc_row_i,
  input      [31:0]             l_i,
  input      [31:0]             out_scale_i,
  output reg                    valid_o,
  output     [LANES*OUT_W-1:0]  out_row_o
);

  wire reciprocal_valid_w;
  wire [31:0] reciprocal_w;
  reg [LANES*ACC_W-1:0] acc_row_q;
  reg [31:0] scale_q;
  reg norm_valid_q;
  reg scale_valid_q;

  reciprocal_lut u_reciprocal (
    .clk(clk), .rst_n(rst_n), .valid_i(valid_i), .value_i(l_i),
    .valid_o(reciprocal_valid_w), .reciprocal_o(reciprocal_w)
  );

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_row_q <= {LANES*ACC_W{1'b0}};
      scale_q <= 32'd0;
      norm_valid_q <= 1'b0;
      scale_valid_q <= 1'b0;
      valid_o <= 1'b0;
    end else begin
      norm_valid_q <= reciprocal_valid_w;
      scale_valid_q <= norm_valid_q;
      valid_o <= scale_valid_q;
      if (valid_i) begin
        acc_row_q <= acc_row_i;
        scale_q <= out_scale_i;
      end
    end
  end

  generate
    genvar lane;
    for (lane = 0; lane < LANES; lane = lane + 1) begin : g_lane
      reg signed [63:0] norm_product_q;
      reg signed [63:0] scale_product_q;
      reg signed [15:0] scale_mant_q;
      reg [5:0] scale_shift_q;
      reg [5:0] result_shift_q;
      reg signed [63:0] rounded_w;
      reg signed [63:0] shifted_w;
      reg signed [OUT_W-1:0] result_q;

      assign out_row_o[lane*OUT_W +: OUT_W] = result_q;

      always @(*) begin
        rounded_w = scale_product_q;
        if (result_shift_q != 0) begin
          if (scale_product_q >= 0)
            rounded_w = scale_product_q + (64'sd1 <<< (result_shift_q - 1'b1));
          else
            rounded_w = scale_product_q - (64'sd1 <<< (result_shift_q - 1'b1));
        end
        shifted_w = rounded_w >>> result_shift_q;
      end

      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          norm_product_q <= 64'sd0;
          scale_product_q <= 64'sd0;
          scale_mant_q <= 16'sd0;
          scale_shift_q <= 6'd0;
          result_shift_q <= 6'd0;
          result_q <= {OUT_W{1'b0}};
        end else begin
          if (reciprocal_valid_w) begin
            norm_product_q <=
                $signed({{(64-ACC_W){acc_row_q[lane*ACC_W+ACC_W-1]}},
                         acc_row_q[lane*ACC_W +: ACC_W]}) *
                $signed({1'b0, reciprocal_w});
            scale_mant_q <= scale_q[15:0];
            scale_shift_q <= scale_q[21:16];
          end
          if (norm_valid_q) begin
            scale_product_q <=
                $signed(norm_product_q >>> `ATTN_BETA_FRAC) *
                $signed(scale_mant_q);
            result_shift_q <= scale_shift_q;
          end
          if (scale_valid_q) begin
            if (shifted_w > 64'sd127)
              result_q <= 8'sd127;
            else if (shifted_w < -64'sd128)
              result_q <= -8'sd128;
            else
              result_q <= shifted_w[OUT_W-1:0];
          end
        end
      end
    end
  endgenerate

endmodule
