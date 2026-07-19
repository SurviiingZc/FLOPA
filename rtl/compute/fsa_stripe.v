`timescale 1ns/1ps

(* keep_hierarchy = "yes" *) module fsa_stripe #(
  parameter integer STRIPE_ROWS = 8,
  parameter integer COLS = 32,
  parameter integer DATA_W = 16,
  parameter integer SCORE_W = 32,
  parameter integer PROB_W = 16,
  parameter integer SUM_W = 32,
  parameter integer LOCAL_ROW_IDX_W = (STRIPE_ROWS < 2) ? 1 : $clog2(STRIPE_ROWS)
)(
  input                                  clk,
  input                                  rst_n,
  input                                  clear_i,
  input                                  clear_score_i,
  input                                  ws_pv_i,

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

  input                                  prob_col_load_valid_i,
  input      [((COLS < 2) ? 1 : $clog2(COLS))-1:0] prob_col_load_col_i,
  input      [STRIPE_ROWS*PROB_W-1:0]    prob_col_load_data_i,

  input                                  pv_row_load_valid_i,
  input      [LOCAL_ROW_IDX_W-1:0]       pv_row_load_row_i,
  input                                  pv_row_load_half_i,
  input      [COLS*SUM_W-1:0]            pv_row_load_data_i,
  input                                  pv_issue_valid_i,
  input                                  pv_issue_half_i,
  input                                  pv_seed_zero_i,
  output     [STRIPE_ROWS*SUM_W-1:0]     pv_seed_rows_o,
  input      [STRIPE_ROWS-1:0]           pv_sum_valid_i,
  input      [STRIPE_ROWS-1:0]           pv_sum_last_i,
  input      [STRIPE_ROWS*SUM_W-1:0]     pv_sum_data_i,
  output reg                             pv_row_valid_o,
  output reg [LOCAL_ROW_IDX_W-1:0]       pv_row_index_o,
  output reg                             pv_row_half_o,
  output reg [COLS*SUM_W-1:0]            pv_row_data_o,

  output reg                             delta_col_valid_o,
  output reg [((COLS < 2) ? 1 : $clog2(COLS))-1:0] delta_col_index_o,
  output reg [STRIPE_ROWS*SCORE_W-1:0]   delta_col_data_o,

  output                                 tail_mac_last_o
);

  localparam integer ROW_BUFFER_W = COLS * SUM_W;
  localparam integer COL_IDX_W = (COLS < 2) ? 1 : $clog2(COLS);

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
  wire [SUM_W-1:0] sum_forward_data_w [0:STRIPE_ROWS-1][0:COLS];
  wire sum_forward_valid_w [0:STRIPE_ROWS-1][0:COLS];
  wire sum_forward_last_w [0:STRIPE_ROWS-1][0:COLS];
  wire [SUM_W-1:0] sum_reverse_data_w [0:STRIPE_ROWS-1][0:COLS];
  wire sum_reverse_valid_w [0:STRIPE_ROWS-1][0:COLS];
  wire sum_reverse_last_w [0:STRIPE_ROWS-1][0:COLS];
  wire [SUM_W-1:0] pe_sum_data_w [0:STRIPE_ROWS-1][0:COLS-1];
  wire pe_sum_valid_w [0:STRIPE_ROWS-1][0:COLS-1];
  wire pe_sum_last_w [0:STRIPE_ROWS-1][0:COLS-1];
  wire [SCORE_W-1:0] delta_w [0:STRIPE_ROWS-1][0:COLS-1];
  wire pe_last_w [0:STRIPE_ROWS-1][0:COLS-1];

  reg [ROW_BUFFER_W-1:0] pv_row_buffer0_q [0:STRIPE_ROWS-1];
  reg [ROW_BUFFER_W-1:0] pv_row_buffer1_q [0:STRIPE_ROWS-1];
  reg [STRIPE_ROWS-1:0] pv_collect_half_q;
  reg [STRIPE_ROWS*SCORE_W-1:0] delta_col_mux_w;
  reg [COL_IDX_W-1:0] delta_col_mux_index_w;
  reg delta_col_mux_valid_w;
  integer delta_row;
  integer delta_col;
  integer buffer_row;

  function [LOCAL_ROW_IDX_W-1:0] local_row_index;
    input integer value;
    integer bit_index;
    begin
      for (bit_index = 0; bit_index < LOCAL_ROW_IDX_W;
           bit_index = bit_index + 1)
        local_row_index[bit_index] = value[bit_index];
    end
  endfunction

  generate
    genvar boundary_row;
    for (boundary_row = 0; boundary_row < STRIPE_ROWS; boundary_row = boundary_row + 1) begin : g_q_boundary
      assign q_data_w[boundary_row][0] = q_rows_i[boundary_row*DATA_W +: DATA_W];
      assign q_valid_w[boundary_row][0] = q_valid_i[boundary_row];
      assign q_last_w[boundary_row][0] = q_last_i[boundary_row];
      assign q_tail_valid_o[boundary_row] = q_valid_w[boundary_row][COLS];
      assign q_tail_last_o[boundary_row] = q_last_w[boundary_row][COLS];
      assign pv_seed_rows_o[boundary_row*SUM_W +: SUM_W] = pv_seed_zero_i ?
          {SUM_W{1'b0}} :
          (pv_issue_half_i ?
           pv_row_buffer1_q[boundary_row][SUM_W-1:0] :
           pv_row_buffer0_q[boundary_row][SUM_W-1:0]);
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
      assign max_valid_w[reduce_row][0] = pe_last_w[reduce_row][0] && !ws_pv_i;
      assign max_data_w[reduce_row][0] = {1'b1, {(SCORE_W-1){1'b0}}};
      assign max_done_valid_o[reduce_row] = max_valid_w[reduce_row][COLS];
      assign max_done_data_o[reduce_row*SCORE_W +: SCORE_W] = max_data_w[reduce_row][COLS];

      assign m_valid_w[reduce_row][COLS] = m_start_valid_i[reduce_row];
      assign m_data_w[reduce_row][COLS] = m_start_data_i[reduce_row*SCORE_W +: SCORE_W];
      assign m_done_valid_o[reduce_row] = m_valid_w[reduce_row][0];

      assign sum_forward_valid_w[reduce_row][0] = pv_sum_valid_i[reduce_row];
      assign sum_forward_last_w[reduce_row][0] = pv_sum_last_i[reduce_row];
      assign sum_forward_data_w[reduce_row][0] =
          pv_sum_data_i[reduce_row*SUM_W +: SUM_W];
      assign sum_reverse_valid_w[reduce_row][COLS] = sum_start_valid_i[reduce_row];
      assign sum_reverse_last_w[reduce_row][COLS] = 1'b0;
      assign sum_reverse_data_w[reduce_row][COLS] = {SUM_W{1'b0}};
      assign sum_done_valid_o[reduce_row] = ws_pv_i ?
          sum_forward_valid_w[reduce_row][COLS] :
          sum_reverse_valid_w[reduce_row][0];
      assign sum_done_data_o[reduce_row*SUM_W +: SUM_W] = ws_pv_i ?
          sum_forward_data_w[reduce_row][COLS] :
          sum_reverse_data_w[reduce_row][0];
    end

    genvar pe_row;
    genvar pe_col;
    for (pe_row = 0; pe_row < STRIPE_ROWS; pe_row = pe_row + 1) begin : g_pe_row
      for (pe_col = 0; pe_col < COLS; pe_col = pe_col + 1) begin : g_pe_col
        fsa_fused_pe #(
          .DATA_W(DATA_W), .SCORE_W(SCORE_W), .PROB_W(PROB_W), .SUM_W(SUM_W)
        ) u_pe (
          .clk(clk), .rst_n(rst_n), .clear_i(clear_i),
          .clear_score_i(clear_score_i), .ws_pv_i(ws_pv_i),
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
          .prob_load_i(prob_col_load_valid_i && prob_col_load_col_i == pe_col),
          .prob_data_i(prob_col_load_data_i[pe_row*PROB_W +: PROB_W]),
          .prob_o(),
          .sum_valid_i(ws_pv_i ? sum_forward_valid_w[pe_row][pe_col] :
                                 sum_reverse_valid_w[pe_row][pe_col+1]),
          .sum_last_i(ws_pv_i ? sum_forward_last_w[pe_row][pe_col] :
                                sum_reverse_last_w[pe_row][pe_col+1]),
          .sum_data_i(ws_pv_i ? sum_forward_data_w[pe_row][pe_col] :
                                sum_reverse_data_w[pe_row][pe_col+1]),
          .sum_valid_o(pe_sum_valid_w[pe_row][pe_col]),
          .sum_last_o(pe_sum_last_w[pe_row][pe_col]),
          .sum_data_o(pe_sum_data_w[pe_row][pe_col]),
          .mac_valid_o(), .mac_last_o(pe_last_w[pe_row][pe_col])
        );
        assign sum_forward_valid_w[pe_row][pe_col+1] =
            pe_sum_valid_w[pe_row][pe_col];
        assign sum_forward_last_w[pe_row][pe_col+1] =
            pe_sum_last_w[pe_row][pe_col];
        assign sum_forward_data_w[pe_row][pe_col+1] =
            pe_sum_data_w[pe_row][pe_col];
        assign sum_reverse_valid_w[pe_row][pe_col] =
            pe_sum_valid_w[pe_row][pe_col];
        assign sum_reverse_last_w[pe_row][pe_col] =
            pe_sum_last_w[pe_row][pe_col];
        assign sum_reverse_data_w[pe_row][pe_col] =
            pe_sum_data_w[pe_row][pe_col];
      end
    end
  endgenerate

  assign tail_mac_last_o = pe_last_w[STRIPE_ROWS-1][COLS-1];

  always @(*) begin
    delta_col_mux_valid_w = 1'b0;
    delta_col_mux_index_w = {COL_IDX_W{1'b0}};
    delta_col_mux_w = {STRIPE_ROWS*SCORE_W{1'b0}};
    for (delta_col = 0; delta_col < COLS; delta_col = delta_col + 1) begin
      if (m_valid_w[0][delta_col]) begin
        delta_col_mux_valid_w = 1'b1;
        delta_col_mux_index_w = delta_col[COL_IDX_W-1:0];
        for (delta_row = 0; delta_row < STRIPE_ROWS; delta_row = delta_row + 1)
          delta_col_mux_w[delta_row*SCORE_W +: SCORE_W] =
              delta_w[delta_row][delta_col];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      delta_col_valid_o <= 1'b0;
      delta_col_index_o <= {COL_IDX_W{1'b0}};
      delta_col_data_o <= {STRIPE_ROWS*SCORE_W{1'b0}};
      pv_row_valid_o <= 1'b0;
      pv_row_index_o <= {LOCAL_ROW_IDX_W{1'b0}};
      pv_row_half_o <= 1'b0;
      pv_row_data_o <= {ROW_BUFFER_W{1'b0}};
      pv_collect_half_q <= {STRIPE_ROWS{1'b0}};
      for (buffer_row = 0; buffer_row < STRIPE_ROWS; buffer_row = buffer_row + 1) begin
        pv_row_buffer0_q[buffer_row] <= {ROW_BUFFER_W{1'b0}};
        pv_row_buffer1_q[buffer_row] <= {ROW_BUFFER_W{1'b0}};
      end
    end else if (clear_i) begin
      delta_col_valid_o <= 1'b0;
      pv_row_valid_o <= 1'b0;
      pv_collect_half_q <= {STRIPE_ROWS{1'b0}};
    end else begin
      delta_col_valid_o <= delta_col_mux_valid_w;
      if (delta_col_mux_valid_w) begin
        delta_col_index_o <= delta_col_mux_index_w;
        delta_col_data_o <= delta_col_mux_w;
      end
      pv_row_valid_o <= 1'b0;

      if (clear_score_i)
        pv_collect_half_q <= {STRIPE_ROWS{1'b0}};

      for (buffer_row = 0; buffer_row < STRIPE_ROWS; buffer_row = buffer_row + 1) begin
        if (pv_row_load_valid_i &&
            pv_row_load_row_i == local_row_index(buffer_row)) begin
          if (pv_row_load_half_i)
            pv_row_buffer1_q[buffer_row] <= pv_row_load_data_i;
          else begin
            pv_row_buffer0_q[buffer_row] <= pv_row_load_data_i;
            pv_collect_half_q[buffer_row] <= 1'b0;
          end
        end else begin
          if (ws_pv_i && pv_issue_valid_i) begin
            if (pv_issue_half_i)
              pv_row_buffer1_q[buffer_row] <=
                  {{SUM_W{1'b0}},
                   pv_row_buffer1_q[buffer_row][ROW_BUFFER_W-1:SUM_W]};
            else
              pv_row_buffer0_q[buffer_row] <=
                  {{SUM_W{1'b0}},
                   pv_row_buffer0_q[buffer_row][ROW_BUFFER_W-1:SUM_W]};
          end

          if (ws_pv_i && sum_forward_valid_w[buffer_row][COLS]) begin
            if (pv_collect_half_q[buffer_row])
              pv_row_buffer1_q[buffer_row] <=
                  {sum_forward_data_w[buffer_row][COLS],
                   pv_row_buffer1_q[buffer_row][ROW_BUFFER_W-1:SUM_W]};
            else
              pv_row_buffer0_q[buffer_row] <=
                  {sum_forward_data_w[buffer_row][COLS],
                   pv_row_buffer0_q[buffer_row][ROW_BUFFER_W-1:SUM_W]};

            if (sum_forward_last_w[buffer_row][COLS]) begin
              pv_row_valid_o <= 1'b1;
              pv_row_index_o <= local_row_index(buffer_row);
              pv_row_half_o <= pv_collect_half_q[buffer_row];
              if (pv_collect_half_q[buffer_row])
                pv_row_data_o <=
                    {sum_forward_data_w[buffer_row][COLS],
                     pv_row_buffer1_q[buffer_row][ROW_BUFFER_W-1:SUM_W]};
              else
                pv_row_data_o <=
                    {sum_forward_data_w[buffer_row][COLS],
                     pv_row_buffer0_q[buffer_row][ROW_BUFFER_W-1:SUM_W]};
              pv_collect_half_q[buffer_row] <=
                  ~pv_collect_half_q[buffer_row];
            end
          end
        end
      end
    end
  end

`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (rst_n && ws_pv_i && pv_issue_valid_i) begin
      for (buffer_row = 0; buffer_row < STRIPE_ROWS; buffer_row = buffer_row + 1)
        if (sum_forward_valid_w[buffer_row][COLS] &&
            pv_issue_half_i == pv_collect_half_q[buffer_row])
          $fatal(1, "fsa_stripe seed issue collides with same-half result collection");
    end
  end
`endif

endmodule
