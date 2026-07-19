`timescale 1ns/1ps
`include "attention_defines.vh"
`include "fixed_defs.vh"

module os_fsa_fused_array #(
  parameter integer ROWS = `ATTN_ARRAY_ROWS,
  parameter integer STRIPE_ROWS = (ROWS < `ATTN_ARRAY_STRIPE_ROWS) ?
                                  ROWS : `ATTN_ARRAY_STRIPE_ROWS,
  parameter integer COLS = `ATTN_ARRAY_COLS,
  parameter integer DATA_W = `ATTN_ARRAY_DATA_W,
  parameter integer SCORE_W = `ATTN_ACC_W,
  parameter integer PROB_W = `ATTN_BETA_W,
  parameter integer ACC_W = `ATTN_ACC_W,
  parameter integer LSE_W = `ATTN_LSE_W
)(
  input                              clk,
  input                              rst_n,
  input                              clear_i,
  input                              clear_rows_i,

  input                              qk_clear_i,
  input                              qk_valid_i,
  input                              qk_last_i,
  input      [ROWS*DATA_W-1:0]       qk_rows_i,
  input      [COLS*DATA_W-1:0]       qk_cols_i,
  output reg                         qk_last_o,

  input                              softmax_start_i,
  input      [31:0]                  score_scale_i,
  input      [15:0]                  q_base_i,
  input      [15:0]                  k_base_i,
  input      [15:0]                  seq_q_i,
  input      [15:0]                  seq_kv_i,
  input                              causal_en_i,
  input                              row_state_rd_en_i,
  input      [((ROWS < 2) ? 1 : $clog2(ROWS))-1:0] row_state_rd_row_i,
  output reg                         row_state_rd_valid_o,
  output reg [PROB_W-1:0]            row_state_alpha_o,
  output reg [LSE_W-1:0]             row_state_l_o,
  output reg                         softmax_done_o,
  output reg                         softmax_busy_o,

  input                              pv_start_i,
  output reg                         pv_ready_o,
  input                              pv_clear_acc_i,
  input                              pv_load_row_valid_i,
  input      [((ROWS < 2) ? 1 : $clog2(ROWS))-1:0] pv_load_row_index_i,
  input      [COLS*ACC_W-1:0]        pv_load_row_data_i,
  input                              pv_valid_i,
  input                              pv_last_i,
  input      [COLS*DATA_W-1:0]       pv_cols_i,
  output reg                         pv_done_o,

  output reg                         row_valid_o,
  input                              row_ready_i,
  output reg [((ROWS < 2) ? 1 : $clog2(ROWS))-1:0] row_index_o,
  output reg [COLS*ACC_W-1:0]        row_data_o,
  output reg                         error_o
);

  localparam integer ROW_IDX_W = (ROWS < 2) ? 1 : $clog2(ROWS);
  localparam integer LOCAL_ROW_IDX_W = (STRIPE_ROWS < 2) ? 1 : $clog2(STRIPE_ROWS);
  localparam integer NUM_STRIPES = ROWS / STRIPE_ROWS;
  localparam integer EXP_LANES = COLS;
  localparam integer L_PRODUCT_W = LSE_W + PROB_W;
  localparam [ROW_IDX_W-1:0] ROW_LAST = ROWS - 1;

  localparam SM_IDLE = 4'd0;
  localparam SM_MAX_WAIT = 4'd1;
  localparam SM_ALPHA_LAUNCH = 4'd2;
  localparam SM_ALPHA_WAIT = 4'd3;
  localparam SM_M_START = 4'd4;
  localparam SM_M_WAIT = 4'd5;
  localparam SM_PROB_ISSUE = 4'd6;
  localparam SM_PROB_DRAIN = 4'd7;
  localparam SM_SUM_START = 4'd8;
  localparam SM_SUM_WAIT = 4'd9;
  localparam SM_L_UPDATE = 4'd10;
  localparam SM_DONE = 4'd11;

  reg [3:0] softmax_state_q;
  reg mac_phase_pv_q;
  reg [ROW_IDX_W-1:0] prob_issue_row_q;
  reg [ROW_IDX_W-1:0] prob_receive_row_q;
  reg [ROW_IDX_W-1:0] lse_update_row_q;
  reg stream_active_q;
  reg stream_read_pending_q;

  reg [ROWS*SCORE_W-1:0] m_rows_q;
  reg [ROWS*SCORE_W-1:0] m_pending_q;
  reg [ROWS*SCORE_W-1:0] alpha_delta_q;
  reg [ROWS*SCORE_W-1:0] block_max_rows_q;
  reg [ROWS*LSE_W-1:0] l_rows_q;
  reg [ROWS*LSE_W-1:0] old_l_q;
  reg [ROWS*PROB_W-1:0] alpha_rows_q;
  reg [ROWS-1:0] row_state_valid_q;
  reg [ROWS-1:0] old_row_state_valid_q;
  reg [ROWS-1:0] max_ready_rows_q;

  wire [ROWS*DATA_W-1:0] q_boundary_data_w;
  wire [ROWS-1:0] q_boundary_valid_w;
  wire [ROWS-1:0] q_boundary_last_w;
  wire [COLS*DATA_W-1:0] k_boundary_data_w;
  wire [COLS-1:0] k_boundary_valid_w;
  wire [COLS-1:0] k_boundary_last_w;
  wire [ROWS*COLS-1:0] lane_valid_w;
  wire [ROWS-1:0] row_has_valid_w;
  wire [16:0] query_index_w [0:ROWS-1];
  wire [16:0] key_index_w [0:COLS-1];
  wire [ROWS-1:0] query_in_range_w;
  wire [COLS-1:0] key_in_range_w;
  wire [ROWS*SCORE_W-1:0] max_right_data_w;
  wire [ROWS-1:0] max_right_valid_w;
  wire [ROWS-1:0] m_left_valid_w;
  wire [ROWS*LSE_W-1:0] sum_right_data_w;
  wire [ROWS-1:0] sum_right_valid_w;
  wire [ROWS*PROB_W-1:0] prob_left_rows_w;

  wire [COLS*DATA_W-1:0] stripe_k_data_w [0:NUM_STRIPES];
  wire [COLS-1:0] stripe_k_valid_w [0:NUM_STRIPES];
  wire [COLS-1:0] stripe_k_last_w [0:NUM_STRIPES];
  wire [STRIPE_ROWS-1:0] stripe_q_tail_valid_w [0:NUM_STRIPES-1];
  wire [STRIPE_ROWS-1:0] stripe_q_tail_last_w [0:NUM_STRIPES-1];
  wire [NUM_STRIPES-1:0] stripe_tail_mac_last_w;
  wire [NUM_STRIPES-1:0] stripe_delta_valid_w;
  wire [COLS*SCORE_W-1:0] stripe_delta_data_w [0:NUM_STRIPES-1];
  wire [NUM_STRIPES-1:0] stripe_acc_valid_w;
  wire [COLS*ACC_W-1:0] stripe_acc_data_w [0:NUM_STRIPES-1];

  reg [COLS*SCORE_W-1:0] delta_response_data_w;
  reg [COLS*ACC_W-1:0] acc_response_data_w;
  wire delta_response_valid_w;
  wire acc_response_valid_w;

  wire [EXP_LANES*SCORE_W-1:0] exp_source_data_w;
  wire exp_source_valid_w;
  wire [EXP_LANES*16-1:0] scaled_exp_data_w;
  wire [EXP_LANES-1:0] scaled_exp_valid_w;
  wire [EXP_LANES*PROB_W-1:0] exp_data_w;
  wire [EXP_LANES-1:0] exp_valid_w;
  wire all_exp_valid_w;
  wire prob_write_valid_w;

  wire qk_tail_last_w;
  wire pv_tail_last_w;
  wire pipeline_clear_w;
  wire source_is_pv_w;
  wire source_valid_w;
  wire source_last_w;
  wire [ROWS*DATA_W-1:0] source_rows_w;
  wire [COLS*DATA_W-1:0] source_cols_w;
  wire acc_read_request_w;

  integer row_idx;
  integer stripe_idx;
  reg signed [SCORE_W-1:0] old_m_w;
  reg signed [SCORE_W-1:0] block_max_w;
  reg signed [SCORE_W-1:0] next_m_w;
  reg [L_PRODUCT_W-1:0] l_product_w;
  reg [L_PRODUCT_W:0] l_total_w;

