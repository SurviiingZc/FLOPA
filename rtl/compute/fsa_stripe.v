`timescale 1ns/1ps
`include "attention_defines.vh"
`include "fixed_defs.vh"

// Physical 8-row slice of the 32-column fused array. Stripe boundaries keep
// routing bounded and place a persistent feature-addressed O bank near its PEs.
(* keep_hierarchy = "yes" *) module fsa_stripe #(
  parameter integer STRIPE_ROWS = 8,
  parameter integer COLS = 32,
  parameter integer HEAD_DIM = 64,
  parameter integer DATA_W = `ATTN_ARRAY_DATA_W,
  parameter integer SCORE_W = 32,
  parameter integer PROB_W = 16,
  parameter integer SUM_W = 32,
  parameter integer TAG_W = (HEAD_DIM < 2) ? 1 : $clog2(HEAD_DIM),
  parameter integer LOCAL_ROW_IDX_W = (STRIPE_ROWS < 2) ? 1 : $clog2(STRIPE_ROWS)
)(
  input                                  clk,
  input                                  rst_n,
  input                                  clear_i,
  input                                  clear_score_i,
  input                                  ws_pv_i,

  input      [STRIPE_ROWS*DATA_W-1:0]    q_rows_i,
  input      [STRIPE_ROWS-1:0]           q_valid_i,
  input      [STRIPE_ROWS-1:0]           qk_row_done_i,

  input      [COLS*DATA_W-1:0]           k_top_data_i,
  input      [COLS-1:0]                  k_top_valid_i,
  output     [COLS*DATA_W-1:0]           k_bottom_data_o,
  output     [COLS-1:0]                  k_bottom_valid_o,

  input      [STRIPE_ROWS*COLS-1:0]      lane_valid_i,
  output     [STRIPE_ROWS-1:0]           max_done_valid_o,
  output     [STRIPE_ROWS*SCORE_W-1:0]   max_done_data_o,
  input      [STRIPE_ROWS-1:0]           m_start_valid_i,
  input      [STRIPE_ROWS*SCORE_W-1:0]   m_start_data_i,

  input      [STRIPE_ROWS-1:0]           sum_start_valid_i,
  output     [STRIPE_ROWS-1:0]           sum_done_valid_o,
  output     [STRIPE_ROWS*SUM_W-1:0]     sum_done_data_o,
  output     [STRIPE_ROWS*TAG_W-1:0]     sum_done_tag_o,

  input                                  prob_col_load_valid_i,
  input      [((COLS < 2) ? 1 : $clog2(COLS))-1:0] prob_col_load_col_i,
  input      [STRIPE_ROWS*PROB_W-1:0]    prob_col_load_data_i,

  input      [STRIPE_ROWS-1:0]           pv_sum_valid_i,
  input      [STRIPE_ROWS*SUM_W-1:0]     pv_sum_data_i,
  input      [STRIPE_ROWS*TAG_W-1:0]     pv_sum_tag_i,

  input                                  pv_seed_operand_valid_i,
  input                                  pv_seed_zero_i,
  input      [STRIPE_ROWS*PROB_W-1:0]    pv_seed_alpha_i,
  input      [TAG_W-1:0]                 pv_seed_feature_i,
  output reg                             pv_seed_valid_o,
  output     [STRIPE_ROWS*SUM_W-1:0]     pv_seed_data_o,
  output reg [TAG_W-1:0]                 pv_seed_feature_o,

  input                                  o_rd_en_i,
  input      [TAG_W-1:0]                 o_rd_feature_i,
  output                                 o_rd_valid_o,
  output     [STRIPE_ROWS*SUM_W-1:0]     o_rd_data_o,

  output reg                             delta_col_valid_o,
  output reg [((COLS < 2) ? 1 : $clog2(COLS))-1:0] delta_col_index_o,
  output reg [STRIPE_ROWS*SCORE_W-1:0]   delta_col_data_o
);

  localparam integer COL_IDX_W = (COLS < 2) ? 1 : $clog2(COLS);
  localparam integer DELTA_GROUP_SIZE = 8;
  localparam integer DELTA_GROUPS = (COLS + DELTA_GROUP_SIZE - 1) /
                                    DELTA_GROUP_SIZE;
  localparam integer RESCALE_PRODUCT_W = SUM_W + PROB_W + 1;

  wire [DATA_W-1:0] q_data_w [0:STRIPE_ROWS-1][0:COLS];
  wire q_valid_w [0:STRIPE_ROWS-1][0:COLS];
  wire [DATA_W-1:0] k_data_w [0:STRIPE_ROWS][0:COLS-1];
  wire k_valid_w [0:STRIPE_ROWS][0:COLS-1];
  wire [SCORE_W-1:0] max_data_w [0:STRIPE_ROWS-1][0:COLS];
  wire max_valid_w [0:STRIPE_ROWS-1][0:COLS];
  wire [SCORE_W-1:0] m_data_w [0:STRIPE_ROWS-1][0:COLS];
  wire m_valid_w [0:STRIPE_ROWS-1][0:COLS];
  wire [SUM_W-1:0] sum_forward_data_w [0:STRIPE_ROWS-1][0:COLS];
  wire sum_forward_valid_w [0:STRIPE_ROWS-1][0:COLS];
  wire [TAG_W-1:0] sum_forward_tag_w [0:STRIPE_ROWS-1][0:COLS];
  wire [SUM_W-1:0] sum_reverse_data_w [0:STRIPE_ROWS-1][0:COLS];
  wire sum_reverse_valid_w [0:STRIPE_ROWS-1][0:COLS];
  wire [TAG_W-1:0] sum_reverse_tag_w [0:STRIPE_ROWS-1][0:COLS];
  wire [SUM_W-1:0] pe_sum_data_w [0:STRIPE_ROWS-1][0:COLS-1];
  wire pe_sum_valid_w [0:STRIPE_ROWS-1][0:COLS-1];
  wire [TAG_W-1:0] pe_sum_tag_w [0:STRIPE_ROWS-1][0:COLS-1];
  wire [SCORE_W-1:0] delta_w [0:STRIPE_ROWS-1][0:COLS-1];
  wire [COLS-1:0] prob_col_select_w;
  wire [STRIPE_ROWS-1:0] o_wr_valid_w;
  wire [STRIPE_ROWS*TAG_W-1:0] o_wr_feature_w;
  wire [STRIPE_ROWS*SUM_W-1:0] o_wr_data_w;
  reg [STRIPE_ROWS*SUM_W-1:0] pv_seed_o_q;
  reg [STRIPE_ROWS*PROB_W-1:0] pv_seed_alpha_q;
  wire signed [RESCALE_PRODUCT_W-1:0] pv_rescale_product_w
      [0:STRIPE_ROWS-1];
  wire signed [RESCALE_PRODUCT_W-1:0] pv_rescale_shifted_w
      [0:STRIPE_ROWS-1];

  reg ws_pv_q;
  reg [DELTA_GROUPS-1:0] delta_group_valid_w;
  reg [DELTA_GROUPS*COL_IDX_W-1:0] delta_group_index_w;
  reg [DELTA_GROUPS*STRIPE_ROWS*SCORE_W-1:0] delta_group_data_w;
  reg [DELTA_GROUPS-1:0] delta_group_valid_q;
  reg [DELTA_GROUPS*COL_IDX_W-1:0] delta_group_index_q;
  reg [DELTA_GROUPS*STRIPE_ROWS*SCORE_W-1:0] delta_group_data_q;
  reg delta_group_mux_valid_w;
  reg [COL_IDX_W-1:0] delta_group_mux_index_w;
  reg [STRIPE_ROWS*SCORE_W-1:0] delta_group_mux_data_w;
  integer delta_group;
  integer delta_group_col;
  integer delta_row;

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n && pv_seed_operand_valid_i && !pv_seed_zero_i && !o_rd_valid_o)
      $fatal(1, "fsa_stripe O-seed operand arrived without SRAM read response");
