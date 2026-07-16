`timescale 1ns/1ps
`include "attention_defines.vh"

module block_lse_update (
  input                         clk,
  input                         rst_n,
  input                         valid_i,
  input                         init_i,
  input signed [15:0]           m_old_i,
  input      [31:0]             l_old_i,
  input signed [15:0]           block_max_i,
  input      [31:0]             block_sum_i,
  output reg                    valid_o,
  output reg signed [15:0]      m_new_o,
  output reg [31:0]             l_new_o,
  output reg [15:0]             alpha_o
);

  wire signed [15:0] m_select_w;
  wire signed [15:0] delta_w;
  wire exp_valid_w;
  wire [15:0] exp_alpha_w;
  reg init_d0_q;
  reg init_d1_q;
  reg signed [15:0] m_d0_q;
  reg signed [15:0] m_d1_q;
  reg [31:0] l_d0_q;
  reg [31:0] l_d1_q;
  reg [31:0] sum_d0_q;
  reg [31:0] sum_d1_q;
  reg [47:0] old_scaled_w;
  reg [47:0] l_total_w;

  assign m_select_w = init_i ? block_max_i : (($signed(m_old_i) >= $signed(block_max_i)) ? m_old_i : block_max_i);
  assign delta_w = init_i ? 16'sd0 : (m_old_i - m_select_w);

  pwl_exp_unit u_alpha_exp (
    .clk(clk), .rst_n(rst_n), .valid_i(valid_i), .x_i(delta_w),
    .valid_o(exp_valid_w), .y_o(exp_alpha_w)
  );

  always @(*) begin
    old_scaled_w = {16'd0, l_d1_q} * {32'd0, (init_d1_q ? 16'd0 : exp_alpha_w)};
    l_total_w = (old_scaled_w >> `ATTN_BETA_FRAC) + sum_d1_q;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      init_d0_q <= 1'b0;
      init_d1_q <= 1'b0;
      m_d0_q <= 16'sd0;
      m_d1_q <= 16'sd0;
      l_d0_q <= 32'd0;
      l_d1_q <= 32'd0;
      sum_d0_q <= 32'd0;
      sum_d1_q <= 32'd0;
      valid_o <= 1'b0;
      m_new_o <= 16'sd0;
      l_new_o <= 32'd0;
      alpha_o <= 16'd0;
    end else begin
      valid_o <= exp_valid_w;
      if (valid_i) begin
        init_d0_q <= init_i;
        m_d0_q <= m_select_w;
        l_d0_q <= l_old_i;
        sum_d0_q <= block_sum_i;
      end
      init_d1_q <= init_d0_q;
      m_d1_q <= m_d0_q;
      l_d1_q <= l_d0_q;
      sum_d1_q <= sum_d0_q;
      if (exp_valid_w) begin
        m_new_o <= m_d1_q;
        l_new_o <= (l_total_w[47:32] != 0) ? 32'hffff_ffff : l_total_w[31:0];
        alpha_o <= init_d1_q ? 16'd0 : exp_alpha_w;
      end
    end
  end

endmodule