`ifndef SYNTHESIS
  initial begin
    if (ROWS != COLS) $fatal(1, "os_fsa_fused_array requires ROWS == COLS");
    if (ROWS % STRIPE_ROWS != 0) $fatal(1, "ROWS must be divisible by STRIPE_ROWS");
    if ((1 << LOCAL_ROW_IDX_W) != STRIPE_ROWS)
      $fatal(1, "STRIPE_ROWS must be a power of two");
  end
`endif

  assign pipeline_clear_w = clear_i || qk_clear_i || pv_start_i;
  assign source_is_pv_w = mac_phase_pv_q;
  assign source_valid_w = qk_valid_i || pv_valid_i;
  assign source_last_w = source_is_pv_w ? pv_last_i : qk_last_i;
  assign source_cols_w = source_is_pv_w ? pv_cols_i : qk_cols_i;
  assign delta_response_valid_w = |stripe_delta_valid_w;
  assign acc_response_valid_w = |stripe_acc_valid_w;
  assign acc_read_request_w = stream_active_q && !row_valid_o && !stream_read_pending_q;

  generate
    genvar source_row;
    for (source_row = 0; source_row < ROWS; source_row = source_row + 1) begin : g_source_row
      assign source_rows_w[source_row*DATA_W +: DATA_W] = source_is_pv_w ?
          {{(DATA_W-PROB_W){1'b0}}, prob_left_rows_w[source_row*PROB_W +: PROB_W]} :
          qk_rows_i[source_row*DATA_W +: DATA_W];
    end

    genvar skew_row;
    for (skew_row = 0; skew_row < ROWS; skew_row = skew_row + 1) begin : g_q_skew
      os_fsa_delay_line #(.WIDTH(DATA_W), .DEPTH(skew_row+1)) u_q_skew (
        .clk(clk), .rst_n(rst_n), .clear_i(pipeline_clear_w),
        .valid_i(source_valid_w), .last_i(source_last_w),
        .data_i(source_rows_w[skew_row*DATA_W +: DATA_W]),
        .valid_o(q_boundary_valid_w[skew_row]),
        .last_o(q_boundary_last_w[skew_row]),
        .data_o(q_boundary_data_w[skew_row*DATA_W +: DATA_W])
      );
    end

    genvar skew_col;
    for (skew_col = 0; skew_col < COLS; skew_col = skew_col + 1) begin : g_k_skew
      os_fsa_delay_line #(.WIDTH(DATA_W), .DEPTH(skew_col+1)) u_k_skew (
        .clk(clk), .rst_n(rst_n), .clear_i(pipeline_clear_w),
        .valid_i(source_valid_w), .last_i(source_last_w),
        .data_i(source_cols_w[skew_col*DATA_W +: DATA_W]),
        .valid_o(k_boundary_valid_w[skew_col]),
        .last_o(k_boundary_last_w[skew_col]),
        .data_o(k_boundary_data_w[skew_col*DATA_W +: DATA_W])
      );
    end

    genvar mask_row;
    genvar mask_col;
    for (mask_row = 0; mask_row < ROWS; mask_row = mask_row + 1) begin : g_mask_row
      localparam [15:0] ROW_OFFSET = mask_row;
      assign query_index_w[mask_row] = {1'b0, q_base_i} + ROW_OFFSET;
      assign query_in_range_w[mask_row] = query_index_w[mask_row] < {1'b0, seq_q_i};
      assign row_has_valid_w[mask_row] = |lane_valid_w[mask_row*COLS +: COLS];
      for (mask_col = 0; mask_col < COLS; mask_col = mask_col + 1) begin : g_mask_col
        assign lane_valid_w[mask_row*COLS+mask_col] =
            query_in_range_w[mask_row] && key_in_range_w[mask_col] &&
            (!causal_en_i || key_index_w[mask_col] <= query_index_w[mask_row]);
      end
    end

    for (mask_col = 0; mask_col < COLS; mask_col = mask_col + 1) begin : g_mask_col_base
      localparam [15:0] COL_OFFSET = mask_col;
      assign key_index_w[mask_col] = {1'b0, k_base_i} + COL_OFFSET;
      assign key_in_range_w[mask_col] = key_index_w[mask_col] < {1'b0, seq_kv_i};
    end

    assign stripe_k_data_w[0] = k_boundary_data_w;
    assign stripe_k_valid_w[0] = k_boundary_valid_w;
    assign stripe_k_last_w[0] = k_boundary_last_w;

    genvar stripe;
    for (stripe = 0; stripe < NUM_STRIPES; stripe = stripe + 1) begin : g_stripe
      localparam integer ROW_BASE = stripe * STRIPE_ROWS;
      wire stripe_prob_load_w = prob_write_valid_w &&
          ((prob_receive_row_q >> LOCAL_ROW_IDX_W) == stripe);
      wire stripe_acc_load_w = pv_load_row_valid_i &&
          ((pv_load_row_index_i >> LOCAL_ROW_IDX_W) == stripe);
      wire stripe_delta_req_w = (softmax_state_q == SM_PROB_ISSUE) &&
          ((prob_issue_row_q >> LOCAL_ROW_IDX_W) == stripe);
      wire stripe_acc_req_w = acc_read_request_w &&
          ((row_index_o >> LOCAL_ROW_IDX_W) == stripe);

      os_fsa_stripe #(
        .STRIPE_ROWS(STRIPE_ROWS), .COLS(COLS), .DATA_W(DATA_W),
        .SCORE_W(SCORE_W), .PROB_W(PROB_W), .ACC_W(ACC_W), .SUM_W(LSE_W),
        .LOCAL_ROW_IDX_W(LOCAL_ROW_IDX_W)
      ) u_stripe (
        .clk(clk), .rst_n(rst_n), .clear_i(clear_i),
        .clear_score_i(qk_clear_i), .clear_acc_i(pv_clear_acc_i),
        .mac_is_pv_i(source_is_pv_w),
        .q_rows_i(q_boundary_data_w[ROW_BASE*DATA_W +: STRIPE_ROWS*DATA_W]),
        .q_valid_i(q_boundary_valid_w[ROW_BASE +: STRIPE_ROWS]),
        .q_last_i(q_boundary_last_w[ROW_BASE +: STRIPE_ROWS]),
        .q_tail_valid_o(stripe_q_tail_valid_w[stripe]),
        .q_tail_last_o(stripe_q_tail_last_w[stripe]),
        .k_top_data_i(stripe_k_data_w[stripe]),
        .k_top_valid_i(stripe_k_valid_w[stripe]),
        .k_top_last_i(stripe_k_last_w[stripe]),
        .k_bottom_data_o(stripe_k_data_w[stripe+1]),
        .k_bottom_valid_o(stripe_k_valid_w[stripe+1]),
        .k_bottom_last_o(stripe_k_last_w[stripe+1]),
        .lane_valid_i(lane_valid_w[ROW_BASE*COLS +: STRIPE_ROWS*COLS]),
        .max_done_valid_o(max_right_valid_w[ROW_BASE +: STRIPE_ROWS]),
        .max_done_data_o(max_right_data_w[ROW_BASE*SCORE_W +: STRIPE_ROWS*SCORE_W]),
        .m_start_valid_i({STRIPE_ROWS{softmax_state_q == SM_M_START}}),
        .m_start_data_i(m_pending_q[ROW_BASE*SCORE_W +: STRIPE_ROWS*SCORE_W]),
        .m_done_valid_o(m_left_valid_w[ROW_BASE +: STRIPE_ROWS]),
        .sum_start_valid_i({STRIPE_ROWS{softmax_state_q == SM_SUM_START}}),
        .sum_done_valid_o(sum_right_valid_w[ROW_BASE +: STRIPE_ROWS]),
        .sum_done_data_o(sum_right_data_w[ROW_BASE*LSE_W +: STRIPE_ROWS*LSE_W]),
        .prob_load_valid_i(stripe_prob_load_w),
        .prob_load_row_i(prob_receive_row_q[LOCAL_ROW_IDX_W-1:0]),
        .prob_load_data_i(exp_data_w),
        .prob_shift_load_i(pv_start_i), .prob_shift_en_i(pv_valid_i),
        .prob_left_rows_o(prob_left_rows_w[ROW_BASE*PROB_W +: STRIPE_ROWS*PROB_W]),
        .acc_load_valid_i(stripe_acc_load_w),
        .acc_load_row_i(pv_load_row_index_i[LOCAL_ROW_IDX_W-1:0]),
        .acc_load_data_i(pv_load_row_data_i),
        .delta_read_req_i(stripe_delta_req_w),
        .delta_read_row_i(prob_issue_row_q[LOCAL_ROW_IDX_W-1:0]),
        .delta_read_valid_o(stripe_delta_valid_w[stripe]),
        .delta_read_data_o(stripe_delta_data_w[stripe]),
        .acc_read_req_i(stripe_acc_req_w),
        .acc_read_row_i(row_index_o[LOCAL_ROW_IDX_W-1:0]),
        .acc_read_valid_o(stripe_acc_valid_w[stripe]),
        .acc_read_data_o(stripe_acc_data_w[stripe]),
        .tail_mac_last_o(stripe_tail_mac_last_w[stripe])
      );
    end
  endgenerate

  assign qk_tail_last_w = stripe_tail_mac_last_w[NUM_STRIPES-1] && !source_is_pv_w;
  assign pv_tail_last_w = stripe_tail_mac_last_w[NUM_STRIPES-1] && source_is_pv_w;

  always @(*) begin
    delta_response_data_w = {COLS*SCORE_W{1'b0}};
    acc_response_data_w = {COLS*ACC_W{1'b0}};
    for (stripe_idx = 0; stripe_idx < NUM_STRIPES; stripe_idx = stripe_idx + 1) begin
      if (stripe_delta_valid_w[stripe_idx])
        delta_response_data_w = delta_response_data_w | stripe_delta_data_w[stripe_idx];
      if (stripe_acc_valid_w[stripe_idx])
        acc_response_data_w = acc_response_data_w | stripe_acc_data_w[stripe_idx];
    end
  end

  generate
    genvar exp_lane;
    for (exp_lane = 0; exp_lane < EXP_LANES; exp_lane = exp_lane + 1) begin : g_exp_lane
      scale_requant_unit #(.IN_W(SCORE_W), .SCALE_W(16), .OUT_W(16)) u_scale (
        .clk(clk), .rst_n(rst_n), .valid_i(exp_source_valid_w),
        .data_i(exp_source_data_w[exp_lane*SCORE_W +: SCORE_W]),
        .scale_mant_i(score_scale_i[15:0]), .shift_i(score_scale_i[21:16]),
        .zero_point_i(16'sd0), .round_mode_i(`ATTN_ROUND_NEAREST),
        .sat_mode_i(`ATTN_SAT_INT16),
        .valid_o(scaled_exp_valid_w[exp_lane]),
        .data_o(scaled_exp_data_w[exp_lane*16 +: 16])
      );
      pwl_exp_unit u_exp (
        .clk(clk), .rst_n(rst_n), .valid_i(scaled_exp_valid_w[exp_lane]),
        .x_i(scaled_exp_data_w[exp_lane*16 +: 16]),
        .valid_o(exp_valid_w[exp_lane]),
        .y_o(exp_data_w[exp_lane*PROB_W +: PROB_W])
      );
      assign exp_source_data_w[exp_lane*SCORE_W +: SCORE_W] =
          (softmax_state_q == SM_ALPHA_LAUNCH) ?
          alpha_delta_q[exp_lane*SCORE_W +: SCORE_W] :
          delta_response_data_w[exp_lane*SCORE_W +: SCORE_W];
    end
  endgenerate

  assign exp_source_valid_w = (softmax_state_q == SM_ALPHA_LAUNCH) ||
                              delta_response_valid_w;
  assign all_exp_valid_w = &exp_valid_w;
  assign prob_write_valid_w = all_exp_valid_w &&
                              (softmax_state_q == SM_PROB_ISSUE ||
                               softmax_state_q == SM_PROB_DRAIN);

  always @(*) begin
    for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
      old_m_w = m_rows_q[row_idx*SCORE_W +: SCORE_W];
      block_max_w = block_max_rows_q[row_idx*SCORE_W +: SCORE_W];
      if (row_state_valid_q[row_idx] && $signed(old_m_w) >= $signed(block_max_w))
        next_m_w = old_m_w;
      else
        next_m_w = block_max_w;
      m_pending_q[row_idx*SCORE_W +: SCORE_W] = next_m_w;
      if (row_state_valid_q[row_idx])
        alpha_delta_q[row_idx*SCORE_W +: SCORE_W] = $signed(old_m_w) - $signed(next_m_w);
      else
        alpha_delta_q[row_idx*SCORE_W +: SCORE_W] = {SCORE_W{1'b0}};
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      softmax_state_q <= SM_IDLE;
      mac_phase_pv_q <= 1'b0;
      prob_issue_row_q <= {ROW_IDX_W{1'b0}};
      prob_receive_row_q <= {ROW_IDX_W{1'b0}};
      lse_update_row_q <= {ROW_IDX_W{1'b0}};
      stream_active_q <= 1'b0;
      stream_read_pending_q <= 1'b0;
      m_rows_q <= {ROWS*SCORE_W{1'b0}};
      block_max_rows_q <= {ROWS*SCORE_W{1'b0}};
      l_rows_q <= {ROWS*LSE_W{1'b0}};
      old_l_q <= {ROWS*LSE_W{1'b0}};
      alpha_rows_q <= {ROWS*PROB_W{1'b0}};
      row_state_valid_q <= {ROWS{1'b0}};
      old_row_state_valid_q <= {ROWS{1'b0}};
      max_ready_rows_q <= {ROWS{1'b0}};
      qk_last_o <= 1'b0;
      softmax_done_o <= 1'b0;
      softmax_busy_o <= 1'b0;
      pv_ready_o <= 1'b0;
      pv_done_o <= 1'b0;
      row_valid_o <= 1'b0;
      row_index_o <= {ROW_IDX_W{1'b0}};
      row_data_o <= {COLS*ACC_W{1'b0}};
      error_o <= 1'b0;
      row_state_rd_valid_o <= 1'b0;
      row_state_alpha_o <= {PROB_W{1'b0}};
      row_state_l_o <= {LSE_W{1'b0}};
    end else if (clear_i) begin
      softmax_state_q <= SM_IDLE;
      mac_phase_pv_q <= 1'b0;
      stream_active_q <= 1'b0;
      stream_read_pending_q <= 1'b0;
      row_state_valid_q <= {ROWS{1'b0}};
      max_ready_rows_q <= {ROWS{1'b0}};
      qk_last_o <= 1'b0;
      softmax_done_o <= 1'b0;
      softmax_busy_o <= 1'b0;
      pv_ready_o <= 1'b0;
      pv_done_o <= 1'b0;
      row_valid_o <= 1'b0;
      error_o <= 1'b0;
      row_state_rd_valid_o <= 1'b0;
    end else begin
      qk_last_o <= qk_tail_last_w;
      softmax_done_o <= 1'b0;
      pv_ready_o <= pv_start_i;
      pv_done_o <= 1'b0;
      row_state_rd_valid_o <= row_state_rd_en_i;
      if (row_state_rd_en_i) begin
        row_state_alpha_o <= alpha_rows_q[row_state_rd_row_i*PROB_W +: PROB_W];
        row_state_l_o <= l_rows_q[row_state_rd_row_i*LSE_W +: LSE_W];
      end

      if (qk_clear_i) mac_phase_pv_q <= 1'b0;
      else if (pv_start_i) mac_phase_pv_q <= 1'b1;

      if (qk_clear_i) begin
        max_ready_rows_q <= {ROWS{1'b0}};
      end else if (!mac_phase_pv_q) begin
        for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
          if (max_right_valid_w[row_idx]) begin
            block_max_rows_q[row_idx*SCORE_W +: SCORE_W] <=
                max_right_data_w[row_idx*SCORE_W +: SCORE_W];
            max_ready_rows_q[row_idx] <= 1'b1;
          end
        end
      end

      if (clear_rows_i) begin
        if (softmax_busy_o) error_o <= 1'b1;
        m_rows_q <= {ROWS*SCORE_W{1'b0}};
        l_rows_q <= {ROWS*LSE_W{1'b0}};
        alpha_rows_q <= {ROWS*PROB_W{1'b0}};
        row_state_valid_q <= {ROWS{1'b0}};
      end

      if (softmax_start_i && softmax_state_q != SM_IDLE)
        error_o <= 1'b1;

      case (softmax_state_q)
        SM_IDLE: begin
          softmax_busy_o <= 1'b0;
          if (softmax_start_i) begin
            softmax_busy_o <= 1'b1;
            old_l_q <= l_rows_q;
            old_row_state_valid_q <= row_state_valid_q;
            if (&max_ready_rows_q) softmax_state_q <= SM_ALPHA_LAUNCH;
            else softmax_state_q <= SM_MAX_WAIT;
          end
        end
        SM_MAX_WAIT: if (&max_ready_rows_q) softmax_state_q <= SM_ALPHA_LAUNCH;
        SM_ALPHA_LAUNCH: softmax_state_q <= SM_ALPHA_WAIT;
        SM_ALPHA_WAIT: begin
          if (all_exp_valid_w) begin
            m_rows_q <= m_pending_q;
            for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
              if (old_row_state_valid_q[row_idx])
                alpha_rows_q[row_idx*PROB_W +: PROB_W] <=
                    exp_data_w[row_idx*PROB_W +: PROB_W];
              else
                alpha_rows_q[row_idx*PROB_W +: PROB_W] <= {PROB_W{1'b0}};
            end
            softmax_state_q <= SM_M_START;
          end
        end
        SM_M_START: softmax_state_q <= SM_M_WAIT;
        SM_M_WAIT: begin
          if (&m_left_valid_w) begin
            prob_issue_row_q <= {ROW_IDX_W{1'b0}};
            prob_receive_row_q <= {ROW_IDX_W{1'b0}};
            softmax_state_q <= SM_PROB_ISSUE;
          end
        end
        SM_PROB_ISSUE: begin
          if (prob_issue_row_q == ROW_LAST)
            softmax_state_q <= SM_PROB_DRAIN;
          else
            prob_issue_row_q <= prob_issue_row_q + 1'b1;
          if (prob_write_valid_w) prob_receive_row_q <= prob_receive_row_q + 1'b1;
        end
        SM_PROB_DRAIN: begin
          if (prob_write_valid_w) begin
            if (prob_receive_row_q == ROW_LAST) softmax_state_q <= SM_SUM_START;
            else prob_receive_row_q <= prob_receive_row_q + 1'b1;
          end
        end
        SM_SUM_START: softmax_state_q <= SM_SUM_WAIT;
        SM_SUM_WAIT: begin
          if (&sum_right_valid_w) begin
            lse_update_row_q <= {ROW_IDX_W{1'b0}};
            softmax_state_q <= SM_L_UPDATE;
          end
        end
        SM_L_UPDATE: begin
          if (|l_total_w[L_PRODUCT_W:LSE_W])
            l_rows_q[lse_update_row_q*LSE_W +: LSE_W] <= {LSE_W{1'b1}};
          else
            l_rows_q[lse_update_row_q*LSE_W +: LSE_W] <= l_total_w[LSE_W-1:0];
          if (row_has_valid_w[lse_update_row_q])
            row_state_valid_q[lse_update_row_q] <= 1'b1;
          if (lse_update_row_q == ROW_LAST)
            softmax_state_q <= SM_DONE;
          else
            lse_update_row_q <= lse_update_row_q + 1'b1;
        end
        SM_DONE: begin
          softmax_done_o <= 1'b1;
          softmax_busy_o <= 1'b0;
          max_ready_rows_q <= {ROWS{1'b0}};
          softmax_state_q <= SM_IDLE;
        end
        default: begin
          error_o <= 1'b1;
          softmax_busy_o <= 1'b0;
          softmax_state_q <= SM_IDLE;
        end
      endcase

      if (pv_tail_last_w) begin
        stream_active_q <= 1'b1;
        stream_read_pending_q <= 1'b0;
        row_valid_o <= 1'b0;
        row_index_o <= {ROW_IDX_W{1'b0}};
      end else if (stream_active_q) begin
        if (acc_read_request_w) stream_read_pending_q <= 1'b1;
        if (acc_response_valid_w) begin
          row_data_o <= acc_response_data_w;
          row_valid_o <= 1'b1;
          stream_read_pending_q <= 1'b0;
        end
        if (row_valid_o && row_ready_i) begin
          row_valid_o <= 1'b0;
          if (row_index_o == ROW_LAST) begin
            stream_active_q <= 1'b0;
            pv_done_o <= 1'b1;
          end else begin
            row_index_o <= row_index_o + 1'b1;
          end
        end
      end else begin
        row_valid_o <= 1'b0;
      end
    end
  end

  always @(*) begin
    l_product_w =
        {{PROB_W{1'b0}}, old_l_q[lse_update_row_q*LSE_W +: LSE_W]} *
        alpha_rows_q[lse_update_row_q*PROB_W +: PROB_W];
    l_total_w = {1'b0, (l_product_w >> `ATTN_BETA_FRAC)} +
                {{(L_PRODUCT_W+1-LSE_W){1'b0}},
                 sum_right_data_w[lse_update_row_q*LSE_W +: LSE_W]};
  end

endmodule
