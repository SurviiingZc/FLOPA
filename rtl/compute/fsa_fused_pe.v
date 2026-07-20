`timescale 1ns/1ps
`include "attention_defines.vh"

// One phase-multiplexed PE. QK keeps the score in accum_q; online softmax reuses
// it for score-m_new and prob_q; WS-PV keeps P stationary and forwards tagged sums.
module fsa_fused_pe #(
  parameter integer DATA_W = `ATTN_ARRAY_DATA_W,
  parameter integer SCORE_W = `ATTN_ACC_W,
  parameter integer PROB_W = `ATTN_BETA_W,
  parameter integer SUM_W = `ATTN_LSE_W,
  parameter integer TAG_W = 6
)(
  input                         clk,
  input                         rst_n,
  input                         clear_i,
  input                         clear_score_i,
  input                         ws_pv_i,

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

  input                         sum_valid_i,
  input      [SUM_W-1:0]        sum_data_i,
  input      [TAG_W-1:0]        sum_tag_i,
  output reg                    sum_valid_o,
  output reg [SUM_W-1:0]        sum_data_o,
  output reg [TAG_W-1:0]        sum_tag_o,

  output reg                    mac_last_o
);

  localparam signed [SCORE_W-1:0] SCORE_MIN =
      {1'b1, {(SCORE_W-1){1'b0}}};

  reg signed [SCORE_W-1:0] accum_q;
  reg [PROB_W-1:0] prob_q;
  reg signed [DATA_W:0] mul_a_w;
  reg signed [DATA_W:0] mul_b_w;
  reg signed [2*DATA_W+1:0] shared_product_w;
  reg signed [SUM_W-1:0] ws_product_w;
  reg signed [SCORE_W:0] score_next_w;
  reg signed [SUM_W:0] ws_sum_next_w;
  reg signed [SCORE_W-1:0] delta_w;
  reg signed [SCORE_W-1:0] max_score_w;

`ifndef SYNTHESIS
  initial begin
    if (DATA_W != PROB_W)
      $fatal(1, "fsa_fused_pe requires DATA_W == PROB_W");
    if (SUM_W < DATA_W + PROB_W)
      $fatal(1, "fsa_fused_pe SUM_W is too narrow for P*V");
  end
`endif

  assign delta_o = accum_q;

  // One signed multiplier is shared by Q*K and P*V. Explicit sign/zero extension
  // prevents Verilog expression sizing from truncating signed INT8 products.
  // Invalid operands are forced to zero to reduce multiplier switching activity.
  always @(*) begin
    mul_a_w = {(DATA_W+1){1'b0}};
    mul_b_w = {(DATA_W+1){1'b0}};
    if (ws_pv_i && sum_valid_i && k_valid_i) begin
      mul_a_w = $signed({1'b0, prob_q});
      mul_b_w = $signed({k_data_i[DATA_W-1], k_data_i});
    end else if (!ws_pv_i && q_valid_i && k_valid_i) begin
      mul_a_w = $signed({q_data_i[DATA_W-1], q_data_i});
      mul_b_w = $signed({k_data_i[DATA_W-1], k_data_i});
    end
    shared_product_w =
        $signed({{(DATA_W+1){mul_a_w[DATA_W]}}, mul_a_w}) *
        $signed({{(DATA_W+1){mul_b_w[DATA_W]}}, mul_b_w});
    ws_product_w = {SUM_W{1'b0}};
    score_next_w = {accum_q[SCORE_W-1], accum_q};
    ws_sum_next_w = {sum_data_i[SUM_W-1], sum_data_i};

    if (!ws_pv_i && q_valid_i && k_valid_i) begin
      score_next_w = {accum_q[SCORE_W-1], accum_q} +
          {{(SCORE_W+1-2*DATA_W){shared_product_w[2*DATA_W-1]}},
           shared_product_w[2*DATA_W-1:0]};
    end

    if (ws_pv_i && sum_valid_i && k_valid_i) begin
      ws_product_w =
          {{(SUM_W-2*DATA_W){shared_product_w[2*DATA_W-1]}},
           shared_product_w[2*DATA_W-1:0]};
      ws_sum_next_w = {sum_data_i[SUM_W-1], sum_data_i} +
          {ws_product_w[SUM_W-1], ws_product_w};
    end

    // Masked score lanes contribute -infinity to max and zero probability later.
    delta_w = score_lane_valid_i ?
              $signed(accum_q) - $signed(m_data_i) : SCORE_MIN;
    max_score_w = score_lane_valid_i ? accum_q : SCORE_MIN;
  end

  // Q moves right, K/V moves down, max moves right, m_new moves left, and the
  // sum/tag link reverses for rowsum but moves right for WS-PV.
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
      sum_tag_o <= {TAG_W{1'b0}};
      mac_last_o <= 1'b0;
      accum_q <= {SCORE_W{1'b0}};
      prob_q <= {PROB_W{1'b0}};
    end else if (clear_i) begin
      q_valid_o <= 1'b0;
      q_last_o <= 1'b0;
      k_valid_o <= 1'b0;
      k_last_o <= 1'b0;
      max_valid_o <= 1'b0;
      m_valid_o <= 1'b0;
      sum_valid_o <= 1'b0;
      mac_last_o <= 1'b0;
      accum_q <= {SCORE_W{1'b0}};
      prob_q <= {PROB_W{1'b0}};
    end else begin
      q_valid_o <= q_valid_i;
      q_last_o <= q_valid_i && q_last_i;
      k_valid_o <= k_valid_i;
      k_last_o <= k_valid_i && k_last_i;
      max_valid_o <= max_valid_i;
      m_valid_o <= m_valid_i;
      mac_last_o <= !ws_pv_i && q_valid_i && k_valid_i && q_last_i && k_last_i;

      if (q_valid_i) q_data_o <= q_data_i;
      if (k_valid_i) k_data_o <= k_data_i;

      // Score clear has highest priority; m_valid converts the stored score to
      // delta in place before the probability is loaded into prob_q.
      if (clear_score_i) begin
        accum_q <= {SCORE_W{1'b0}};
      end else if (m_valid_i) begin
        accum_q <= delta_w;
      end else if (!ws_pv_i && q_valid_i && k_valid_i) begin
        accum_q <= score_next_w[SCORE_W-1:0];
      end

      if (max_valid_i) begin
        if ($signed(max_score_w) >= $signed(max_data_i))
          max_data_o <= max_score_w;
        else
          max_data_o <= max_data_i;
      end

      if (m_valid_i) m_data_o <= m_data_i;
      if (prob_load_i) prob_q <= prob_data_i;

      // In WS-PV, sum_tag_i is the full feature ID and remains aligned with every
      // partial sum until the right edge writes O_new[row, feature].
      if (ws_pv_i) begin
        sum_valid_o <= sum_valid_i && k_valid_i;
        if (sum_valid_i && k_valid_i)
          sum_data_o <= ws_sum_next_w[SUM_W-1:0];
        if (sum_valid_i && k_valid_i) sum_tag_o <= sum_tag_i;
      end else begin
        sum_valid_o <= sum_valid_i;
        if (sum_valid_i)
          sum_data_o <= sum_data_i + {{(SUM_W-PROB_W){1'b0}}, prob_q};
        if (sum_valid_i) sum_tag_o <= sum_tag_i;
      end
    end
  end

endmodule
