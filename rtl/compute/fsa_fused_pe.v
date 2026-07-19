`timescale 1ns/1ps
`include "attention_defines.vh"

module os_fsa_fused_pe #(
  parameter integer DATA_W = `ATTN_ARRAY_DATA_W,
  parameter integer SCORE_W = `ATTN_ACC_W,
  parameter integer PROB_W = `ATTN_BETA_W,
  parameter integer ACC_W = `ATTN_ACC_W,
  parameter integer SUM_W = `ATTN_LSE_W
)(
  input                         clk,
  input                         rst_n,
  input                         clear_i,
  input                         clear_score_i,
  input                         clear_acc_i,
  input                         load_acc_i,
  input      [ACC_W-1:0]        load_acc_data_i,
  input                         mac_is_pv_i,

  input                         q_valid_i,
  input                         q_last_i,
  input      [DATA_W-1:0]       q_data_i,
  output reg                    q_valid_o,
  output reg                    q_last_o,
  output reg [DATA_W-1:0]       q_data_o,

  input                         k_valid_i,
  input                         k_last_i,
  input      [DATA_W-1:0]       k_data_i,
  output reg                    k_valid_o,
  output reg                    k_last_o,
  output reg [DATA_W-1:0]       k_data_o,

  input                         score_lane_valid_i,

  input                         max_valid_i,
  input      [SCORE_W-1:0]      max_data_i,
  output reg                    max_valid_o,
  output reg [SCORE_W-1:0]      max_data_o,

  input                         m_valid_i,
  input      [SCORE_W-1:0]      m_data_i,
  output reg                    m_valid_o,
  output reg [SCORE_W-1:0]      m_data_o,
  output     [SCORE_W-1:0]      delta_o,

  input                         prob_load_i,
  input      [PROB_W-1:0]       prob_data_i,
  output     [PROB_W-1:0]       prob_o,
  input                         prob_shift_load_i,
  input                         prob_shift_en_i,
  input      [PROB_W-1:0]       prob_shift_i,
  output     [PROB_W-1:0]       prob_shift_o,

  input                         sum_valid_i,
  input      [SUM_W-1:0]        sum_data_i,
  output reg                    sum_valid_o,
  output reg [SUM_W-1:0]        sum_data_o,

  output reg                    mac_valid_o,
  output reg                    mac_last_o,
  output     [ACC_W-1:0]        acc_o
);

  localparam signed [SCORE_W-1:0] SCORE_MIN = {1'b1, {(SCORE_W-1){1'b0}}};

  localparam integer ACCUM_W = (SCORE_W > ACC_W) ? SCORE_W : ACC_W;

  reg signed [ACCUM_W-1:0] accum_q;
  reg [PROB_W-1:0] prob_q;
  reg [PROB_W-1:0] prob_shift_q;
  reg signed [2*DATA_W-1:0] product_w;
  reg signed [SCORE_W:0] score_next_w;
  reg signed [ACC_W:0] acc_next_w;
  reg signed [SCORE_W-1:0] delta_w;
  reg signed [SCORE_W-1:0] max_score_w;

`ifndef SYNTHESIS
  initial begin
    if (SCORE_W != ACC_W)
      $fatal(1, "os_fsa_fused_pe requires SCORE_W == ACC_W");
  end
