`timescale 1ns/1ps
`include "attention_defines.vh"

module online_normalizer (
  input                    clk,
  input                    rst_n,
  input                    valid_i,
  input      [32*32-1:0]   acc_row_i,
  input      [31:0]        l_i,
  input      [31:0]        out_scale_i,
  output reg               valid_o,
  output reg [32*8-1:0]    out_row_o
);

  wire reciprocal_valid_w;
  wire [31:0] reciprocal_w;
  reg [32*32-1:0] acc_row_q;
  reg [31:0] scale_q;
  integer lane;

  function signed [7:0] normalize_lane;
    input signed [31:0] acc;
    input [31:0] reciprocal;
    input signed [15:0] scale_mant;
    input [5:0] scale_shift;
    reg signed [63:0] product_norm;
    reg signed [63:0] product_scale;
    reg signed [63:0] rounded_scale;
    reg signed [63:0] shifted;
    begin
      product_norm = $signed({{32{acc[31]}}, acc}) * $signed({32'd0, reciprocal});
      product_scale = (product_norm >>> `ATTN_BETA_FRAC) *
                      $signed({{48{scale_mant[15]}}, scale_mant});
      rounded_scale = product_scale;
      if (scale_shift != 0) begin
        if (product_scale >= 0) rounded_scale = product_scale + (64'sd1 <<< (scale_shift - 1'b1));
        else rounded_scale = product_scale - (64'sd1 <<< (scale_shift - 1'b1));
      end
      shifted = rounded_scale >>> scale_shift;
      if (shifted > 64'sd127) normalize_lane = 8'sd127;
      else if (shifted < -64'sd128) normalize_lane = -8'sd128;
      else normalize_lane = shifted[7:0];
    end
  endfunction

  reciprocal_lut u_reciprocal (
    .clk(clk), .rst_n(rst_n), .valid_i(valid_i), .value_i(l_i),
    .valid_o(reciprocal_valid_w), .reciprocal_o(reciprocal_w)
  );

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_row_q <= {(32*32){1'b0}};
      scale_q <= 32'd0;
      valid_o <= 1'b0;
      out_row_o <= {(32*8){1'b0}};
    end else begin
      valid_o <= reciprocal_valid_w;
      if (valid_i) begin
        acc_row_q <= acc_row_i;
        scale_q <= out_scale_i;
      end
      if (reciprocal_valid_w) begin
        for (lane = 0; lane < 32; lane = lane + 1) begin
          out_row_o[lane*8 +: 8] <= normalize_lane(
            acc_row_q[lane*32 +: 32], reciprocal_w, scale_q[15:0], scale_q[21:16]);
        end
      end
    end
  end

endmodule
