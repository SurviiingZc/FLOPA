`timescale 1ns/1ps
`include "fixed_defs.vh"

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
  localparam signed [PROD_W:0] INT8_MAX_EXT = 127;
  localparam signed [PROD_W:0] INT8_MIN_EXT = -128;
  localparam signed [PROD_W:0] INT16_MAX_EXT = 32767;
  localparam signed [PROD_W:0] INT16_MIN_EXT = -32768;
  reg valid_s0_q;
  reg valid_s1_q;
  reg signed [IN_W-1:0] data_s0_q;
  reg signed [SCALE_W-1:0] scale_s0_q;
  reg [5:0] shift_s0_q;
  reg signed [15:0] zp_s0_q;
  reg [1:0] round_s0_q;
  reg [1:0] sat_s0_q;
  reg signed [PROD_W-1:0] product_s1_q;
  reg [5:0] shift_s1_q;
  reg signed [15:0] zp_s1_q;
  reg [1:0] round_s1_q;
  reg [1:0] sat_s1_q;
  reg signed [PROD_W:0] shifted_s2_q;
  reg [1:0] sat_s2_q;
  reg valid_s2_q;
  reg signed [PROD_W:0] rounded_w;
  reg signed [PROD_W:0] biased_w;
  reg signed [PROD_W:0] round_bias_w;

  always @(*) begin
    rounded_w = {product_s1_q[PROD_W-1], product_s1_q};
    round_bias_w = {{PROD_W{1'b0}}, 1'b1};
    if (round_s1_q == `ATTN_ROUND_NEAREST && shift_s1_q != 0) begin
      if (product_s1_q >= 0)
        rounded_w = {product_s1_q[PROD_W-1], product_s1_q} +
                    (round_bias_w <<< (shift_s1_q - 1'b1));
      else
        rounded_w = {product_s1_q[PROD_W-1], product_s1_q} -
                    (round_bias_w <<< (shift_s1_q - 1'b1));
    end
    biased_w = (rounded_w >>> shift_s1_q) + zp_s1_q;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s0_q <= 1'b0;
      valid_s1_q <= 1'b0;
      valid_s2_q <= 1'b0;
      valid_o <= 1'b0;
      data_s0_q <= {IN_W{1'b0}};
      scale_s0_q <= {SCALE_W{1'b0}};
      shift_s0_q <= 6'd0;
      zp_s0_q <= 16'sd0;
      round_s0_q <= 2'd0;
      sat_s0_q <= 2'd0;
      product_s1_q <= {PROD_W{1'b0}};
      shift_s1_q <= 6'd0;
      zp_s1_q <= 16'sd0;
      round_s1_q <= 2'd0;
      sat_s1_q <= 2'd0;
      shifted_s2_q <= {(PROD_W+1){1'b0}};
      sat_s2_q <= 2'd0;
      data_o <= {OUT_W{1'b0}};
    end else begin
      valid_s0_q <= valid_i;
      valid_s1_q <= valid_s0_q;
      valid_s2_q <= valid_s1_q;
      valid_o <= valid_s2_q;

      if (valid_i) begin
        data_s0_q <= data_i;
        scale_s0_q <= scale_mant_i;
        shift_s0_q <= shift_i;
        zp_s0_q <= zero_point_i;
        round_s0_q <= round_mode_i;
        sat_s0_q <= sat_mode_i;
      end
      if (valid_s0_q) begin
        product_s1_q <= $signed({{SCALE_W{data_s0_q[IN_W-1]}}, data_s0_q}) *
                        $signed({{IN_W{scale_s0_q[SCALE_W-1]}}, scale_s0_q});
        shift_s1_q <= shift_s0_q;
        zp_s1_q <= zp_s0_q;
        round_s1_q <= round_s0_q;
        sat_s1_q <= sat_s0_q;
      end
      if (valid_s1_q) begin
        shifted_s2_q <= biased_w;
        sat_s2_q <= sat_s1_q;
      end
      if (valid_s2_q) begin
        if (sat_s2_q == `ATTN_SAT_INT8) begin
          if (shifted_s2_q > INT8_MAX_EXT) data_o <= {{(OUT_W-8){1'b0}}, 8'h7f};
          else if (shifted_s2_q < INT8_MIN_EXT) data_o <= {{(OUT_W-8){1'b1}}, 8'h80};
          else data_o <= {{(OUT_W-8){shifted_s2_q[7]}}, shifted_s2_q[7:0]};
        end else begin
          if (shifted_s2_q > INT16_MAX_EXT) data_o <= {{(OUT_W-16){1'b0}}, 16'h7fff};
          else if (shifted_s2_q < INT16_MIN_EXT) data_o <= {{(OUT_W-16){1'b1}}, 16'h8000};
          else data_o <= shifted_s2_q[OUT_W-1:0];
        end
      end
    end
  end

endmodule