`endif

  assign delta_o = accum_q[SCORE_W-1:0];
  assign prob_o = prob_q;
  assign prob_shift_o = prob_shift_q;
  assign acc_o = accum_q[ACC_W-1:0];

  always @(*) begin
    product_w = {2*DATA_W{1'b0}};
    score_next_w = {accum_q[SCORE_W-1], accum_q[SCORE_W-1:0]};
    acc_next_w = {accum_q[ACC_W-1], accum_q[ACC_W-1:0]};
    if (q_valid_i && k_valid_i) begin
      product_w = $signed({{DATA_W{q_data_i[DATA_W-1]}}, q_data_i}) *
                  $signed({{DATA_W{k_data_i[DATA_W-1]}}, k_data_i});
      score_next_w = {accum_q[SCORE_W-1], accum_q[SCORE_W-1:0]} +
                     {{(SCORE_W+1-2*DATA_W){product_w[2*DATA_W-1]}}, product_w};
      acc_next_w = {accum_q[ACC_W-1], accum_q[ACC_W-1:0]} +
                   {{(ACC_W+1-2*DATA_W){product_w[2*DATA_W-1]}}, product_w};
    end
    delta_w = score_lane_valid_i ?
              $signed(accum_q[SCORE_W-1:0]) - $signed(m_data_i) : SCORE_MIN;
    max_score_w = score_lane_valid_i ? accum_q[SCORE_W-1:0] : SCORE_MIN;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q_valid_o <= 1'b0;
      q_last_o <= 1'b0;
      q_data_o <= {DATA_W{1'b0}};
      k_valid_o <= 1'b0;
      k_last_o <= 1'b0;
      k_data_o <= {DATA_W{1'b0}};
      max_valid_o <= 1'b0;
      max_data_o <= SCORE_MIN;
      m_valid_o <= 1'b0;
      m_data_o <= {SCORE_W{1'b0}};
      sum_valid_o <= 1'b0;
      sum_data_o <= {SUM_W{1'b0}};
      mac_valid_o <= 1'b0;
      mac_last_o <= 1'b0;
      accum_q <= {ACCUM_W{1'b0}};
      prob_q <= {PROB_W{1'b0}};
      prob_shift_q <= {PROB_W{1'b0}};
    end else if (clear_i) begin
      q_valid_o <= 1'b0;
      q_last_o <= 1'b0;
      k_valid_o <= 1'b0;
      k_last_o <= 1'b0;
      max_valid_o <= 1'b0;
      m_valid_o <= 1'b0;
      sum_valid_o <= 1'b0;
      mac_valid_o <= 1'b0;
      mac_last_o <= 1'b0;
      accum_q <= {ACCUM_W{1'b0}};
      prob_q <= {PROB_W{1'b0}};
      prob_shift_q <= {PROB_W{1'b0}};
    end else begin
      q_valid_o <= q_valid_i;
      q_last_o <= q_valid_i && q_last_i;
      k_valid_o <= k_valid_i;
      k_last_o <= k_valid_i && k_last_i;
      max_valid_o <= max_valid_i;
      m_valid_o <= m_valid_i;
      sum_valid_o <= sum_valid_i;
      mac_valid_o <= q_valid_i && k_valid_i;
      mac_last_o <= q_valid_i && k_valid_i && q_last_i && k_last_i;

      if (q_valid_i) q_data_o <= q_data_i;
      if (k_valid_i) k_data_o <= k_data_i;

      if (clear_score_i || clear_acc_i) begin
        accum_q <= {ACCUM_W{1'b0}};
      end else if (load_acc_i) begin
        accum_q <= {{(ACCUM_W-ACC_W){load_acc_data_i[ACC_W-1]}}, load_acc_data_i};
      end else if (m_valid_i) begin
        accum_q <= {{(ACCUM_W-SCORE_W){delta_w[SCORE_W-1]}}, delta_w};
      end else if (q_valid_i && k_valid_i && mac_is_pv_i) begin
        accum_q <= {{(ACCUM_W-ACC_W){acc_next_w[ACC_W-1]}}, acc_next_w[ACC_W-1:0]};
      end else if (q_valid_i && k_valid_i) begin
        accum_q <= {{(ACCUM_W-SCORE_W){score_next_w[SCORE_W-1]}}, score_next_w[SCORE_W-1:0]};
      end

      if (max_valid_i) begin
        if ($signed(max_score_w) >= $signed(max_data_i))
          max_data_o <= max_score_w;
        else
          max_data_o <= max_data_i;
      end

      if (m_valid_i) begin
        m_data_o <= m_data_i;
      end

      if (prob_load_i) prob_q <= prob_data_i;

      if (prob_shift_load_i) begin
        prob_shift_q <= prob_q;
      end else if (prob_shift_en_i) begin
        prob_shift_q <= prob_shift_i;
      end

      if (sum_valid_i)
        sum_data_o <= sum_data_i + {{(SUM_W-PROB_W){1'b0}}, prob_q};
    end
  end

endmodule
