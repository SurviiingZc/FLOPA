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
  input                              clock_en_i,
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
  output reg                         softmax_pv_ready_o,
  output reg                         softmax_done_o,
  output reg                         softmax_busy_o,

  input                              pv_start_i,
  output reg                         pv_ready_o,
  input                              pv_seed_zero_i,
  input                              pv_valid_i,
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
  localparam integer EXP_LATENCY = `ATTN_SCORE_EXP_LATENCY;
  localparam integer L_PRODUCT_W = LSE_W + PROB_W;
  localparam integer QK_COMPLETION_DEPTH = ROWS + COLS;
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
  localparam SM_L_DRAIN = 4'd8;
  localparam SM_DONE = 4'd9;

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
  reg [ROWS*PROB_W-1:0] alpha_update_stream_q;
  reg [ROWS-1:0] lse_bypass_stream_q;
  reg [ROWS-1:0] row_state_valid_q;
  reg [ROWS-1:0] old_row_state_valid_q;
  reg [ROWS-1:0] max_ready_rows_q;

  wire [ROWS*DATA_W-1:0] q_boundary_data_w;
  wire [ROWS-1:0] q_boundary_valid_w;
  wire [COLS*DATA_W-1:0] k_boundary_data_w;
  wire [COLS-1:0] k_boundary_valid_w;
  wire [ROWS-1:0] qk_row_done_w;
  reg [ROWS*COLS-1:0] lane_valid_q;
  reg [ROWS*COLS-1:0] lane_valid_next_w;
  wire [ROWS-1:0] row_has_valid_w;
  wire [ROWS*SCORE_W-1:0] max_right_data_w;
  wire [ROWS-1:0] max_right_valid_w;
  wire [ROWS*LSE_W-1:0] sum_right_data_w;
  wire [ROWS-1:0] sum_right_valid_w;
  wire [ROWS*FEATURE_IDX_W-1:0] sum_right_tag_w;
  wire [ROWS*(ACC_W+FEATURE_IDX_W)-1:0] pv_seed_boundary_packed_w;
  wire [ROWS*ACC_W-1:0] pv_seed_boundary_data_w;
  wire [ROWS*FEATURE_IDX_W-1:0] pv_seed_boundary_tag_w;
  wire [ROWS-1:0] pv_seed_boundary_valid_w;

  wire [COLS*DATA_W-1:0] stripe_k_data_w [0:NUM_STRIPES];
  wire [COLS-1:0] stripe_k_valid_w [0:NUM_STRIPES];
  wire [NUM_STRIPES-1:0] stripe_delta_col_valid_w;
  wire [COL_IDX_W-1:0] stripe_delta_col_index_w [0:NUM_STRIPES-1];
  wire [STRIPE_ROWS*SCORE_W-1:0] stripe_delta_col_data_w [0:NUM_STRIPES-1];
  wire [NUM_STRIPES-1:0] stripe_o_rd_valid_w;
  wire [STRIPE_ROWS*ACC_W-1:0] stripe_o_rd_data_w [0:NUM_STRIPES-1];
  wire [NUM_STRIPES-1:0] stripe_o_rd_en_w;
  wire [FEATURE_IDX_W-1:0] stripe_o_rd_feature_w [0:NUM_STRIPES-1];
  wire [NUM_STRIPES-1:0] stripe_pv_seed_valid_w;
  wire [STRIPE_ROWS*ACC_W-1:0] stripe_pv_seed_data_w
      [0:NUM_STRIPES-1];
  wire [FEATURE_IDX_W-1:0] stripe_pv_seed_feature_w
      [0:NUM_STRIPES-1];
  wire pv_seed_stage_valid_w = stripe_pv_seed_valid_w[0];

  wire [ROWS*SCORE_W-1:0] delta_col_data_w;
  wire delta_col_valid_w;
  wire [COL_IDX_W-1:0] delta_col_index_w;

  wire [EXP_LANES*SCORE_W-1:0] exp_source_data_w;
  wire exp_source_valid_w;
  wire [EXP_LANES*16-1:0] scaled_exp_data_w;
  wire [EXP_LANES-1:0] scaled_exp_valid_w;
  wire [EXP_LANES*PROB_W-1:0] exp_data_w;
  wire [EXP_LANES-1:0] exp_valid_w;
  wire exp_stage_valid_w;
  wire prob_write_valid_w;
  wire [COL_IDX_W-1:0] prob_write_col_w;

  wire qk_tail_last_w;
  wire pipeline_clear_w;
  wire source_is_pv_w;
  wire source_valid_w;
  wire [COLS*DATA_W-1:0] source_cols_w;
  wire seed_read_request_w;
  wire [NUM_STRIPES*STRIPE_ROWS*ACC_W-1:0] stripe_o_rd_flat_w;
  wire array_gate_enable_w;
  wire array_clk_w;
  wire q_skew_clk_w;
  wire pv_seed_skew_clk_w;
  wire k_skew_clk_w;
  wire q_skew_gate_enable_w;
  wire pv_seed_skew_gate_enable_w;
  wire k_skew_gate_enable_w;
  reg [ROWS:0] q_skew_occupancy_q;
  reg [ROWS:0] pv_seed_skew_occupancy_q;
  reg [COLS:0] k_skew_occupancy_q;

  integer row_idx;
  integer tag_stage;
  integer consistency_stripe;
  integer mask_row;
  integer mask_col;
  reg [31:0] query_index_w;
  reg [31:0] valid_col_count_w;
  reg [31:0] causal_col_count_w;
  reg [31:0] seq_kv_int_w;
  reg [31:0] seq_q_int_w;
  reg [31:0] k_base_int_w;
  reg signed [SCORE_W-1:0] old_m_w;
  reg signed [SCORE_W-1:0] block_max_w;
  reg signed [SCORE_W-1:0] next_m_w;
  reg [LSE_W-1:0] lse_sum_s0_q;
  reg [LSE_W-1:0] lse_sum_s1_q;
  reg [LSE_W-1:0] lse_old_l_s0_q;
  reg [LSE_W-1:0] lse_old_l_s1_q;
  reg lse_bypass_s0_q;
  reg lse_bypass_s1_q;
  reg [ROW_IDX_W-1:0] lse_row_s0_q;
  reg [ROW_IDX_W-1:0] lse_row_s1_q;
  reg lse_metadata_valid_s0_q;
  reg lse_metadata_valid_s1_q;
  reg pv_issue_valid_q;
  reg pv_issue_seed_zero_q;
  reg [FEATURE_IDX_W-1:0] pv_issue_feature_q;
  reg [COLS*DATA_W-1:0] pv_issue_cols_q;
  reg [COLS*DATA_W-1:0] pv_rescale_cols_q;
  reg [COLS*DATA_W-1:0] pv_rescale_cols_s1_q;
  reg [COLS*DATA_W-1:0] pv_rescale_cols_s2_q;
  // Keep a shadow feature tag with the V payload pipeline. PEs receive their
  // writeback tag from the O-seed wave, and this tag proves that wave is paired
  // with the V[:,d] value entering the column-skew network.
  reg [FEATURE_IDX_W-1:0] pv_rescale_feature_q;
  reg [FEATURE_IDX_W-1:0] pv_rescale_feature_s1_q;
  reg [FEATURE_IDX_W-1:0] pv_rescale_feature_s2_q;
  reg [QK_COMPLETION_DEPTH-1:0] qk_completion_q;
  reg norm_request_q;
  reg [STRIPE_IDX_W-1:0] norm_request_stripe_q;
  reg [FEATURE_IDX_W-1:0] norm_request_feature_q;

  wire lse_issue_valid_w = (softmax_state_q == SM_L_UPDATE);
  // Preserve initialized row state when this physical KV tile contains no
  // unmasked key for the row. Q1.15 cannot encode exact 1.0, so exp(0)=0x7fff
  // must not be used for what is mathematically an identity update.
  wire [ROWS-1:0] row_tile_bypass_w =
      old_row_state_valid_q & ~row_has_valid_w;
  wire lse_product_valid_w;
  wire [L_PRODUCT_W-1:0] lse_product_w;
  wire [L_PRODUCT_W:0] lse_total_w =
      {1'b0, (lse_product_w >> `ATTN_BETA_FRAC)} +
      {{(L_PRODUCT_W+1-LSE_W){1'b0}}, lse_sum_s1_q};
  wire [LSE_W-1:0] lse_new_l_math_w =
      (|lse_total_w[L_PRODUCT_W:LSE_W]) ?
      {LSE_W{1'b1}} : lse_total_w[LSE_W-1:0];
  wire [LSE_W-1:0] lse_new_l_w =
      lse_bypass_s1_q ? lse_old_l_s1_q : lse_new_l_math_w;
  // Product and metadata are driven by the same issue token through equal
  // two-cycle pipelines. The product valid is canonical; SVA checks metadata.
  wire lse_result_valid_w = lse_product_valid_w;
  wire [ROWS*LSE_W-1:0] lse_new_l_extended_w =
      {{((ROWS-1)*LSE_W){1'b0}}, lse_new_l_w};
  wire [ROWS*LSE_W-1:0] l_rows_shifted_w =
      (l_rows_q >> LSE_W) |
      (lse_new_l_extended_w << ((ROWS-1)*LSE_W));

  // The row-state update consumes fixed low slices of three shift streams.
  // There is no counter-driven 32:1 operand mux in front of this multiplier.
  fa_unsigned_mult_pipe2 #(
    .A_W(LSE_W), .B_W(PROB_W), .SPLIT_W(LSE_W/2)
  ) u_lse_update_multiplier (
    .clk(array_clk_w), .rst_n(rst_n), .valid_i(lse_issue_valid_w),
    .a_i(old_l_q[LSE_W-1:0]),
    .b_i(alpha_update_stream_q[PROB_W-1:0]),
    .valid_o(lse_product_valid_w), .product_o(lse_product_w)
  );

  // Sum and row metadata cross the same two cycles as the multiplier. Synchronous
  // clear suppresses any product that was already in flight.
  always @(posedge array_clk_w or negedge rst_n) begin
    if (!rst_n) begin
      lse_metadata_valid_s0_q <= 1'b0;
      lse_metadata_valid_s1_q <= 1'b0;
    end else if (clear_i) begin
      lse_metadata_valid_s0_q <= 1'b0;
      lse_metadata_valid_s1_q <= 1'b0;
    end else begin
      lse_metadata_valid_s0_q <= lse_issue_valid_w;
      lse_metadata_valid_s1_q <= lse_metadata_valid_s0_q;
      if (lse_issue_valid_w) begin
        lse_sum_s0_q <= sum_rows_q[LSE_W-1:0];
        lse_old_l_s0_q <= old_l_q[LSE_W-1:0];
        lse_bypass_s0_q <= lse_bypass_stream_q[0];
        lse_row_s0_q <= lse_update_row_q;
      end
      if (lse_metadata_valid_s0_q) begin
        lse_sum_s1_q <= lse_sum_s0_q;
        lse_old_l_s1_q <= lse_old_l_s0_q;
        lse_bypass_s1_q <= lse_bypass_s0_q;
        lse_row_s1_q <= lse_row_s0_q;
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (ROWS != COLS) $fatal(1, "fsa_fused_array requires ROWS == COLS");
    if (ROWS % STRIPE_ROWS != 0) $fatal(1, "ROWS must be divisible by STRIPE_ROWS");
    if ((1 << LOCAL_ROW_IDX_W) != STRIPE_ROWS)
      $fatal(1, "STRIPE_ROWS must be a power of two");
    if (QK_COMPLETION_DEPTH < ROWS + 1)
      $fatal(1, "QK completion sideband is too short for rowmax launch");
  end

  property p_stripe_delta_valids_aligned;
    @(posedge clk) disable iff (!rst_n || clear_i)
      stripe_delta_col_valid_w ==
        {NUM_STRIPES{stripe_delta_col_valid_w[0]}};
  endproperty
  a_stripe_delta_valids_aligned:
    assert property (p_stripe_delta_valids_aligned)
    else $fatal(1, "fsa_fused_array stripe delta-column valid misalignment");

  property p_stripe_pv_seed_valids_aligned;
    @(posedge clk) disable iff (!rst_n || clear_i)
      stripe_pv_seed_valid_w ==
        {NUM_STRIPES{stripe_pv_seed_valid_w[0]}};
  endproperty
  a_stripe_pv_seed_valids_aligned:
    assert property (p_stripe_pv_seed_valids_aligned)
    else $fatal(1, "fsa_fused_array stripe PV-seed valid misalignment");

  property p_exp_lane_valids_aligned;
    @(posedge array_clk_w) disable iff (!rst_n || clear_i)
      exp_valid_w == {EXP_LANES{exp_valid_w[0]}};
  endproperty
  a_exp_lane_valids_aligned:
    assert property (p_exp_lane_valids_aligned)
    else $fatal(1, "fsa_fused_array exp lane valid misalignment");

  property p_lse_product_metadata_valid_aligned;
    @(posedge array_clk_w) disable iff (!rst_n || clear_i)
      lse_product_valid_w == lse_metadata_valid_s1_q;
  endproperty
  a_lse_product_metadata_valid_aligned:
    assert property (p_lse_product_metadata_valid_aligned)
    else $fatal(1, "fsa_fused_array l-update product/metadata valid mismatch");

  always @(posedge clk) begin
    if (rst_n && stripe_delta_col_valid_w[0]) begin
      for (consistency_stripe = 1; consistency_stripe < NUM_STRIPES;
           consistency_stripe = consistency_stripe + 1)
        if (stripe_delta_col_index_w[consistency_stripe] !=
            stripe_delta_col_index_w[0])
          $fatal(1, "fsa_fused_array stripe delta-column tag mismatch");
    end
    if (rst_n && pv_seed_stage_valid_w) begin
      for (consistency_stripe = 1; consistency_stripe < NUM_STRIPES;
           consistency_stripe = consistency_stripe + 1)
        if (stripe_pv_seed_feature_w[consistency_stripe] !=
            stripe_pv_seed_feature_w[0])
          $fatal(1, "fsa_fused_array stripe PV-seed feature mismatch");
      if (stripe_pv_seed_feature_w[0] != pv_rescale_feature_s2_q)
        $fatal(1, "fsa_fused_array V/O-seed feature misalignment");
    end
  end
`endif

  // The control/exp branch remains active for a complete array transaction.
  // Skew and stripe datapaths use narrower phase-local branches below.
  assign array_gate_enable_w = !rst_n || clock_en_i || clear_i ||
      clear_rows_i || qk_clear_i;
  fa_clock_gate u_array_clock_gate (
    .clk_i(clk), .enable_i(array_gate_enable_w), .test_enable_i(1'b0),
    .clk_o(array_clk_w)
  );

  // QK and WS-PV share the vertical K/V network. pv_issue_* is a registered copy
  // of one V[:,d] transfer and its full feature ID.
  assign pipeline_clear_w = clear_i || qk_clear_i || pv_start_i;
  assign source_is_pv_w = mac_phase_pv_q;
  // The stripe-local operand register and latency-2 O-rescale add three PV
  // stages. V follows the same payload pipeline before entering column skew.
  assign source_valid_w = source_is_pv_w ?
                          pv_seed_stage_valid_w : qk_valid_i;
  assign source_cols_w = source_is_pv_w ? pv_rescale_cols_s2_q : qk_cols_i;

  // Each skew network is a complete payload/valid bundle. A root-clock
  // occupancy tail keeps its ICG open until the deepest delay line has shifted
  // the final token and then cleared its last valid bit.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q_skew_occupancy_q <= {(ROWS+1){1'b0}};
      pv_seed_skew_occupancy_q <= {(ROWS+1){1'b0}};
      k_skew_occupancy_q <= {(COLS+1){1'b0}};
    end else if (pipeline_clear_w) begin
      q_skew_occupancy_q <= {(ROWS+1){1'b0}};
      pv_seed_skew_occupancy_q <= {(ROWS+1){1'b0}};
      k_skew_occupancy_q <= {(COLS+1){1'b0}};
    end else begin
      q_skew_occupancy_q <=
          {q_skew_occupancy_q[ROWS-1:0], qk_valid_i};
      pv_seed_skew_occupancy_q <=
          {pv_seed_skew_occupancy_q[ROWS-1:0],
           pv_seed_stage_valid_w};
      k_skew_occupancy_q <=
          {k_skew_occupancy_q[COLS-1:0], source_valid_w};
    end
  end

  assign q_skew_gate_enable_w = !rst_n || pipeline_clear_w || qk_valid_i ||
      (|q_skew_occupancy_q) || (|q_boundary_valid_w);
  assign pv_seed_skew_gate_enable_w = !rst_n || pipeline_clear_w ||
      pv_seed_stage_valid_w || (|pv_seed_skew_occupancy_q) ||
      (|pv_seed_boundary_valid_w);
  assign k_skew_gate_enable_w = !rst_n || pipeline_clear_w || source_valid_w ||
      (|k_skew_occupancy_q) || (|k_boundary_valid_w);

  fa_clock_gate u_q_skew_clock_gate (
    .clk_i(clk), .enable_i(q_skew_gate_enable_w),
    .test_enable_i(1'b0), .clk_o(q_skew_clk_w)
  );
  fa_clock_gate u_pv_seed_skew_clock_gate (
    .clk_i(clk), .enable_i(pv_seed_skew_gate_enable_w),
    .test_enable_i(1'b0), .clk_o(pv_seed_skew_clk_w)
  );
  fa_clock_gate u_k_skew_clock_gate (
    .clk_i(clk), .enable_i(k_skew_gate_enable_w),
    .test_enable_i(1'b0), .clk_o(k_skew_clk_w)
  );

  // One diagonal completion shift register replaces q_last/k_last/mac_last in
  // every PE. Tap row+1 launches that row's column-0 max after its final MAC;
  // the final tap preserves the former bottom-right completion latency.
  always @(posedge array_clk_w or negedge rst_n) begin
    if (!rst_n)
      qk_completion_q <= {QK_COMPLETION_DEPTH{1'b0}};
    else if (pipeline_clear_w)
      qk_completion_q <= {QK_COMPLETION_DEPTH{1'b0}};
    else
      qk_completion_q <=
          {qk_completion_q[QK_COMPLETION_DEPTH-2:0],
           qk_valid_i && qk_last_i};
  end
  // For non-first KV tiles, the incoming V feature ID is simultaneously used as
  // the persistent O-bank read address. First-tile seeds bypass memory with zero.
  assign seed_read_request_w = pv_valid_i && !pv_seed_zero_i;
  assign delta_col_valid_w = stripe_delta_col_valid_w[0];
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
      query_index_w = {16'd0, q_base_i} + $unsigned(mask_row);
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
        lane_valid_next_w[$unsigned(mask_row*COLS+mask_col)] =
            $unsigned(mask_col) < valid_col_count_w;
    end
  end

  // Row skew aligns Q with K during QK. The second delay line receives the
  // stripe-local registered/rescaled O seed and its feature tag while the
  // equally delayed V[:,d] follows the column-skew network.
  generate
    genvar skew_row;
    for (skew_row = 0; skew_row < ROWS; skew_row = skew_row + 1) begin : g_q_skew
      fsa_delay_line #(.WIDTH(DATA_W), .DEPTH(skew_row+1)) u_q_skew (
        .clk(q_skew_clk_w), .rst_n(rst_n), .clear_i(pipeline_clear_w),
        .valid_i(qk_valid_i), .last_i(1'b0),
        .data_i(qk_rows_i[skew_row*DATA_W +: DATA_W]),
        .valid_o(q_boundary_valid_w[skew_row]),
        .last_o(),
        .data_o(q_boundary_data_w[skew_row*DATA_W +: DATA_W])
      );

      fsa_delay_line #(.WIDTH(ACC_W+FEATURE_IDX_W), .DEPTH(skew_row+1))
      u_pv_seed_skew (
        .clk(pv_seed_skew_clk_w), .rst_n(rst_n),
        .clear_i(pipeline_clear_w),
        .valid_i(stripe_pv_seed_valid_w[skew_row/STRIPE_ROWS]),
        .last_i(1'b0),
        .data_i({stripe_pv_seed_feature_w[skew_row/STRIPE_ROWS],
                 stripe_pv_seed_data_w[skew_row/STRIPE_ROWS][
                     (skew_row%STRIPE_ROWS)*ACC_W +: ACC_W]}),
        .valid_o(pv_seed_boundary_valid_w[skew_row]),
        .last_o(),
        .data_o(pv_seed_boundary_packed_w[
            skew_row*(ACC_W+FEATURE_IDX_W) +: ACC_W+FEATURE_IDX_W])
      );
      assign pv_seed_boundary_data_w[skew_row*ACC_W +: ACC_W] =
          pv_seed_boundary_packed_w[
              skew_row*(ACC_W+FEATURE_IDX_W) +: ACC_W];
      assign pv_seed_boundary_tag_w[skew_row*FEATURE_IDX_W +: FEATURE_IDX_W] =
          pv_seed_boundary_packed_w[
              skew_row*(ACC_W+FEATURE_IDX_W)+ACC_W +: FEATURE_IDX_W];

    end

    genvar skew_col;
    for (skew_col = 0; skew_col < COLS; skew_col = skew_col + 1) begin : g_k_skew
      fsa_delay_line #(.WIDTH(DATA_W), .DEPTH(skew_col+1)) u_k_skew (
        .clk(k_skew_clk_w), .rst_n(rst_n), .clear_i(pipeline_clear_w),
        .valid_i(source_valid_w), .last_i(1'b0),
        .data_i(source_cols_w[skew_col*DATA_W +: DATA_W]),
        .valid_o(k_boundary_valid_w[skew_col]),
        .last_o(),
        .data_o(k_boundary_data_w[skew_col*DATA_W +: DATA_W])
      );
    end

    genvar valid_row;
    for (valid_row = 0; valid_row < ROWS; valid_row = valid_row + 1) begin : g_row_valid
      assign row_has_valid_w[valid_row] =
          |lane_valid_q[valid_row*COLS +: COLS];
      assign qk_row_done_w[valid_row] = qk_completion_q[valid_row+1];
    end

    assign stripe_k_data_w[0] = k_boundary_data_w;
    assign stripe_k_valid_w[0] = k_boundary_valid_w;

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
      fsa_stripe #(
        .STRIPE_ROWS(STRIPE_ROWS), .COLS(COLS), .DATA_W(DATA_W),
        .SCORE_W(SCORE_W), .PROB_W(PROB_W), .SUM_W(ACC_W),
        .HEAD_DIM(HEAD_DIM), .TAG_W(FEATURE_IDX_W),
        .LOCAL_ROW_IDX_W(LOCAL_ROW_IDX_W)
      ) u_stripe (
        // A new Q tile starts a fresh online-attention recurrence.  Propagate
        // clear_rows_i into every stripe so its persistent O bank cannot leak
        // the same physical row from the preceding Q tile.
        .clk(clk), .rst_n(rst_n), .clock_en_i(array_gate_enable_w),
        .clear_i(clear_i || clear_rows_i),
        .clear_score_i(qk_clear_i), .ws_pv_i(source_is_pv_w),
        .q_rows_i(q_boundary_data_w[ROW_BASE*DATA_W +: STRIPE_ROWS*DATA_W]),
        .q_valid_i(q_boundary_valid_w[ROW_BASE +: STRIPE_ROWS]),
        .qk_row_done_i(qk_row_done_w[ROW_BASE +: STRIPE_ROWS]),
        .k_top_data_i(stripe_k_data_w[stripe]),
        .k_top_valid_i(stripe_k_valid_w[stripe]),
        .k_bottom_data_o(stripe_k_data_w[stripe+1]),
        .k_bottom_valid_o(stripe_k_valid_w[stripe+1]),
        .lane_valid_i(lane_valid_q[ROW_BASE*COLS +: STRIPE_ROWS*COLS]),
        .max_done_valid_o(max_right_valid_w[ROW_BASE +: STRIPE_ROWS]),
        .max_done_data_o(max_right_data_w[ROW_BASE*SCORE_W +: STRIPE_ROWS*SCORE_W]),
        .m_start_valid_i({STRIPE_ROWS{softmax_state_q == SM_M_START}}),
        // SM_ALPHA_WAIT commits m_pending_q before SM_M_START.  Source the
        // reverse wave from that register boundary so block-max selection is
        // not combinationally chained into every PE delta subtractor.
        .m_start_data_i(m_rows_q[ROW_BASE*SCORE_W +: STRIPE_ROWS*SCORE_W]),
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
        .pv_sum_data_i(pv_seed_boundary_data_w[
            ROW_BASE*ACC_W +: STRIPE_ROWS*ACC_W]),
        .pv_sum_tag_i(pv_seed_boundary_tag_w[
            ROW_BASE*FEATURE_IDX_W +: STRIPE_ROWS*FEATURE_IDX_W]),
        .pv_seed_operand_valid_i(pv_issue_valid_q),
        .pv_seed_zero_i(pv_issue_seed_zero_q),
        .pv_seed_alpha_i(alpha_rows_q[
            ROW_BASE*PROB_W +: STRIPE_ROWS*PROB_W]),
        .pv_seed_bypass_i(row_tile_bypass_w[
            ROW_BASE +: STRIPE_ROWS]),
        .pv_seed_feature_i(pv_issue_feature_q),
        .pv_seed_valid_o(stripe_pv_seed_valid_w[stripe]),
        .pv_seed_data_o(stripe_pv_seed_data_w[stripe]),
        .pv_seed_feature_o(stripe_pv_seed_feature_w[stripe]),
        .o_rd_en_i(stripe_o_rd_en_w[stripe]),
        .o_rd_feature_i(stripe_o_rd_feature_w[stripe]),
        .o_rd_valid_o(stripe_o_rd_valid_w[stripe]),
        .o_rd_data_o(stripe_o_rd_data_w[stripe]),
        .delta_col_valid_o(stripe_delta_col_valid_w[stripe]),
        .delta_col_index_o(stripe_delta_col_index_w[stripe]),
        .delta_col_data_o(stripe_delta_col_data_w[stripe])
      );
    end
  endgenerate

  assign qk_tail_last_w =
      qk_completion_q[QK_COMPLETION_DEPTH-1] && !source_is_pv_w;

  // One exp lane per row accepts a completed score column each cycle. The delayed
  // column tag returns probabilities to the exact PE column that produced delta.
  generate
    genvar exp_lane;
    for (exp_lane = 0; exp_lane < EXP_LANES; exp_lane = exp_lane + 1) begin : g_exp_lane
      score_scale_pipe #(.IN_W(SCORE_W), .SCALE_W(16), .OUT_W(16)) u_scale (
        .clk(array_clk_w), .rst_n(rst_n), .valid_i(exp_source_valid_w),
        .data_i(exp_source_data_w[exp_lane*SCORE_W +: SCORE_W]),
        .scale_mant_i(score_scale_i[15:0]), .shift_i(score_scale_i[21:16]),
        .valid_o(scaled_exp_valid_w[exp_lane]),
        .data_o(scaled_exp_data_w[exp_lane*16 +: 16])
      );
      pwl_exp_unit u_exp (
        .clk(array_clk_w), .rst_n(rst_n), .valid_i(scaled_exp_valid_w[exp_lane]),
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
  assign exp_stage_valid_w = exp_valid_w[0];
  assign prob_write_valid_w = exp_stage_valid_w &&
                              prob_col_tag_valid_q[EXP_LATENCY-1];

  // FlashAttention recurrence: m_new=max(m_old, block_max) and
  // alpha=exp(m_old-m_new), with alpha=0 for an uninitialized row state.
  always @(*) begin
    for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
      old_m_w = $signed(m_rows_q[row_idx*SCORE_W +: SCORE_W]);
      block_max_w = $signed(
          block_max_rows_q[row_idx*SCORE_W +: SCORE_W]);
      if (row_state_valid_q[row_idx] && $signed(old_m_w) >= $signed(block_max_w))
        next_m_w = old_m_w;
      else
        next_m_w = block_max_w;
      m_pending_q[row_idx*SCORE_W +: SCORE_W] = $unsigned(next_m_w);
      if (row_state_valid_q[row_idx])
        alpha_delta_q[row_idx*SCORE_W +: SCORE_W] = $unsigned(
            $signed(old_m_w) - $signed(next_m_w));
      else
        alpha_delta_q[row_idx*SCORE_W +: SCORE_W] = {SCORE_W{1'b0}};
    end
  end

  // Register all data/tag/valid paths. In particular the V payload and its
  // shadow feature tag advance together with the synchronous O-bank response
  // before row/column skew, which aligns O_old[:,d] with V[:,d].
  always @(posedge array_clk_w or negedge rst_n) begin
    if (!rst_n) begin
      softmax_state_q <= SM_IDLE;
      mac_phase_pv_q <= 1'b0;
      lse_update_row_q <= {ROW_IDX_W{1'b0}};
      sum_launch_rows_q <= {ROWS{1'b0}};
      prob_col_tag_valid_q <= {EXP_LATENCY{1'b0}};
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
      pv_issue_seed_zero_q <= 1'b0;
      norm_request_q <= 1'b0;
      norm_rd_valid_o <= 1'b0;
      norm_rd_acc_o <= {STRIPE_ROWS*ACC_W{1'b0}};
      norm_rd_l_o <= {STRIPE_ROWS*LSE_W{1'b0}};
      norm_rd_stripe_o <= {STRIPE_IDX_W{1'b0}};
      norm_rd_feature_o <= {FEATURE_IDX_W{1'b0}};
      error_o <= 1'b0;
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
      norm_rd_acc_o <= {STRIPE_ROWS*ACC_W{1'b0}};
      norm_rd_l_o <= {STRIPE_ROWS*LSE_W{1'b0}};
      norm_rd_stripe_o <= {STRIPE_IDX_W{1'b0}};
      norm_rd_feature_o <= {FEATURE_IDX_W{1'b0}};
      sum_launch_rows_q <= {ROWS{1'b0}};
      prob_col_tag_valid_q <= {EXP_LATENCY{1'b0}};
      sum_rows_q <= {ROWS*LSE_W{1'b0}};
      error_o <= 1'b0;
    end else begin
      qk_last_o <= qk_tail_last_w;
      softmax_pv_ready_o <= 1'b0;
      softmax_done_o <= 1'b0;
      pv_ready_o <= pv_start_i;
      pv_done_o <= 1'b0;
      pv_issue_valid_q <= pv_valid_i;
      pv_issue_seed_zero_q <= pv_seed_zero_i;
      pv_issue_feature_q <= pv_feature_i;
      pv_issue_cols_q <= pv_cols_i;
      if (pv_issue_valid_q)
        pv_rescale_cols_q <= pv_issue_cols_q;
      if (pv_issue_valid_q)
        pv_rescale_feature_q <= pv_issue_feature_q;
      pv_rescale_cols_s1_q <= pv_rescale_cols_q;
      pv_rescale_feature_s1_q <= pv_rescale_feature_q;
      pv_rescale_cols_s2_q <= pv_rescale_cols_s1_q;
      pv_rescale_feature_s2_q <= pv_rescale_feature_s1_q;
      norm_request_q <= norm_rd_en_i;
      if (norm_rd_en_i) begin
        norm_request_stripe_q <= norm_rd_stripe_i;
        norm_request_feature_q <= norm_rd_feature_i;
      end
      // O-bank data changes on every synchronous read response. Capture the
      // selected payload with the delayed request tag; exposing a combinational
      // O-bank output here would pair tag d with the next response O[:,d+1]
      // during the feature-major normalizer scan.
      norm_rd_valid_o <= norm_request_q &&
          stripe_o_rd_valid_w[norm_request_stripe_q];
      if (norm_request_q && stripe_o_rd_valid_w[norm_request_stripe_q]) begin
        norm_rd_acc_o <= stripe_o_rd_flat_w[
            norm_request_stripe_q*STRIPE_ROWS*ACC_W +: STRIPE_ROWS*ACC_W];
        norm_rd_l_o <= l_rows_q[
            norm_request_stripe_q*STRIPE_ROWS*LSE_W +: STRIPE_ROWS*LSE_W];
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
          if (exp_stage_valid_w) begin
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
            alpha_update_stream_q <= alpha_rows_q;
            lse_bypass_stream_q <= row_tile_bypass_w;
            lse_update_row_q <= {ROW_IDX_W{1'b0}};
            softmax_pv_ready_o <= 1'b1;
            softmax_state_q <= SM_L_UPDATE;
          end
        end
        SM_L_UPDATE: begin
          // Destructive stream shifts are safe: alpha_rows_q remains intact for
          // overlapping WS-PV, while old_l_q and sum_rows_q have no later reader.
          old_l_q <= old_l_q >> LSE_W;
          sum_rows_q <= sum_rows_q >> LSE_W;
          alpha_update_stream_q <= alpha_update_stream_q >> PROB_W;
          lse_bypass_stream_q <= lse_bypass_stream_q >> 1;
          if (lse_update_row_q == ROW_LAST)
            softmax_state_q <= SM_L_DRAIN;
          else
            lse_update_row_q <= lse_update_row_q + 1'b1;
        end
        SM_L_DRAIN: begin
          // Wait for the last two products to leave the II=1 multiplier.
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

      // Insert each completed row at the fixed high end. After ROWS commits the
      // shift register is ordered identically to the original packed l_rows_q.
      if (lse_result_valid_w) begin
        l_rows_q <= l_rows_shifted_w;
        if (lse_row_s1_q == ROW_LAST) begin
          row_state_valid_q <= row_state_valid_q | row_has_valid_w;
          softmax_state_q <= SM_DONE;
        end
      end

      if (sum_right_valid_w[ROWS-1] &&
          sum_right_tag_w[(ROWS-1)*FEATURE_IDX_W +: FEATURE_IDX_W] ==
          FEATURE_LAST)
        pv_done_o <= 1'b1;
    end
  end

endmodule
