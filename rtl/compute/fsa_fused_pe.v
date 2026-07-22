`timescale 1ns/1ps
`include "attention_defines.vh"

// One phase-multiplexed PE. QK keeps the score in accum_q; online softmax
// overwrites it with score-m_new and stores probability in prob_q. WS-PV keeps
// probability stationary and forwards a feature-tagged horizontal partial sum.
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

  input                         q_valid_i,
  input      [DATA_W-1:0]       q_data_i,
  output reg                    q_valid_o,
  output reg [DATA_W-1:0]       q_data_o,

  input                         k_valid_i,
  input      [DATA_W-1:0]       k_data_i,
  output reg                    k_valid_o,
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

  input                         pv_mac_valid_i,
  input                         sum_valid_i,
  input      [SUM_W-1:0]        sum_data_i,
  input      [TAG_W-1:0]        sum_tag_i,
  output reg                    sum_valid_o,
  output reg [SUM_W-1:0]        sum_data_o,
  output reg [TAG_W-1:0]        sum_tag_o
);

  localparam integer MUL_A_W = PROB_W + 1;
  localparam integer MUL_B_W = DATA_W + 1;
  localparam integer MUL_PRODUCT_W = MUL_A_W + MUL_B_W;
  localparam integer QK_PRODUCT_W = 2 * DATA_W;
  localparam integer PV_PRODUCT_W = PROB_W + DATA_W;
  localparam integer SHARED_ADD_W =
      ((SCORE_W > SUM_W) ? SCORE_W : SUM_W) + 1;
  localparam signed [SCORE_W-1:0] SCORE_MIN =
      {1'b1, {(SCORE_W-1){1'b0}}};

  reg signed [SCORE_W-1:0] accum_q;
  reg [PROB_W-1:0] prob_q;
  reg signed [MUL_A_W-1:0] mul_a_w;
  reg signed [MUL_B_W-1:0] mul_b_w;
  wire signed [MUL_PRODUCT_W-1:0] shared_product_w;
  reg signed [SHARED_ADD_W-1:0] shared_add_a_w;
  reg signed [SHARED_ADD_W-1:0] shared_add_b_w;
  wire signed [SHARED_ADD_W-1:0] shared_add_result_w =
      $signed(shared_add_a_w) + $signed(shared_add_b_w);
  reg signed [SCORE_W-1:0] delta_w;
  reg signed [SCORE_W-1:0] max_score_w;
  wire qk_mac_valid_w = q_valid_i && k_valid_i;
  wire pv_mac_valid_w = pv_mac_valid_i && sum_valid_i && k_valid_i;

  // QK and PV tokens are mutually exclusive, so one exact 17x9 DesignWare
  // multiplier serves both modes without a second arithmetic unit.
  fa_signed_mult_comb #(
    .A_W(MUL_A_W), .B_W(MUL_B_W)
  ) u_shared_multiplier (
    .a_i(mul_a_w), .b_i(mul_b_w), .product_o(shared_product_w)
  );

