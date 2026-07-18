`timescale 1ns/1ps
`include "attention_defines.vh"
`include "fixed_defs.vh"

module os_fsa_fused_array #(
  parameter integer ROWS = `ATTN_ARRAY_ROWS,
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
  output     [ROWS*PROB_W-1:0]       alpha_rows_o,
  output     [ROWS*LSE_W-1:0]        l_rows_o,
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
  localparam integer PROB_MATRIX_W = ROWS * COLS * PROB_W;
  localparam integer ACC_MATRIX_W = ROWS * COLS * ACC_W;
  localparam integer Q_NODES = ROWS * (COLS + 1);
  localparam integer K_NODES = (ROWS + 1) * COLS;
  localparam integer REDUCE_NODES = ROWS * (COLS + 1);
  localparam integer EXP_LANES = COLS;
  localparam integer L_PRODUCT_W = LSE_W + PROB_W;
  localparam [ROW_IDX_W-1:0] ROW_LAST = ROWS - 1;
  localparam signed [SCORE_W-1:0] SCORE_MIN = {1'b1, {(SCORE_W-1){1'b0}}};

  localparam SM_IDLE = 4'd0;
  localparam SM_MAX_START = 4'd1;
  localparam SM_MAX_WAIT = 4'd2;
  localparam SM_ALPHA_LAUNCH = 4'd3;
  localparam SM_ALPHA_WAIT = 4'd4;
  localparam SM_M_START = 4'd5;
  localparam SM_M_WAIT = 4'd6;
  localparam SM_PROB_ISSUE = 4'd7;
  localparam SM_PROB_DRAIN = 4'd8;
  localparam SM_SUM_START = 4'd9;
  localparam SM_SUM_WAIT = 4'd10;
  localparam SM_L_UPDATE = 4'd11;
  localparam SM_DONE = 4'd12;

  reg [3:0] softmax_state_q;
  reg mac_phase_pv_q;
  reg [ROW_IDX_W-1:0] prob_issue_row_q;
  reg [ROW_IDX_W-1:0] prob_receive_row_q;
  reg [ROW_IDX_W-1:0] stream_row_q;
  reg stream_active_q;

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
  wire [Q_NODES*DATA_W-1:0] q_node_data_w;
  wire [Q_NODES-1:0] q_node_valid_w;
  wire [Q_NODES-1:0] q_node_last_w;
  wire [K_NODES*DATA_W-1:0] k_node_data_w;
  wire [K_NODES-1:0] k_node_valid_w;
  wire [K_NODES-1:0] k_node_last_w;

  wire [ROWS*COLS*SCORE_W-1:0] delta_matrix_w;
  wire [PROB_MATRIX_W-1:0] prob_shift_matrix_w;
  wire [ACC_MATRIX_W-1:0] acc_matrix_w;
  wire [ROWS*COLS-1:0] pe_last_w;
  wire [ROWS*COLS-1:0] lane_valid_w;
  wire [ROWS-1:0] row_has_valid_w;

  wire [REDUCE_NODES*SCORE_W-1:0] max_node_data_w;
  wire [REDUCE_NODES-1:0] max_node_valid_w;
  wire [REDUCE_NODES*SCORE_W-1:0] m_node_data_w;
  wire [REDUCE_NODES-1:0] m_node_valid_w;
  wire [REDUCE_NODES*LSE_W-1:0] sum_node_data_w;
  wire [REDUCE_NODES-1:0] sum_node_valid_w;
  wire [ROWS*SCORE_W-1:0] max_right_data_w;
  wire [ROWS-1:0] max_right_valid_w;
  wire [ROWS-1:0] m_left_valid_w;
  wire [ROWS*LSE_W-1:0] sum_right_data_w;
  wire [ROWS-1:0] sum_right_valid_w;

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

  integer row_idx;
  integer col_idx;
  reg signed [SCORE_W-1:0] old_m_w;
  reg signed [SCORE_W-1:0] block_max_w;
  reg signed [SCORE_W-1:0] next_m_w;
  reg [L_PRODUCT_W-1:0] l_product_w;
  reg [L_PRODUCT_W:0] l_total_w;

  assign alpha_rows_o = alpha_rows_q;
  assign l_rows_o = l_rows_q;
  assign pipeline_clear_w = clear_i || qk_clear_i || pv_start_i;
  assign source_is_pv_w = mac_phase_pv_q;
  assign source_valid_w = qk_valid_i || pv_valid_i;
  assign source_last_w = source_is_pv_w ? pv_last_i : qk_last_i;
  assign source_cols_w = source_is_pv_w ? pv_cols_i : qk_cols_i;

  generate
    genvar source_row;
    for (source_row = 0; source_row < ROWS; source_row = source_row + 1) begin : g_source_row
      assign source_rows_w[source_row*DATA_W +: DATA_W] = source_is_pv_w ?
          {{(DATA_W-PROB_W){1'b0}},
           prob_shift_matrix_w[(source_row*COLS)*PROB_W +: PROB_W]} :
          qk_rows_i[source_row*DATA_W +: DATA_W];
    end
  endgenerate

  generate
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
      assign q_node_valid_w[skew_row*(COLS+1)] = q_boundary_valid_w[skew_row];
      assign q_node_last_w[skew_row*(COLS+1)] = q_boundary_last_w[skew_row];
      assign q_node_data_w[(skew_row*(COLS+1))*DATA_W +: DATA_W] =
          q_boundary_data_w[skew_row*DATA_W +: DATA_W];
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
      assign k_node_valid_w[skew_col] = k_boundary_valid_w[skew_col];
      assign k_node_last_w[skew_col] = k_boundary_last_w[skew_col];
      assign k_node_data_w[skew_col*DATA_W +: DATA_W] =
          k_boundary_data_w[skew_col*DATA_W +: DATA_W];
    end
  endgenerate

  generate
    genvar mask_row;
    genvar mask_col;
    for (mask_row = 0; mask_row < ROWS; mask_row = mask_row + 1) begin : g_mask_row
      assign row_has_valid_w[mask_row] = |lane_valid_w[mask_row*COLS +: COLS];
      assign max_node_valid_w[mask_row*(COLS+1)] =
          pe_last_w[mask_row*COLS] && !mac_phase_pv_q;
      assign max_node_data_w[(mask_row*(COLS+1))*SCORE_W +: SCORE_W] = SCORE_MIN;
      assign m_node_valid_w[mask_row*(COLS+1)+COLS] = (softmax_state_q == SM_M_START);
      assign m_node_data_w[(mask_row*(COLS+1)+COLS)*SCORE_W +: SCORE_W] =
          m_pending_q[mask_row*SCORE_W +: SCORE_W];
      assign sum_node_valid_w[mask_row*(COLS+1)] = (softmax_state_q == SM_SUM_START);
      assign sum_node_data_w[(mask_row*(COLS+1))*LSE_W +: LSE_W] = {LSE_W{1'b0}};
      assign max_right_valid_w[mask_row] = max_node_valid_w[mask_row*(COLS+1)+COLS];
      assign max_right_data_w[mask_row*SCORE_W +: SCORE_W] =
          max_node_data_w[(mask_row*(COLS+1)+COLS)*SCORE_W +: SCORE_W];
      assign m_left_valid_w[mask_row] = m_node_valid_w[mask_row*(COLS+1)];
      assign sum_right_valid_w[mask_row] = sum_node_valid_w[mask_row*(COLS+1)+COLS];
      assign sum_right_data_w[mask_row*LSE_W +: LSE_W] =
          sum_node_data_w[(mask_row*(COLS+1)+COLS)*LSE_W +: LSE_W];

      for (mask_col = 0; mask_col < COLS; mask_col = mask_col + 1) begin : g_mask_col
        localparam [15:0] ROW_OFFSET = mask_row;
        localparam [15:0] COL_OFFSET = mask_col;
        wire [16:0] query_index_w = {1'b0, q_base_i} + ROW_OFFSET;
        wire [16:0] key_index_w = {1'b0, k_base_i} + COL_OFFSET;
        assign lane_valid_w[mask_row*COLS+mask_col] =
            (query_index_w < {1'b0, seq_q_i}) &&
            (key_index_w < {1'b0, seq_kv_i}) &&
            (!causal_en_i || key_index_w <= query_index_w);
      end
    end
  endgenerate

  generate
    genvar pe_row;
    genvar pe_col;
    for (pe_row = 0; pe_row < ROWS; pe_row = pe_row + 1) begin : g_pe_row
      for (pe_col = 0; pe_col < COLS; pe_col = pe_col + 1) begin : g_pe_col
        localparam integer PE_INDEX = pe_row*COLS + pe_col;
        localparam integer Q_IN_NODE = pe_row*(COLS+1) + pe_col;
        localparam integer Q_OUT_NODE = Q_IN_NODE + 1;
        localparam integer K_IN_NODE = pe_row*COLS + pe_col;
        localparam integer K_OUT_NODE = (pe_row+1)*COLS + pe_col;
        localparam integer RED_IN_NODE = pe_row*(COLS+1) + pe_col;
        localparam integer RED_OUT_NODE = RED_IN_NODE + 1;
        localparam integer M_IN_NODE = pe_row*(COLS+1) + pe_col + 1;
        localparam integer M_OUT_NODE = M_IN_NODE - 1;
        wire [PROB_W-1:0] prob_shift_from_right_w;

        if (pe_col == COLS-1) begin : g_prob_edge
          assign prob_shift_from_right_w = {PROB_W{1'b0}};
        end else begin : g_prob_neighbor
          assign prob_shift_from_right_w =
              prob_shift_matrix_w[(PE_INDEX+1)*PROB_W +: PROB_W];
        end

        os_fsa_fused_pe #(
          .DATA_W(DATA_W), .SCORE_W(SCORE_W), .PROB_W(PROB_W),
          .ACC_W(ACC_W), .SUM_W(LSE_W)
        ) u_pe (
          .clk(clk), .rst_n(rst_n), .clear_i(clear_i),
          .clear_score_i(qk_clear_i),
          .clear_acc_i(pv_clear_acc_i),
          .load_acc_i(pv_load_row_valid_i && pv_load_row_index_i == pe_row),
          .load_acc_data_i(pv_load_row_data_i[pe_col*ACC_W +: ACC_W]),
          .mac_is_pv_i(source_is_pv_w),

          .q_valid_i(q_node_valid_w[Q_IN_NODE]),
          .q_last_i(q_node_last_w[Q_IN_NODE]),
          .q_data_i(q_node_data_w[Q_IN_NODE*DATA_W +: DATA_W]),
          .q_valid_o(q_node_valid_w[Q_OUT_NODE]),
          .q_last_o(q_node_last_w[Q_OUT_NODE]),
          .q_data_o(q_node_data_w[Q_OUT_NODE*DATA_W +: DATA_W]),
          .k_valid_i(k_node_valid_w[K_IN_NODE]),
          .k_last_i(k_node_last_w[K_IN_NODE]),
          .k_data_i(k_node_data_w[K_IN_NODE*DATA_W +: DATA_W]),
          .k_valid_o(k_node_valid_w[K_OUT_NODE]),
          .k_last_o(k_node_last_w[K_OUT_NODE]),
          .k_data_o(k_node_data_w[K_OUT_NODE*DATA_W +: DATA_W]),

          .score_lane_valid_i(lane_valid_w[PE_INDEX]),
          .score_o(),
          .max_valid_i(max_node_valid_w[RED_IN_NODE]),
          .max_data_i(max_node_data_w[RED_IN_NODE*SCORE_W +: SCORE_W]),
          .max_valid_o(max_node_valid_w[RED_OUT_NODE]),
          .max_data_o(max_node_data_w[RED_OUT_NODE*SCORE_W +: SCORE_W]),
          .m_valid_i(m_node_valid_w[M_IN_NODE]),
          .m_data_i(m_node_data_w[M_IN_NODE*SCORE_W +: SCORE_W]),
          .m_valid_o(m_node_valid_w[M_OUT_NODE]),
          .m_data_o(m_node_data_w[M_OUT_NODE*SCORE_W +: SCORE_W]),
          .delta_o(delta_matrix_w[PE_INDEX*SCORE_W +: SCORE_W]),

          .prob_load_i(prob_write_valid_w && prob_receive_row_q == pe_row),
          .prob_data_i(exp_data_w[pe_col*PROB_W +: PROB_W]),
          .prob_o(),
          .prob_shift_load_i(pv_start_i),
          .prob_shift_en_i(pv_valid_i),
          .prob_shift_i(prob_shift_from_right_w),
          .prob_shift_o(prob_shift_matrix_w[PE_INDEX*PROB_W +: PROB_W]),

          .sum_valid_i(sum_node_valid_w[RED_IN_NODE]),
          .sum_data_i(sum_node_data_w[RED_IN_NODE*LSE_W +: LSE_W]),
          .sum_valid_o(sum_node_valid_w[RED_OUT_NODE]),
          .sum_data_o(sum_node_data_w[RED_OUT_NODE*LSE_W +: LSE_W]),
          .mac_valid_o(),
          .mac_last_o(pe_last_w[PE_INDEX]),
          .acc_o(acc_matrix_w[PE_INDEX*ACC_W +: ACC_W])
        );
      end
    end
  endgenerate

  assign qk_tail_last_w = q_node_valid_w[ROWS*(COLS+1)-1] &&
                          q_node_last_w[ROWS*(COLS+1)-1] &&
                          k_node_valid_w[(ROWS+1)*COLS-1] &&
                          k_node_last_w[(ROWS+1)*COLS-1] && !source_is_pv_w;
  assign pv_tail_last_w = q_node_valid_w[ROWS*(COLS+1)-1] &&
                          q_node_last_w[ROWS*(COLS+1)-1] &&
                          k_node_valid_w[(ROWS+1)*COLS-1] &&
                          k_node_last_w[(ROWS+1)*COLS-1] && source_is_pv_w;

  generate
    genvar exp_lane;
    for (exp_lane = 0; exp_lane < EXP_LANES; exp_lane = exp_lane + 1) begin : g_exp_lane
      scale_requant_unit #(.IN_W(SCORE_W), .SCALE_W(16), .OUT_W(16)) u_scale (
        .clk(clk), .rst_n(rst_n), .valid_i(exp_source_valid_w),
        .data_i(exp_source_data_w[exp_lane*SCORE_W +: SCORE_W]),
        .scale_mant_i(score_scale_i[15:0]),
        .shift_i(score_scale_i[21:16]),
        .zero_point_i(16'sd0),
        .round_mode_i(`ATTN_ROUND_NEAREST),
        .sat_mode_i(`ATTN_SAT_INT16),
        .valid_o(scaled_exp_valid_w[exp_lane]),
        .data_o(scaled_exp_data_w[exp_lane*16 +: 16])
      );
      pwl_exp_unit u_exp (
        .clk(clk), .rst_n(rst_n),
        .valid_i(scaled_exp_valid_w[exp_lane]),
        .x_i(scaled_exp_data_w[exp_lane*16 +: 16]),
        .valid_o(exp_valid_w[exp_lane]),
        .y_o(exp_data_w[exp_lane*PROB_W +: PROB_W])
      );
    end
  endgenerate

  assign exp_source_valid_w = (softmax_state_q == SM_ALPHA_LAUNCH) ||
                              (softmax_state_q == SM_PROB_ISSUE);
  assign all_exp_valid_w = &exp_valid_w;
  assign prob_write_valid_w = all_exp_valid_w &&
                              (softmax_state_q == SM_PROB_ISSUE ||
                               softmax_state_q == SM_PROB_DRAIN);

  generate
    genvar exp_mux_lane;
    for (exp_mux_lane = 0; exp_mux_lane < EXP_LANES; exp_mux_lane = exp_mux_lane + 1) begin : g_exp_mux
      assign exp_source_data_w[exp_mux_lane*SCORE_W +: SCORE_W] =
          (softmax_state_q == SM_ALPHA_LAUNCH) ?
          alpha_delta_q[exp_mux_lane*SCORE_W +: SCORE_W] :
          delta_matrix_w[(prob_issue_row_q*COLS+exp_mux_lane)*SCORE_W +: SCORE_W];
    end
  endgenerate

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

  always @(*) begin
    row_data_o = {COLS*ACC_W{1'b0}};
    for (col_idx = 0; col_idx < COLS; col_idx = col_idx + 1)
      row_data_o[col_idx*ACC_W +: ACC_W] =
          acc_matrix_w[(row_index_o*COLS+col_idx)*ACC_W +: ACC_W];
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      softmax_state_q <= SM_IDLE;
      mac_phase_pv_q <= 1'b0;
      prob_issue_row_q <= {ROW_IDX_W{1'b0}};
      prob_receive_row_q <= {ROW_IDX_W{1'b0}};
      stream_row_q <= {ROW_IDX_W{1'b0}};
      stream_active_q <= 1'b0;
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
      error_o <= 1'b0;
    end else if (clear_i) begin
      softmax_state_q <= SM_IDLE;
      mac_phase_pv_q <= 1'b0;
      stream_active_q <= 1'b0;
      row_state_valid_q <= {ROWS{1'b0}};
      max_ready_rows_q <= {ROWS{1'b0}};
      qk_last_o <= 1'b0;
      softmax_done_o <= 1'b0;
      softmax_busy_o <= 1'b0;
      pv_ready_o <= 1'b0;
      pv_done_o <= 1'b0;
      row_valid_o <= 1'b0;
      error_o <= 1'b0;
    end else begin
      qk_last_o <= qk_tail_last_w;
      softmax_done_o <= 1'b0;
      pv_ready_o <= pv_start_i;
      pv_done_o <= 1'b0;

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
            if (ROWS != COLS) begin
              error_o <= 1'b1;
            end else begin
              softmax_busy_o <= 1'b1;
              old_l_q <= l_rows_q;
              old_row_state_valid_q <= row_state_valid_q;
              if (&max_ready_rows_q)
                softmax_state_q <= SM_ALPHA_LAUNCH;
              else
                softmax_state_q <= SM_MAX_WAIT;
            end
          end
        end
        SM_MAX_WAIT: begin
          if (&max_ready_rows_q) begin
            softmax_state_q <= SM_ALPHA_LAUNCH;
          end
        end
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
          if (prob_write_valid_w)
            prob_receive_row_q <= prob_receive_row_q + 1'b1;
        end
        SM_PROB_DRAIN: begin
          if (prob_write_valid_w) begin
            if (prob_receive_row_q == ROW_LAST)
              softmax_state_q <= SM_SUM_START;
            else
              prob_receive_row_q <= prob_receive_row_q + 1'b1;
          end
        end
        SM_SUM_START: softmax_state_q <= SM_SUM_WAIT;
        SM_SUM_WAIT: begin
          if (&sum_right_valid_w) softmax_state_q <= SM_L_UPDATE;
        end
        SM_L_UPDATE: begin
          for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
            l_product_w =
                { {PROB_W{1'b0}}, old_l_q[row_idx*LSE_W +: LSE_W] } *
                alpha_rows_q[row_idx*PROB_W +: PROB_W];
            l_total_w = {1'b0, (l_product_w >> `ATTN_BETA_FRAC)} +
                        {{(L_PRODUCT_W+1-LSE_W){1'b0}},
                         sum_right_data_w[row_idx*LSE_W +: LSE_W]};
            if (|l_total_w[L_PRODUCT_W:LSE_W])
              l_rows_q[row_idx*LSE_W +: LSE_W] <= {LSE_W{1'b1}};
            else
              l_rows_q[row_idx*LSE_W +: LSE_W] <= l_total_w[LSE_W-1:0];
            if (row_has_valid_w[row_idx]) row_state_valid_q[row_idx] <= 1'b1;
          end
          softmax_state_q <= SM_DONE;
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
        row_valid_o <= 1'b0;
        row_index_o <= {ROW_IDX_W{1'b0}};
      end else if (stream_active_q) begin
        if (!row_valid_o) begin
          row_valid_o <= 1'b1;
        end else if (row_ready_i) begin
          if (row_index_o == ROW_LAST) begin
            row_valid_o <= 1'b0;
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

endmodule