`endif

  // Decode the global probability column tag once per stripe; each one-hot bit
  // drives only eight local PEs instead of broadcasting a binary select globally.
  assign prob_col_select_w = prob_col_load_valid_i ?
      ({{(COLS-1){1'b0}}, 1'b1} << prob_col_load_col_i) : {COLS{1'b0}};

  // Wire nearest-neighbor systolic boundaries and the bidirectional row-reduction
  // links. No full score or probability tile crosses the stripe interface.
  generate
    genvar boundary_row;
    for (boundary_row = 0; boundary_row < STRIPE_ROWS;
         boundary_row = boundary_row + 1) begin : g_q_boundary
      assign q_data_w[boundary_row][0] =
          q_rows_i[boundary_row*DATA_W +: DATA_W];
      assign q_valid_w[boundary_row][0] = q_valid_i[boundary_row];
    end

    genvar boundary_col;
    for (boundary_col = 0; boundary_col < COLS;
         boundary_col = boundary_col + 1) begin : g_k_boundary
      assign k_data_w[0][boundary_col] =
          k_top_data_i[boundary_col*DATA_W +: DATA_W];
      assign k_valid_w[0][boundary_col] = k_top_valid_i[boundary_col];
      assign k_bottom_data_o[boundary_col*DATA_W +: DATA_W] =
          k_data_w[STRIPE_ROWS][boundary_col];
      assign k_bottom_valid_o[boundary_col] =
          k_valid_w[STRIPE_ROWS][boundary_col];
    end

    genvar reduce_row;
    for (reduce_row = 0; reduce_row < STRIPE_ROWS;
         reduce_row = reduce_row + 1) begin : g_reduce_boundary
      assign max_valid_w[reduce_row][0] = qk_row_done_i[reduce_row];
      assign max_data_w[reduce_row][0] = {1'b1, {(SCORE_W-1){1'b0}}};
      assign max_done_valid_o[reduce_row] = max_valid_w[reduce_row][COLS];
      assign max_done_data_o[reduce_row*SCORE_W +: SCORE_W] =
          max_data_w[reduce_row][COLS];
      assign m_valid_w[reduce_row][COLS] = m_start_valid_i[reduce_row];
      assign m_data_w[reduce_row][COLS] =
          m_start_data_i[reduce_row*SCORE_W +: SCORE_W];
      assign sum_forward_valid_w[reduce_row][0] = pv_sum_valid_i[reduce_row];
      assign sum_forward_data_w[reduce_row][0] =
          pv_sum_data_i[reduce_row*SUM_W +: SUM_W];
      assign sum_forward_tag_w[reduce_row][0] =
          pv_sum_tag_i[reduce_row*TAG_W +: TAG_W];
      assign sum_reverse_valid_w[reduce_row][COLS] =
          sum_start_valid_i[reduce_row];
      assign sum_reverse_data_w[reduce_row][COLS] = {SUM_W{1'b0}};
      assign sum_reverse_tag_w[reduce_row][COLS] = {TAG_W{1'b0}};
      assign sum_done_valid_o[reduce_row] = ws_pv_q ?
          sum_forward_valid_w[reduce_row][COLS] :
          sum_reverse_valid_w[reduce_row][0];
      assign sum_done_data_o[reduce_row*SUM_W +: SUM_W] = ws_pv_q ?
          sum_forward_data_w[reduce_row][COLS] :
          sum_reverse_data_w[reduce_row][0];
      assign sum_done_tag_o[reduce_row*TAG_W +: TAG_W] = ws_pv_q ?
          sum_forward_tag_w[reduce_row][COLS] :
          sum_reverse_tag_w[reduce_row][0];
      // WS-PV right-edge results carry their original feature tag. Each row uses
      // that tag directly as its O-bank write address, so no row deskew is needed.
      assign o_wr_valid_w[reduce_row] = ws_pv_q &&
          sum_forward_valid_w[reduce_row][COLS];
      assign o_wr_feature_w[reduce_row*TAG_W +: TAG_W] =
          sum_forward_tag_w[reduce_row][COLS];
      assign o_wr_data_w[reduce_row*SUM_W +: SUM_W] =
          sum_forward_data_w[reduce_row][COLS];
    end

    genvar pe_row;
    genvar pe_col;
    for (pe_row = 0; pe_row < STRIPE_ROWS; pe_row = pe_row + 1) begin : g_pe_row
      for (pe_col = 0; pe_col < COLS; pe_col = pe_col + 1) begin : g_pe_col
        fsa_fused_pe #(
          .DATA_W(DATA_W), .SCORE_W(SCORE_W), .PROB_W(PROB_W),
          .SUM_W(SUM_W), .TAG_W(TAG_W)
        ) u_pe (
          .clk(clk), .rst_n(rst_n), .clear_i(clear_i),
          .clear_score_i(clear_score_i),
          .q_valid_i(q_valid_w[pe_row][pe_col]),
          .q_data_i(q_data_w[pe_row][pe_col]),
          .q_valid_o(q_valid_w[pe_row][pe_col+1]),
          .q_data_o(q_data_w[pe_row][pe_col+1]),
          .k_valid_i(k_valid_w[pe_row][pe_col]),
          .k_data_i(k_data_w[pe_row][pe_col]),
          .k_valid_o(k_valid_w[pe_row+1][pe_col]),
          .k_data_o(k_data_w[pe_row+1][pe_col]),
          .score_lane_valid_i(lane_valid_i[pe_row*COLS+pe_col]),
          .max_valid_i(max_valid_w[pe_row][pe_col]),
          .max_data_i(max_data_w[pe_row][pe_col]),
          .max_valid_o(max_valid_w[pe_row][pe_col+1]),
          .max_data_o(max_data_w[pe_row][pe_col+1]),
          .m_valid_i(m_valid_w[pe_row][pe_col+1]),
          .m_data_i(m_data_w[pe_row][pe_col+1]),
          .m_valid_o(m_valid_w[pe_row][pe_col]),
          .m_data_o(m_data_w[pe_row][pe_col]),
          .delta_o(delta_w[pe_row][pe_col]),
          .prob_load_i(prob_col_select_w[pe_col]),
          .prob_data_i(prob_col_load_data_i[pe_row*PROB_W +: PROB_W]),
          .pv_mac_valid_i(ws_pv_q &&
                          sum_forward_valid_w[pe_row][pe_col] &&
                          k_valid_w[pe_row][pe_col]),
          .sum_valid_i(ws_pv_q ?
              (sum_forward_valid_w[pe_row][pe_col] &&
               k_valid_w[pe_row][pe_col]) :
              sum_reverse_valid_w[pe_row][pe_col+1]),
          .sum_data_i(ws_pv_q ? sum_forward_data_w[pe_row][pe_col] :
                                sum_reverse_data_w[pe_row][pe_col+1]),
          .sum_tag_i(ws_pv_q ? sum_forward_tag_w[pe_row][pe_col] :
                               sum_reverse_tag_w[pe_row][pe_col+1]),
          .sum_valid_o(pe_sum_valid_w[pe_row][pe_col]),
          .sum_data_o(pe_sum_data_w[pe_row][pe_col]),
          .sum_tag_o(pe_sum_tag_w[pe_row][pe_col])
        );
        assign sum_forward_valid_w[pe_row][pe_col+1] =
            pe_sum_valid_w[pe_row][pe_col];
        assign sum_forward_data_w[pe_row][pe_col+1] =
            pe_sum_data_w[pe_row][pe_col];
        assign sum_forward_tag_w[pe_row][pe_col+1] =
            pe_sum_tag_w[pe_row][pe_col];
        assign sum_reverse_valid_w[pe_row][pe_col] =
            pe_sum_valid_w[pe_row][pe_col];
        assign sum_reverse_data_w[pe_row][pe_col] =
            pe_sum_data_w[pe_row][pe_col];
        assign sum_reverse_tag_w[pe_row][pe_col] =
            pe_sum_tag_w[pe_row][pe_col];
      end
    end
  endgenerate

  // Persistent O survives between KV tiles for the current Q tile. Reads seed
  // the next WS-PV pass; tagged writes update O_new in place.
  o_accumulator_bank #(
    .ROWS(STRIPE_ROWS), .HEAD_DIM(HEAD_DIM), .GROUP_SIZE(COLS),
    .DATA_W(SUM_W), .FEATURE_IDX_W(TAG_W)
  ) u_o_bank (
    .clk(clk), .rst_n(rst_n), .clear_i(clear_i),
    .rd_en_i(o_rd_en_i), .rd_feature_i(o_rd_feature_i),
    .rd_valid_o(o_rd_valid_o), .rd_data_o(o_rd_data_o),
    .wr_valid_i(o_wr_valid_w), .wr_feature_i(o_wr_feature_w),
    .wr_data_i(o_wr_data_w)
  );

  // Capture the synchronous O SRAM response, alpha, and feature locally before
  // rescaling. This removes SRAM CLK-to-Q from the 32x17 multiplier path. First
  // KV tiles use the same registered stage with an explicit zero O operand.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      pv_seed_valid_o <= 1'b0;
    else if (clear_i)
      pv_seed_valid_o <= 1'b0;
    else
      pv_seed_valid_o <= pv_seed_operand_valid_i &&
                         (pv_seed_zero_i || o_rd_valid_o);
  end

  always @(posedge clk) begin
    if (rst_n && !clear_i && pv_seed_operand_valid_i &&
        (pv_seed_zero_i || o_rd_valid_o)) begin
      pv_seed_o_q <= pv_seed_zero_i ?
          {STRIPE_ROWS*SUM_W{1'b0}} : o_rd_data_o;
      pv_seed_alpha_q <= pv_seed_alpha_i;
      pv_seed_feature_o <= pv_seed_feature_i;
    end
  end

  generate
    genvar seed_row;
    for (seed_row = 0; seed_row < STRIPE_ROWS;
         seed_row = seed_row + 1) begin : g_pv_seed_rescale
      assign pv_rescale_product_w[seed_row] =
          $signed({{(RESCALE_PRODUCT_W-SUM_W){
                       pv_seed_o_q[seed_row*SUM_W+SUM_W-1]}},
                    pv_seed_o_q[seed_row*SUM_W +: SUM_W]}) *
          $signed({1'b0,
                    pv_seed_alpha_q[seed_row*PROB_W +: PROB_W]});
      assign pv_rescale_shifted_w[seed_row] =
          pv_rescale_product_w[seed_row] >>> `ATTN_BETA_FRAC;
      assign pv_seed_data_o[seed_row*SUM_W +: SUM_W] =
          pv_rescale_shifted_w[seed_row][SUM_W-1:0];
    end
  endgenerate

  // First-stage hierarchical delta selection: reduce 32 candidate PE columns to
  // four bounded 8-column groups before the register boundary.
  always @(*) begin
    delta_group_valid_w = {DELTA_GROUPS{1'b0}};
    delta_group_index_w = {DELTA_GROUPS*COL_IDX_W{1'b0}};
    delta_group_data_w = {DELTA_GROUPS*STRIPE_ROWS*SCORE_W{1'b0}};
    for (delta_group = 0; delta_group < DELTA_GROUPS;
         delta_group = delta_group + 1) begin
      for (delta_group_col = 0; delta_group_col < DELTA_GROUP_SIZE;
           delta_group_col = delta_group_col + 1) begin
        if ((delta_group*DELTA_GROUP_SIZE + delta_group_col) < COLS &&
            m_valid_w[0][delta_group*DELTA_GROUP_SIZE + delta_group_col]) begin
          delta_group_valid_w[delta_group] = 1'b1;
          delta_group_index_w[delta_group*COL_IDX_W +: COL_IDX_W] =
              (delta_group[COL_IDX_W-1:0] << 3) +
              delta_group_col[COL_IDX_W-1:0];
          for (delta_row = 0; delta_row < STRIPE_ROWS; delta_row = delta_row + 1)
            delta_group_data_w[
                delta_group*STRIPE_ROWS*SCORE_W + delta_row*SCORE_W +: SCORE_W] =
                delta_w[delta_row][delta_group*DELTA_GROUP_SIZE + delta_group_col];
        end
      end
    end
  end

  // Second-stage mux selects one registered group and emits one full stripe column.
  always @(*) begin
    delta_group_mux_valid_w = 1'b0;
    delta_group_mux_index_w = {COL_IDX_W{1'b0}};
    delta_group_mux_data_w = {STRIPE_ROWS*SCORE_W{1'b0}};
    for (delta_group = 0; delta_group < DELTA_GROUPS;
         delta_group = delta_group + 1) begin
      if (delta_group_valid_q[delta_group]) begin
        delta_group_mux_valid_w = 1'b1;
        delta_group_mux_index_w =
            delta_group_index_q[delta_group*COL_IDX_W +: COL_IDX_W];
        delta_group_mux_data_w = delta_group_data_q[
            delta_group*STRIPE_ROWS*SCORE_W +: STRIPE_ROWS*SCORE_W];
      end
    end
  end

  // Register the local phase to contain fanout and pipeline the hierarchical mux.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ws_pv_q <= 1'b0;
      delta_group_valid_q <= {DELTA_GROUPS{1'b0}};
      delta_col_valid_o <= 1'b0;
    end else if (clear_i) begin
      ws_pv_q <= 1'b0;
      delta_group_valid_q <= {DELTA_GROUPS{1'b0}};
      delta_col_valid_o <= 1'b0;
    end else begin
      if (clear_score_i) ws_pv_q <= 1'b0;
      else ws_pv_q <= ws_pv_i;
      delta_group_valid_q <= delta_group_valid_w;
      delta_group_index_q <= delta_group_index_w;
      delta_group_data_q <= delta_group_data_w;
      delta_col_valid_o <= delta_group_mux_valid_w;
      if (delta_group_mux_valid_w) begin
        delta_col_index_o <= delta_group_mux_index_w;
        delta_col_data_o <= delta_group_mux_data_w;
      end
    end
  end

endmodule