`ifndef SYNTHESIS
  initial begin
    if (MUL_A_W < DATA_W + 1)
      $fatal(1, "fsa_fused_pe multiplier A is narrower than signed Q");
    if (SUM_W < PV_PRODUCT_W)
      $fatal(1, "fsa_fused_pe SUM_W is too narrow for unsigned P * signed V");
    if (SCORE_W < QK_PRODUCT_W)
      $fatal(1, "fsa_fused_pe SCORE_W is too narrow for signed Q * signed K");
  end

  always @(posedge clk)
    if (rst_n && qk_mac_valid_w && pv_mac_valid_w)
      $fatal(1, "fsa_fused_pe QK and PV valid tokens overlap");
    else if (rst_n && qk_mac_valid_w && sum_valid_i)
      $fatal(1, "fsa_fused_pe QK and rowsum valid tokens overlap");
    else if (rst_n && pv_mac_valid_i && !(sum_valid_i && k_valid_i))
      $fatal(1, "fsa_fused_pe malformed PV MAC token");
`endif

  assign delta_o = $unsigned(accum_q);

  // Q/K/V remain native INT8 in the array. Only this multiplier boundary grows
  // Q/P to 17 bits and K/V to 9 bits, giving one exact 17x9 shared multiplier.
  // QK, WS-PV, and rowsum are phase-mutually-exclusive, so their former three
  // adders share one 33-bit add datapath with operand isolation.
  always @(*) begin
    mul_a_w = $signed({MUL_A_W{1'b0}});
    mul_b_w = $signed({MUL_B_W{1'b0}});
    if (pv_mac_valid_w) begin
      mul_a_w = $signed({1'b0, prob_q});
      mul_b_w = $signed({k_data_i[DATA_W-1], k_data_i});
    end else if (qk_mac_valid_w) begin
      mul_a_w = $signed({{(MUL_A_W-DATA_W){q_data_i[DATA_W-1]}}, q_data_i});
      mul_b_w = $signed({k_data_i[DATA_W-1], k_data_i});
    end
    shared_add_a_w = $signed({SHARED_ADD_W{1'b0}});
    shared_add_b_w = $signed({SHARED_ADD_W{1'b0}});
    if (qk_mac_valid_w) begin
      shared_add_a_w = $signed({{(SHARED_ADD_W-SCORE_W){accum_q[SCORE_W-1]}},
                                accum_q});
      shared_add_b_w = $signed({{(SHARED_ADD_W-QK_PRODUCT_W){
                                  shared_product_w[QK_PRODUCT_W-1]}},
                                shared_product_w[QK_PRODUCT_W-1:0]});
    end else if (pv_mac_valid_w) begin
      shared_add_a_w = $signed({{(SHARED_ADD_W-SUM_W){sum_data_i[SUM_W-1]}},
                                sum_data_i});
      shared_add_b_w = $signed({{(SHARED_ADD_W-PV_PRODUCT_W){
                                  shared_product_w[PV_PRODUCT_W-1]}},
                                shared_product_w[PV_PRODUCT_W-1:0]});
    end else if (sum_valid_i) begin
      shared_add_a_w = $signed({{(SHARED_ADD_W-SUM_W){sum_data_i[SUM_W-1]}},
                                sum_data_i});
      shared_add_b_w = $signed({{(SHARED_ADD_W-PROB_W){1'b0}}, prob_q});
    end

    // Masked score lanes contribute -infinity to max and zero probability later.
    delta_w = (m_valid_i && score_lane_valid_i) ?
              $signed(accum_q) - $signed(m_data_i) : SCORE_MIN;
    max_score_w = (max_valid_i && score_lane_valid_i) ? accum_q : SCORE_MIN;
  end

  // Only control tokens use asynchronous reset. Payload registers are qualified
  // by these valid bits and therefore do not need a chip-wide reset connection.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q_valid_o <= 1'b0;
      k_valid_o <= 1'b0;
      max_valid_o <= 1'b0;
      m_valid_o <= 1'b0;
      sum_valid_o <= 1'b0;
    end else if (clear_i) begin
      q_valid_o <= 1'b0;
      k_valid_o <= 1'b0;
      max_valid_o <= 1'b0;
      m_valid_o <= 1'b0;
      sum_valid_o <= 1'b0;
    end else begin
      q_valid_o <= q_valid_i;
      k_valid_o <= k_valid_i;
      max_valid_o <= max_valid_i;
      m_valid_o <= m_valid_i;
      sum_valid_o <= sum_valid_i;
    end
  end

  // Score and probability are phase state, so they retain deterministic reset and
  // clear behavior but use synchronous reset muxes rather than asynchronous pins.
  always @(posedge clk) begin
    if (!rst_n || clear_i) begin
      accum_q <= $signed({SCORE_W{1'b0}});
      prob_q <= {PROB_W{1'b0}};
    end else begin
      if (clear_score_i)
        accum_q <= $signed({SCORE_W{1'b0}});
      else if (m_valid_i)
        accum_q <= delta_w;
      else if (qk_mac_valid_w)
        accum_q <= $signed(shared_add_result_w[SCORE_W-1:0]);
      if (prob_load_i) prob_q <= prob_data_i;
    end
  end

  // Data is updated only with its corresponding valid token. Leaving it unreset
  // removes reset-tree load without allowing an invalid payload to be consumed.
  always @(posedge clk) begin
    if (rst_n && !clear_i) begin
      if (q_valid_i) q_data_o <= q_data_i;
      if (k_valid_i) k_data_o <= k_data_i;
      if (max_valid_i) begin
        if ($signed(max_score_w) >= $signed(max_data_i))
          max_data_o <= $unsigned(max_score_w);
        else
          max_data_o <= max_data_i;
      end
      if (m_valid_i) m_data_o <= m_data_i;
      if (pv_mac_valid_w || sum_valid_i) begin
        sum_data_o <= $unsigned(shared_add_result_w[SUM_W-1:0]);
        sum_tag_o <= sum_tag_i;
      end
    end
  end

endmodule
