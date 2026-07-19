`timescale 1ns/1ps

(* keep_hierarchy = "yes" *) module os_fsa_stripe #(
  parameter integer STRIPE_ROWS = 8,
  parameter integer COLS = 32,
  parameter integer DATA_W = 16,
  parameter integer SCORE_W = 32,
  parameter integer PROB_W = 16,
  parameter integer ACC_W = 32,
  parameter integer SUM_W = 32,
  parameter integer LOCAL_ROW_IDX_W = (STRIPE_ROWS < 2) ? 1 : $clog2(STRIPE_ROWS)
)(
  input                                  clk,
  input                                  rst_n,
  input                                  clear_i,
  input                                  clear_score_i,
  input                                  clear_acc_i,
  input                                  mac_is_pv_i,

  input      [STRIPE_ROWS*DATA_W-1:0]    q_rows_i,
  input      [STRIPE_ROWS-1:0]           q_valid_i,
  input      [STRIPE_ROWS-1:0]           q_last_i,
  output     [STRIPE_ROWS-1:0]           q_tail_valid_o,
  output     [STRIPE_ROWS-1:0]           q_tail_last_o,

  input      [COLS*DATA_W-1:0]           k_top_data_i,
  input      [COLS-1:0]                  k_top_valid_i,
  input      [COLS-1:0]                  k_top_last_i,
  output     [COLS*DATA_W-1:0]           k_bottom_data_o,
  output     [COLS-1:0]                  k_bottom_valid_o,
  output     [COLS-1:0]                  k_bottom_last_o,

  input      [STRIPE_ROWS*COLS-1:0]      lane_valid_i,

  output     [STRIPE_ROWS-1:0]           max_done_valid_o,
  output     [STRIPE_ROWS*SCORE_W-1:0]   max_done_data_o,

  input      [STRIPE_ROWS-1:0]           m_start_valid_i,
  input      [STRIPE_ROWS*SCORE_W-1:0]   m_start_data_i,
  output     [STRIPE_ROWS-1:0]           m_done_valid_o,

  input      [STRIPE_ROWS-1:0]           sum_start_valid_i,
  output     [STRIPE_ROWS-1:0]           sum_done_valid_o,
  output     [STRIPE_ROWS*SUM_W-1:0]     sum_done_data_o,

  input                                  prob_load_valid_i,
  input      [LOCAL_ROW_IDX_W-1:0]       prob_load_row_i,
  input      [COLS*PROB_W-1:0]           prob_load_data_i,
  input                                  prob_shift_load_i,
  input                                  prob_shift_en_i,
  output     [STRIPE_ROWS*PROB_W-1:0]    prob_left_rows_o,

  input                                  acc_load_valid_i,
  input      [LOCAL_ROW_IDX_W-1:0]       acc_load_row_i,
  input      [COLS*ACC_W-1:0]            acc_load_data_i,

  input                                  delta_read_req_i,
  input      [LOCAL_ROW_IDX_W-1:0]       delta_read_row_i,
  output reg                             delta_read_valid_o,
  output reg [COLS*SCORE_W-1:0]          delta_read_data_o,

  input                                  acc_read_req_i,
  input      [LOCAL_ROW_IDX_W-1:0]       acc_read_row_i,
  output reg                             acc_read_valid_o,
  output reg [COLS*ACC_W-1:0]            acc_read_data_o,

  output                                 tail_mac_last_o
);

  wire [DATA_W-1:0] q_data_w [0:STRIPE_ROWS-1][0:COLS];
  wire q_valid_w [0:STRIPE_ROWS-1][0:COLS];
  wire q_last_w [0:STRIPE_ROWS-1][0:COLS];
  wire [DATA_W-1:0] k_data_w [0:STRIPE_ROWS][0:COLS-1];
  wire k_valid_w [0:STRIPE_ROWS][0:COLS-1];
  wire k_last_w [0:STRIPE_ROWS][0:COLS-1];
  wire [SCORE_W-1:0] max_data_w [0:STRIPE_ROWS-1][0:COLS];
  wire max_valid_w [0:STRIPE_ROWS-1][0:COLS];
  wire [SCORE_W-1:0] m_data_w [0:STRIPE_ROWS-1][0:COLS];
  wire m_valid_w [0:STRIPE_ROWS-1][0:COLS];
  wire [SUM_W-1:0] sum_data_w [0:STRIPE_ROWS-1][0:COLS];
  wire sum_valid_w [0:STRIPE_ROWS-1][0:COLS];
  wire [SCORE_W-1:0] delta_w [0:STRIPE_ROWS-1][0:COLS-1];
  wire [PROB_W-1:0] prob_shift_w [0:STRIPE_ROWS-1][0:COLS-1];
  wire [ACC_W-1:0] acc_w [0:STRIPE_ROWS-1][0:COLS-1];
  wire pe_last_w [0:STRIPE_ROWS-1][0:COLS-1];

  reg [COLS*SCORE_W-1:0] delta_read_mux_w;
  reg [COLS*ACC_W-1:0] acc_read_mux_w;
  integer read_col;

  generate
    genvar boundary_row;
    for (boundary_row = 0; boundary_row < STRIPE_ROWS; boundary_row = boundary_row + 1) begin : g_q_boundary
      assign q_data_w[boundary_row][0] = q_rows_i[boundary_row*DATA_W +: DATA_W];
      assign q_valid_w[boundary_row][0] = q_valid_i[boundary_row];
      assign q_last_w[boundary_row][0] = q_last_i[boundary_row];
      assign q_tail_valid_o[boundary_row] = q_valid_w[boundary_row][COLS];
      assign q_tail_last_o[boundary_row] = q_last_w[boundary_row][COLS];
    end

    genvar boundary_col;
    for (boundary_col = 0; boundary_col < COLS; boundary_col = boundary_col + 1) begin : g_k_boundary
      assign k_data_w[0][boundary_col] = k_top_data_i[boundary_col*DATA_W +: DATA_W];
      assign k_valid_w[0][boundary_col] = k_top_valid_i[boundary_col];
      assign k_last_w[0][boundary_col] = k_top_last_i[boundary_col];
      assign k_bottom_data_o[boundary_col*DATA_W +: DATA_W] =
          k_data_w[STRIPE_ROWS][boundary_col];
      assign k_bottom_valid_o[boundary_col] = k_valid_w[STRIPE_ROWS][boundary_col];
      assign k_bottom_last_o[boundary_col] = k_last_w[STRIPE_ROWS][boundary_col];
    end

    genvar reduce_row;
    for (reduce_row = 0; reduce_row < STRIPE_ROWS; reduce_row = reduce_row + 1) begin : g_reduce_boundary
      assign max_valid_w[reduce_row][0] = pe_last_w[reduce_row][0] && !mac_is_pv_i;
      assign max_data_w[reduce_row][0] = {1'b1, {(SCORE_W-1){1'b0}}};
      assign max_done_valid_o[reduce_row] = max_valid_w[reduce_row][COLS];
      assign max_done_data_o[reduce_row*SCORE_W +: SCORE_W] = max_data_w[reduce_row][COLS];

      assign m_valid_w[reduce_row][COLS] = m_start_valid_i[reduce_row];
      assign m_data_w[reduce_row][COLS] = m_start_data_i[reduce_row*SCORE_W +: SCORE_W];
      assign m_done_valid_o[reduce_row] = m_valid_w[reduce_row][0];

      assign sum_valid_w[reduce_row][0] = sum_start_valid_i[reduce_row];
      assign sum_data_w[reduce_row][0] = {SUM_W{1'b0}};
      assign sum_done_valid_o[reduce_row] = sum_valid_w[reduce_row][COLS];
      assign sum_done_data_o[reduce_row*SUM_W +: SUM_W] = sum_data_w[reduce_row][COLS];
      assign prob_left_rows_o[reduce_row*PROB_W +: PROB_W] = prob_shift_w[reduce_row][0];
    end

    genvar pe_row;
    genvar pe_col;
    for (pe_row = 0; pe_row < STRIPE_ROWS; pe_row = pe_row + 1) begin : g_pe_row
      for (pe_col = 0; pe_col < COLS; pe_col = pe_col + 1) begin : g_pe_col
        wire [PROB_W-1:0] prob_from_right_w;
        if (pe_col == COLS-1) begin : g_prob_edge
          assign prob_from_right_w = {PROB_W{1'b0}};
        end else begin : g_prob_neighbor
          assign prob_from_right_w = prob_shift_w[pe_row][pe_col+1];
        end

        os_fsa_fused_pe #(
          .DATA_W(DATA_W), .SCORE_W(SCORE_W), .PROB_W(PROB_W),
          .ACC_W(ACC_W), .SUM_W(SUM_W)
        ) u_pe (
          .clk(clk), .rst_n(rst_n), .clear_i(clear_i),
          .clear_score_i(clear_score_i), .clear_acc_i(clear_acc_i),
          .load_acc_i(acc_load_valid_i && acc_load_row_i == pe_row),
          .load_acc_data_i(acc_load_data_i[pe_col*ACC_W +: ACC_W]),
          .mac_is_pv_i(mac_is_pv_i),
          .q_valid_i(q_valid_w[pe_row][pe_col]),
          .q_last_i(q_last_w[pe_row][pe_col]),
          .q_data_i(q_data_w[pe_row][pe_col]),
          .q_valid_o(q_valid_w[pe_row][pe_col+1]),
          .q_last_o(q_last_w[pe_row][pe_col+1]),
          .q_data_o(q_data_w[pe_row][pe_col+1]),
          .k_valid_i(k_valid_w[pe_row][pe_col]),
          .k_last_i(k_last_w[pe_row][pe_col]),
          .k_data_i(k_data_w[pe_row][pe_col]),
          .k_valid_o(k_valid_w[pe_row+1][pe_col]),
          .k_last_o(k_last_w[pe_row+1][pe_col]),
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
          .prob_load_i(prob_load_valid_i && prob_load_row_i == pe_row),
          .prob_data_i(prob_load_data_i[pe_col*PROB_W +: PROB_W]),
          .prob_o(),
          .prob_shift_load_i(prob_shift_load_i),
          .prob_shift_en_i(prob_shift_en_i),
          .prob_shift_i(prob_from_right_w),
          .prob_shift_o(prob_shift_w[pe_row][pe_col]),
          .sum_valid_i(sum_valid_w[pe_row][pe_col]),
          .sum_data_i(sum_data_w[pe_row][pe_col]),
          .sum_valid_o(sum_valid_w[pe_row][pe_col+1]),
          .sum_data_o(sum_data_w[pe_row][pe_col+1]),
          .mac_valid_o(), .mac_last_o(pe_last_w[pe_row][pe_col]),
          .acc_o(acc_w[pe_row][pe_col])
        );
      end
    end
  endgenerate

  assign tail_mac_last_o = pe_last_w[STRIPE_ROWS-1][COLS-1];

  always @(*) begin
    delta_read_mux_w = {COLS*SCORE_W{1'b0}};
    acc_read_mux_w = {COLS*ACC_W{1'b0}};
    for (read_col = 0; read_col < COLS; read_col = read_col + 1) begin
      delta_read_mux_w[read_col*SCORE_W +: SCORE_W] = delta_w[delta_read_row_i][read_col];
      acc_read_mux_w[read_col*ACC_W +: ACC_W] = acc_w[acc_read_row_i][read_col];
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      delta_read_valid_o <= 1'b0;
      delta_read_data_o <= {COLS*SCORE_W{1'b0}};
      acc_read_valid_o <= 1'b0;
      acc_read_data_o <= {COLS*ACC_W{1'b0}};
    end else if (clear_i) begin
      delta_read_valid_o <= 1'b0;
      acc_read_valid_o <= 1'b0;
    end else begin
      delta_read_valid_o <= delta_read_req_i;
      acc_read_valid_o <= acc_read_req_i;
      if (delta_read_req_i) delta_read_data_o <= delta_read_mux_w;
      if (acc_read_req_i) acc_read_data_o <= acc_read_mux_w;
    end
  end

endmodule
