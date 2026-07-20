`timescale 1ns/1ps
`include "attention_defines.vh"
`include "fixed_defs.vh"

// Fused FlashAttention core: output-stationary QK, PE-local max/sub/rowsum,
// column-streamed exp, probability-stationary WS-PV, and persistent O storage.
module fsa_fused_array #(
  parameter integer ROWS = `ATTN_ARRAY_ROWS,
  parameter integer STRIPE_ROWS = (ROWS < `ATTN_ARRAY_STRIPE_ROWS) ?
                                  ROWS : `ATTN_ARRAY_STRIPE_ROWS,
  parameter integer COLS = `ATTN_ARRAY_COLS,
  parameter integer DATA_W = `ATTN_ARRAY_DATA_W,
  parameter integer SCORE_W = `ATTN_ACC_W,
  parameter integer PROB_W = `ATTN_BETA_W,
  parameter integer ACC_W = `ATTN_ACC_W,
  parameter integer LSE_W = `ATTN_LSE_W,
  parameter integer HEAD_DIM = `ATTN_HEAD_DIM,
  parameter integer FEATURE_IDX_W = (HEAD_DIM < 2) ? 1 : $clog2(HEAD_DIM)
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
  output reg                         softmax_pv_ready_o,
  output reg                         softmax_done_o,
  output reg                         softmax_busy_o,

  input                              pv_start_i,
  output reg                         pv_ready_o,
  input                              pv_seed_zero_i,
  input                              pv_valid_i,
  input                              pv_last_i,
  input      [FEATURE_IDX_W-1:0]     pv_feature_i,
  input      [COLS*DATA_W-1:0]       pv_cols_i,
  output reg                         pv_done_o,

  input                              norm_rd_en_i,
  input      [((ROWS/STRIPE_ROWS < 2) ? 1 : $clog2(ROWS/STRIPE_ROWS))-1:0]
                                      norm_rd_stripe_i,
  input      [FEATURE_IDX_W-1:0]     norm_rd_feature_i,
  output reg                         norm_rd_valid_o,
  output reg [STRIPE_ROWS*ACC_W-1:0] norm_rd_acc_o,
  output reg [STRIPE_ROWS*LSE_W-1:0] norm_rd_l_o,
  output reg [((ROWS/STRIPE_ROWS < 2) ? 1 : $clog2(ROWS/STRIPE_ROWS))-1:0]
                                      norm_rd_stripe_o,
  output reg [FEATURE_IDX_W-1:0]     norm_rd_feature_o,
  output reg                         error_o
);

  localparam integer ROW_IDX_W = (ROWS < 2) ? 1 : $clog2(ROWS);
  localparam integer COL_IDX_W = (COLS < 2) ? 1 : $clog2(COLS);
  localparam integer LOCAL_ROW_IDX_W = (STRIPE_ROWS < 2) ? 1 : $clog2(STRIPE_ROWS);
  localparam integer NUM_STRIPES = ROWS / STRIPE_ROWS;
  localparam integer STRIPE_IDX_W = (NUM_STRIPES < 2) ? 1 : $clog2(NUM_STRIPES);
  localparam integer EXP_LANES = ROWS;
  localparam integer EXP_LATENCY = 7;
  localparam integer L_PRODUCT_W = LSE_W + PROB_W;
  localparam integer RESCALE_W = ACC_W + PROB_W;
  localparam [ROW_IDX_W-1:0] ROW_LAST = ROWS - 1;
  localparam [COL_IDX_W-1:0] COL_LAST = COLS - 1;
  localparam [FEATURE_IDX_W-1:0] FEATURE_LAST = HEAD_DIM - 1;

  // Online-softmax control overlaps the reverse delta wave, column exp, rowsum,
  // serialized l update, and the start of WS-PV.
  localparam SM_IDLE = 4'd0;
  localparam SM_MAX_WAIT = 4'd1;
  localparam SM_ALPHA_LAUNCH = 4'd2;
  localparam SM_ALPHA_WAIT = 4'd3;
  localparam SM_M_START = 4'd4;
  localparam SM_M_STREAM = 4'd5;
  localparam SM_SUM_WAIT = 4'd6;
  localparam SM_L_UPDATE = 4'd7;
  localparam SM_DONE = 4'd8;

  reg [3:0] softmax_state_q;
  reg mac_phase_pv_q;
  reg [ROW_IDX_W-1:0] lse_update_row_q;
  reg [ROWS-1:0] sum_launch_rows_q;
  reg [COL_IDX_W-1:0] prob_col_tag_q [0:EXP_LATENCY-1];
  reg [EXP_LATENCY-1:0] prob_col_tag_valid_q;

  reg [ROWS*SCORE_W-1:0] m_rows_q;
  reg [ROWS*SCORE_W-1:0] m_pending_q;
  reg [ROWS*SCORE_W-1:0] alpha_delta_q;
  reg [ROWS*SCORE_W-1:0] block_max_rows_q;
  reg [ROWS*LSE_W-1:0] l_rows_q;
  reg [ROWS*LSE_W-1:0] old_l_q;
  reg [ROWS*LSE_W-1:0] sum_rows_q;
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
  reg [ROWS*COLS-1:0] lane_valid_q;
  reg [ROWS*COLS-1:0] lane_valid_next_w;
  wire [ROWS-1:0] row_has_valid_w;
  wire [ROWS*SCORE_W-1:0] max_right_data_w;
  wire [ROWS-1:0] max_right_valid_w;
  wire [ROWS*LSE_W-1:0] sum_right_data_w;
  wire [ROWS-1:0] sum_right_valid_w;
  wire [ROWS*FEATURE_IDX_W-1:0] sum_right_tag_w;
  wire [ROWS*ACC_W-1:0] pv_seed_source_w;
  wire [ROWS*(ACC_W+FEATURE_IDX_W)-1:0] pv_seed_boundary_packed_w;
  wire [ROWS*ACC_W-1:0] pv_seed_boundary_data_w;
  wire [ROWS*FEATURE_IDX_W-1:0] pv_seed_boundary_tag_w;
  wire [ROWS-1:0] pv_seed_boundary_valid_w;
  wire [ROWS-1:0] pv_seed_boundary_last_w;

  wire [COLS*DATA_W-1:0] stripe_k_data_w [0:NUM_STRIPES];
  wire [COLS-1:0] stripe_k_valid_w [0:NUM_STRIPES];
  wire [COLS-1:0] stripe_k_last_w [0:NUM_STRIPES];
  wire [STRIPE_ROWS-1:0] stripe_q_tail_valid_w [0:NUM_STRIPES-1];
  wire [STRIPE_ROWS-1:0] stripe_q_tail_last_w [0:NUM_STRIPES-1];
  wire [NUM_STRIPES-1:0] stripe_tail_mac_last_w;
  wire [NUM_STRIPES-1:0] stripe_delta_col_valid_w;
  wire [COL_IDX_W-1:0] stripe_delta_col_index_w [0:NUM_STRIPES-1];
  wire [STRIPE_ROWS*SCORE_W-1:0] stripe_delta_col_data_w [0:NUM_STRIPES-1];
  wire [NUM_STRIPES-1:0] stripe_o_rd_valid_w;
  wire [STRIPE_ROWS*ACC_W-1:0] stripe_o_rd_data_w [0:NUM_STRIPES-1];
  wire [NUM_STRIPES-1:0] stripe_o_rd_en_w;
  wire [FEATURE_IDX_W-1:0] stripe_o_rd_feature_w [0:NUM_STRIPES-1];

  wire [ROWS*SCORE_W-1:0] delta_col_data_w;
  wire delta_col_valid_w;
  wire [COL_IDX_W-1:0] delta_col_index_w;

  wire [EXP_LANES*SCORE_W-1:0] exp_source_data_w;
  wire exp_source_valid_w;
  wire [EXP_LANES*16-1:0] scaled_exp_data_w;
  wire [EXP_LANES-1:0] scaled_exp_valid_w;
  wire [EXP_LANES*PROB_W-1:0] exp_data_w;
  wire [EXP_LANES-1:0] exp_valid_w;
  wire all_exp_valid_w;
  wire prob_write_valid_w;
  wire [COL_IDX_W-1:0] prob_write_col_w;

  wire qk_tail_last_w;
  wire pipeline_clear_w;
  wire source_is_pv_w;
  wire source_valid_w;
  wire source_last_w;
  wire [COLS*DATA_W-1:0] source_cols_w;
  wire seed_read_request_w;
  wire [ROWS*ACC_W-1:0] o_seed_rows_w;
  wire signed [2*RESCALE_W-1:0] pv_rescale_product_w [0:ROWS-1];
  wire signed [2*RESCALE_W-1:0] pv_rescale_shifted_w [0:ROWS-1];
  wire [NUM_STRIPES*STRIPE_ROWS*ACC_W-1:0] stripe_o_rd_flat_w;

  integer row_idx;
  integer tag_stage;
  integer consistency_stripe;
  integer mask_row;
  integer mask_col;
  integer query_index_w;
  integer valid_col_count_w;
  integer causal_col_count_w;
  integer seq_kv_int_w;
  integer seq_q_int_w;
  integer k_base_int_w;
  reg signed [SCORE_W-1:0] old_m_w;
  reg signed [SCORE_W-1:0] block_max_w;
  reg signed [SCORE_W-1:0] next_m_w;
  reg [L_PRODUCT_W-1:0] l_product_w;
  reg [L_PRODUCT_W:0] l_total_w;
  reg pv_issue_valid_q;
  reg pv_issue_last_q;
  reg pv_issue_seed_zero_q;
  reg [FEATURE_IDX_W-1:0] pv_issue_feature_q;
  reg [COLS*DATA_W-1:0] pv_issue_cols_q;
  reg norm_request_q;
  reg [STRIPE_IDX_W-1:0] norm_request_stripe_q;
  reg [FEATURE_IDX_W-1:0] norm_request_feature_q;

`ifndef SYNTHESIS
  initial begin
    if (ROWS != COLS) $fatal(1, "fsa_fused_array requires ROWS == COLS");
    if (ROWS % STRIPE_ROWS != 0) $fatal(1, "ROWS must be divisible by STRIPE_ROWS");
    if ((1 << LOCAL_ROW_IDX_W) != STRIPE_ROWS)
      $fatal(1, "STRIPE_ROWS must be a power of two");
  end

  always @(posedge clk) begin
    if (rst_n && (|stripe_delta_col_valid_w)) begin
      if (!(&stripe_delta_col_valid_w))
        $fatal(1, "fsa_fused_array stripe delta-column valid misalignment");
      for (consistency_stripe = 1; consistency_stripe < NUM_STRIPES;
           consistency_stripe = consistency_stripe + 1)
        if (stripe_delta_col_index_w[consistency_stripe] !=
            stripe_delta_col_index_w[0])
          $fatal(1, "fsa_fused_array stripe delta-column tag mismatch");
    end
  end
`endif

  // QK and WS-PV share the vertical K/V network. pv_issue_* is a registered copy
  // of one V[:,d] transfer and its full feature ID.
  assign pipeline_clear_w = clear_i || qk_clear_i || pv_start_i;
  assign source_is_pv_w = mac_phase_pv_q;
  assign source_valid_w = source_is_pv_w ? pv_issue_valid_q : qk_valid_i;
  assign source_last_w = source_is_pv_w ? pv_issue_last_q : qk_last_i;
  assign source_cols_w = source_is_pv_w ? pv_issue_cols_q : qk_cols_i;
  // For non-first KV tiles, the incoming V feature ID is simultaneously used as
  // the persistent O-bank read address. First-tile seeds bypass memory with zero.
  assign seed_read_request_w = pv_valid_i && !pv_seed_zero_i;
  assign delta_col_valid_w = &stripe_delta_col_valid_w;
  assign delta_col_index_w = stripe_delta_col_index_w[0];
  assign prob_write_col_w = prob_col_tag_q[EXP_LATENCY-1];

  // Precompute a registered per-row thermometer mask for padding and causality;
  // PE lanes only consume one mask bit at runtime.
  always @(*) begin
    lane_valid_next_w = {ROWS*COLS{1'b0}};
    seq_kv_int_w = {16'd0, seq_kv_i};
    seq_q_int_w = {16'd0, seq_q_i};
    k_base_int_w = {16'd0, k_base_i};
    for (mask_row = 0; mask_row < ROWS; mask_row = mask_row + 1) begin
      query_index_w = q_base_i + mask_row;
      if (seq_kv_int_w <= k_base_int_w)
        valid_col_count_w = 0;
      else if ((seq_kv_int_w - k_base_int_w) >= COLS)
        valid_col_count_w = COLS;
      else
        valid_col_count_w = seq_kv_int_w - k_base_int_w;
      if (causal_en_i) begin
        if (query_index_w < k_base_int_w)
          causal_col_count_w = 0;
        else if ((query_index_w - k_base_int_w + 1) >= COLS)
          causal_col_count_w = COLS;
        else
          causal_col_count_w = query_index_w - k_base_int_w + 1;
        if (causal_col_count_w < valid_col_count_w)
          valid_col_count_w = causal_col_count_w;
      end
      if (query_index_w >= seq_q_int_w)
        valid_col_count_w = 0;
      for (mask_col = 0; mask_col < COLS; mask_col = mask_col + 1)
        lane_valid_next_w[mask_row*COLS+mask_col] =
            mask_col < valid_col_count_w;
    end
  end

  // Row skew aligns Q with K during QK. The second delay line carries
  // {feature ID, alpha-rescaled O_old[row,d]} together, preserving alignment at
  // every WS-PV row boundary while V[:,d] follows the column-skew network.
  generate
    genvar skew_row;
    for (skew_row = 0; skew_row < ROWS; skew_row = skew_row + 1) begin : g_q_skew
      fsa_delay_line #(.WIDTH(DATA_W), .DEPTH(skew_row+1)) u_q_skew (
        .clk(clk), .rst_n(rst_n), .clear_i(pipeline_clear_w),
        .valid_i(qk_valid_i), .last_i(qk_last_i),
        .data_i(qk_rows_i[skew_row*DATA_W +: DATA_W]),
        .valid_o(q_boundary_valid_w[skew_row]),
        .last_o(q_boundary_last_w[skew_row]),
        .data_o(q_boundary_data_w[skew_row*DATA_W +: DATA_W])
      );

      fsa_delay_line #(.WIDTH(ACC_W+FEATURE_IDX_W), .DEPTH(skew_row+1))
      u_pv_seed_skew (
        .clk(clk), .rst_n(rst_n), .clear_i(pipeline_clear_w),
        .valid_i(pv_issue_valid_q), .last_i(pv_issue_last_q),
        .data_i({pv_issue_feature_q,
                 pv_seed_source_w[skew_row*ACC_W +: ACC_W]}),
        .valid_o(pv_seed_boundary_valid_w[skew_row]),
        .last_o(pv_seed_boundary_last_w[skew_row]),
        .data_o(pv_seed_boundary_packed_w[
            skew_row*(ACC_W+FEATURE_IDX_W) +: ACC_W+FEATURE_IDX_W])
      );
      assign pv_seed_boundary_data_w[skew_row*ACC_W +: ACC_W] =
          pv_seed_boundary_packed_w[
              skew_row*(ACC_W+FEATURE_IDX_W) +: ACC_W];
      assign pv_seed_boundary_tag_w[skew_row*FEATURE_IDX_W +: FEATURE_IDX_W] =
          pv_seed_boundary_packed_w[
              skew_row*(ACC_W+FEATURE_IDX_W)+ACC_W +: FEATURE_IDX_W];

      // Compute seed[row,d] = alpha[row] * O_old[row,d] in Q1.15. The synchronous
      // O read and the registered V/feature capture have matching one-cycle delay.
      assign pv_rescale_product_w[skew_row] =
          $signed({{PROB_W{o_seed_rows_w[skew_row*ACC_W+ACC_W-1]}},
                   o_seed_rows_w[skew_row*ACC_W +: ACC_W]}) *
          $signed({{ACC_W{1'b0}},
                   alpha_rows_q[skew_row*PROB_W +: PROB_W]});
      assign pv_rescale_shifted_w[skew_row] =
          pv_rescale_product_w[skew_row] >>> `ATTN_BETA_FRAC;
      assign pv_seed_source_w[skew_row*ACC_W +: ACC_W] =
          pv_issue_seed_zero_q ? {ACC_W{1'b0}} :
          pv_rescale_shifted_w[skew_row][ACC_W-1:0];
    end

    genvar skew_col;
    for (skew_col = 0; skew_col < COLS; skew_col = skew_col + 1) begin : g_k_skew
      fsa_delay_line #(.WIDTH(DATA_W), .DEPTH(skew_col+1)) u_k_skew (
        .clk(clk), .rst_n(rst_n), .clear_i(pipeline_clear_w),
        .valid_i(source_valid_w), .last_i(source_last_w),
        .data_i(source_cols_w[skew_col*DATA_W +: DATA_W]),
        .valid_o(k_boundary_valid_w[skew_col]),
        .last_o(k_boundary_last_w[skew_col]),
        .data_o(k_boundary_data_w[skew_col*DATA_W +: DATA_W])
      );
    end

    genvar valid_row;
    for (valid_row = 0; valid_row < ROWS; valid_row = valid_row + 1) begin : g_row_valid
      assign row_has_valid_w[valid_row] =
          |lane_valid_q[valid_row*COLS +: COLS];
    end

    assign stripe_k_data_w[0] = k_boundary_data_w;
    assign stripe_k_valid_w[0] = k_boundary_valid_w;
    assign stripe_k_last_w[0] = k_boundary_last_w;

    genvar stripe;
    for (stripe = 0; stripe < NUM_STRIPES; stripe = stripe + 1) begin : g_stripe
      localparam integer ROW_BASE = stripe * STRIPE_ROWS;
      assign delta_col_data_w[ROW_BASE*SCORE_W +: STRIPE_ROWS*SCORE_W] =
          stripe_delta_col_data_w[stripe];
      // Every stripe reads the same feature for a WS-PV seed; normalization reads
      // only its selected stripe. o_rd_feature_i is the complete feature address.
      assign stripe_o_rd_en_w[stripe] = seed_read_request_w ||
          (norm_rd_en_i && norm_rd_stripe_i == stripe);
      assign stripe_o_rd_feature_w[stripe] = seed_read_request_w ?
          pv_feature_i : norm_rd_feature_i;
      assign stripe_o_rd_flat_w[
          stripe*STRIPE_ROWS*ACC_W +: STRIPE_ROWS*ACC_W] =
          stripe_o_rd_data_w[stripe];
      assign o_seed_rows_w[ROW_BASE*ACC_W +: STRIPE_ROWS*ACC_W] =
          stripe_o_rd_data_w[stripe];

      fsa_stripe #(
        .STRIPE_ROWS(STRIPE_ROWS), .COLS(COLS), .DATA_W(DATA_W),
        .SCORE_W(SCORE_W), .PROB_W(PROB_W), .SUM_W(ACC_W),
        .HEAD_DIM(HEAD_DIM), .TAG_W(FEATURE_IDX_W),
        .LOCAL_ROW_IDX_W(LOCAL_ROW_IDX_W)
      ) u_stripe (
        .clk(clk), .rst_n(rst_n), .clear_i(clear_i),
        .clear_score_i(qk_clear_i), .ws_pv_i(source_is_pv_w),
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
        .lane_valid_i(lane_valid_q[ROW_BASE*COLS +: STRIPE_ROWS*COLS]),
        .max_done_valid_o(max_right_valid_w[ROW_BASE +: STRIPE_ROWS]),
        .max_done_data_o(max_right_data_w[ROW_BASE*SCORE_W +: STRIPE_ROWS*SCORE_W]),
        .m_start_valid_i({STRIPE_ROWS{softmax_state_q == SM_M_START}}),
        .m_start_data_i(m_pending_q[ROW_BASE*SCORE_W +: STRIPE_ROWS*SCORE_W]),
        .m_done_valid_o(),
        .sum_start_valid_i(sum_launch_rows_q[ROW_BASE +: STRIPE_ROWS]),
        .sum_done_valid_o(sum_right_valid_w[ROW_BASE +: STRIPE_ROWS]),
        .sum_done_data_o(sum_right_data_w[ROW_BASE*LSE_W +: STRIPE_ROWS*LSE_W]),
        .sum_done_tag_o(sum_right_tag_w[ROW_BASE*FEATURE_IDX_W +:
                                       STRIPE_ROWS*FEATURE_IDX_W]),
        .prob_col_load_valid_i(prob_write_valid_w),
        .prob_col_load_col_i(prob_write_col_w),
        .prob_col_load_data_i(
            exp_data_w[ROW_BASE*PROB_W +: STRIPE_ROWS*PROB_W]),
        .pv_sum_valid_i(pv_seed_boundary_valid_w[ROW_BASE +: STRIPE_ROWS]),
        .pv_sum_last_i(pv_seed_boundary_last_w[ROW_BASE +: STRIPE_ROWS]),
        .pv_sum_data_i(pv_seed_boundary_data_w[
            ROW_BASE*ACC_W +: STRIPE_ROWS*ACC_W]),
        .pv_sum_tag_i(pv_seed_boundary_tag_w[
            ROW_BASE*FEATURE_IDX_W +: STRIPE_ROWS*FEATURE_IDX_W]),
        .o_rd_en_i(stripe_o_rd_en_w[stripe]),
        .o_rd_feature_i(stripe_o_rd_feature_w[stripe]),
        .o_rd_valid_o(stripe_o_rd_valid_w[stripe]),
        .o_rd_data_o(stripe_o_rd_data_w[stripe]),
        .delta_col_valid_o(stripe_delta_col_valid_w[stripe]),
        .delta_col_index_o(stripe_delta_col_index_w[stripe]),
        .delta_col_data_o(stripe_delta_col_data_w[stripe]),
        .tail_mac_last_o(stripe_tail_mac_last_w[stripe])
      );
    end
  endgenerate

  assign qk_tail_last_w = stripe_tail_mac_last_w[NUM_STRIPES-1] && !source_is_pv_w;

  // Select the requested eight-row O/l slice for the final normalizer only.
  always @(*) begin
    norm_rd_acc_o = stripe_o_rd_flat_w[
        norm_request_stripe_q*STRIPE_ROWS*ACC_W +: STRIPE_ROWS*ACC_W];
    norm_rd_l_o = l_rows_q[
        norm_request_stripe_q*STRIPE_ROWS*LSE_W +: STRIPE_ROWS*LSE_W];
  end

  // One exp lane per row accepts a completed score column each cycle. The delayed
  // column tag returns probabilities to the exact PE column that produced delta.
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
          delta_col_data_w[exp_lane*SCORE_W +: SCORE_W];
    end
  endgenerate

  assign exp_source_valid_w = (softmax_state_q == SM_ALPHA_LAUNCH) ||
                              delta_col_valid_w;
  assign all_exp_valid_w = &exp_valid_w;
  assign prob_write_valid_w = all_exp_valid_w &&
                              prob_col_tag_valid_q[EXP_LATENCY-1];

  // FlashAttention recurrence: m_new=max(m_old, block_max) and
  // alpha=exp(m_old-m_new), with alpha=0 for an uninitialized row state.
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

  // Register all data/tag/valid paths. In particular pv_issue_cols_q,
  // pv_issue_feature_q, and the synchronous O-bank output advance together before
  // row/column skew, which is the RTL point that aligns O_old[:,d] with V[:,d].
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      softmax_state_q <= SM_IDLE;
      mac_phase_pv_q <= 1'b0;
      lse_update_row_q <= {ROW_IDX_W{1'b0}};
      sum_launch_rows_q <= {ROWS{1'b0}};
      prob_col_tag_valid_q <= {EXP_LATENCY{1'b0}};
      for (tag_stage = 0; tag_stage < EXP_LATENCY; tag_stage = tag_stage + 1)
        prob_col_tag_q[tag_stage] <= {COL_IDX_W{1'b0}};
      m_rows_q <= {ROWS*SCORE_W{1'b0}};
      block_max_rows_q <= {ROWS*SCORE_W{1'b0}};
      l_rows_q <= {ROWS*LSE_W{1'b0}};
      old_l_q <= {ROWS*LSE_W{1'b0}};
      sum_rows_q <= {ROWS*LSE_W{1'b0}};
      alpha_rows_q <= {ROWS*PROB_W{1'b0}};
      row_state_valid_q <= {ROWS{1'b0}};
      old_row_state_valid_q <= {ROWS{1'b0}};
      max_ready_rows_q <= {ROWS{1'b0}};
      qk_last_o <= 1'b0;
      softmax_pv_ready_o <= 1'b0;
      softmax_done_o <= 1'b0;
      softmax_busy_o <= 1'b0;
      pv_ready_o <= 1'b0;
      pv_done_o <= 1'b0;
      lane_valid_q <= {ROWS*COLS{1'b0}};
      pv_issue_valid_q <= 1'b0;
      pv_issue_last_q <= 1'b0;
      pv_issue_seed_zero_q <= 1'b0;
      pv_issue_feature_q <= {FEATURE_IDX_W{1'b0}};
      pv_issue_cols_q <= {COLS*DATA_W{1'b0}};
      norm_request_q <= 1'b0;
      norm_request_stripe_q <= {STRIPE_IDX_W{1'b0}};
      norm_request_feature_q <= {FEATURE_IDX_W{1'b0}};
      norm_rd_valid_o <= 1'b0;
      norm_rd_stripe_o <= {STRIPE_IDX_W{1'b0}};
      norm_rd_feature_o <= {FEATURE_IDX_W{1'b0}};
      error_o <= 1'b0;
      row_state_rd_valid_o <= 1'b0;
      row_state_alpha_o <= {PROB_W{1'b0}};
      row_state_l_o <= {LSE_W{1'b0}};
    end else if (clear_i) begin
      softmax_state_q <= SM_IDLE;
      mac_phase_pv_q <= 1'b0;
      row_state_valid_q <= {ROWS{1'b0}};
      max_ready_rows_q <= {ROWS{1'b0}};
      qk_last_o <= 1'b0;
      softmax_pv_ready_o <= 1'b0;
      softmax_done_o <= 1'b0;
      softmax_busy_o <= 1'b0;
      pv_ready_o <= 1'b0;
      pv_done_o <= 1'b0;
      pv_issue_valid_q <= 1'b0;
      norm_request_q <= 1'b0;
      norm_rd_valid_o <= 1'b0;
      sum_launch_rows_q <= {ROWS{1'b0}};
      prob_col_tag_valid_q <= {EXP_LATENCY{1'b0}};
      sum_rows_q <= {ROWS*LSE_W{1'b0}};
      error_o <= 1'b0;
      row_state_rd_valid_o <= 1'b0;
    end else begin
      qk_last_o <= qk_tail_last_w;
      softmax_pv_ready_o <= 1'b0;
      softmax_done_o <= 1'b0;
      pv_ready_o <= pv_start_i;
      pv_done_o <= 1'b0;
      pv_issue_valid_q <= pv_valid_i;
      pv_issue_last_q <= pv_last_i;
      pv_issue_seed_zero_q <= pv_seed_zero_i;
      pv_issue_feature_q <= pv_feature_i;
      pv_issue_cols_q <= pv_cols_i;
      norm_request_q <= norm_rd_en_i;
      if (norm_rd_en_i) begin
        norm_request_stripe_q <= norm_rd_stripe_i;
        norm_request_feature_q <= norm_rd_feature_i;
      end
      norm_rd_valid_o <= norm_request_q &&
          stripe_o_rd_valid_w[norm_request_stripe_q];
      if (norm_request_q && stripe_o_rd_valid_w[norm_request_stripe_q]) begin
        norm_rd_stripe_o <= norm_request_stripe_q;
        norm_rd_feature_o <= norm_request_feature_q;
      end
      sum_launch_rows_q <= {ROWS{1'b0}};
      prob_col_tag_valid_q[0] <= delta_col_valid_w;
      if (delta_col_valid_w) prob_col_tag_q[0] <= delta_col_index_w;
      for (tag_stage = 1; tag_stage < EXP_LATENCY; tag_stage = tag_stage + 1) begin
        prob_col_tag_valid_q[tag_stage] <= prob_col_tag_valid_q[tag_stage-1];
        if (prob_col_tag_valid_q[tag_stage-1])
          prob_col_tag_q[tag_stage] <= prob_col_tag_q[tag_stage-1];
      end
      row_state_rd_valid_o <= row_state_rd_en_i;
      if (row_state_rd_en_i) begin
        row_state_alpha_o <= alpha_rows_q[row_state_rd_row_i*PROB_W +: PROB_W];
        row_state_l_o <= l_rows_q[row_state_rd_row_i*LSE_W +: LSE_W];
      end

      if (qk_clear_i) begin
        mac_phase_pv_q <= 1'b0;
        lane_valid_q <= lane_valid_next_w;
      end
      else if (pv_start_i) mac_phase_pv_q <= 1'b1;

      if (qk_clear_i) begin
        max_ready_rows_q <= {ROWS{1'b0}};
        sum_launch_rows_q <= {ROWS{1'b0}};
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

      if (prob_write_valid_w && prob_write_col_w == COL_LAST)
        sum_launch_rows_q <= {ROWS{1'b1}};

      // Rowmax completion launches alpha, then the reverse m_new wave drives the
      // overlapped delta -> exp -> probability -> rowsum column pipeline.
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
        SM_M_START: softmax_state_q <= SM_M_STREAM;
        SM_M_STREAM: begin
          if (prob_write_valid_w && prob_write_col_w == {COL_IDX_W{1'b0}})
            softmax_state_q <= SM_SUM_WAIT;
        end
        SM_SUM_WAIT: begin
          if (&sum_right_valid_w) begin
            sum_rows_q <= sum_right_data_w;
            lse_update_row_q <= {ROW_IDX_W{1'b0}};
            softmax_pv_ready_o <= 1'b1;
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

      if (sum_right_valid_w[ROWS-1] &&
          sum_right_tag_w[(ROWS-1)*FEATURE_IDX_W +: FEATURE_IDX_W] ==
          FEATURE_LAST)
        pv_done_o <= 1'b1;
    end
  end

  // A single row-state multiplier updates l_new=alpha*l_old+rowsum(P) one row per
  // cycle; WS-PV is allowed to overlap this serialized state update.
  always @(*) begin
    l_product_w =
        {{PROB_W{1'b0}}, old_l_q[lse_update_row_q*LSE_W +: LSE_W]} *
        alpha_rows_q[lse_update_row_q*PROB_W +: PROB_W];
    l_total_w = {1'b0, (l_product_w >> `ATTN_BETA_FRAC)} +
                {{(L_PRODUCT_W+1-LSE_W){1'b0}},
                 sum_rows_q[lse_update_row_q*LSE_W +: LSE_W]};
  end

endmodule
