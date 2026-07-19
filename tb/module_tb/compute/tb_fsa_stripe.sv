`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"

module tb_fsa_stripe;
  `TB_FSDB_DUMP("tb_fsa_stripe.fsdb", tb_fsa_stripe)

  localparam STRIPE_ROWS = 2;
  localparam COLS = 2;
  localparam DATA_W = 16;
  localparam SCORE_W = 32;
  localparam PROB_W = 16;
  localparam SUM_W = 32;

  reg clk = 1'b0;
  reg rst_n = 1'b0;
  reg clear_i = 1'b0;
  reg clear_score_i = 1'b0;
  reg ws_pv_i = 1'b0;
  reg [STRIPE_ROWS*DATA_W-1:0] q_rows_i = 0;
  reg [STRIPE_ROWS-1:0] q_valid_i = 0;
  reg [STRIPE_ROWS-1:0] q_last_i = 0;
  wire [STRIPE_ROWS-1:0] q_tail_valid_o;
  wire [STRIPE_ROWS-1:0] q_tail_last_o;
  reg [COLS*DATA_W-1:0] k_top_data_i = 0;
  reg [COLS-1:0] k_top_valid_i = 0;
  reg [COLS-1:0] k_top_last_i = 0;
  wire [COLS*DATA_W-1:0] k_bottom_data_o;
  wire [COLS-1:0] k_bottom_valid_o;
  wire [COLS-1:0] k_bottom_last_o;
  reg [STRIPE_ROWS*COLS-1:0] lane_valid_i = {STRIPE_ROWS*COLS{1'b1}};
  wire [STRIPE_ROWS-1:0] max_done_valid_o;
  wire [STRIPE_ROWS*SCORE_W-1:0] max_done_data_o;
  reg [STRIPE_ROWS-1:0] m_start_valid_i = 0;
  reg [STRIPE_ROWS*SCORE_W-1:0] m_start_data_i = 0;
  wire [STRIPE_ROWS-1:0] m_done_valid_o;
  reg [STRIPE_ROWS-1:0] sum_start_valid_i = 0;
  wire [STRIPE_ROWS-1:0] sum_done_valid_o;
  wire [STRIPE_ROWS*SUM_W-1:0] sum_done_data_o;
  reg prob_col_load_valid_i = 1'b0;
  reg prob_col_load_col_i = 1'b0;
  reg [STRIPE_ROWS*PROB_W-1:0] prob_col_load_data_i = 0;
  reg pv_row_load_valid_i = 1'b0;
  reg pv_row_load_row_i = 1'b0;
  reg pv_row_load_half_i = 1'b0;
  reg [COLS*SUM_W-1:0] pv_row_load_data_i = 0;
  reg pv_issue_valid_i = 1'b0;
  reg pv_issue_half_i = 1'b0;
  reg pv_seed_zero_i = 1'b0;
  wire [STRIPE_ROWS*SUM_W-1:0] pv_seed_rows_o;
  reg [STRIPE_ROWS-1:0] pv_sum_valid_i = 0;
  reg [STRIPE_ROWS-1:0] pv_sum_last_i = 0;
  reg [STRIPE_ROWS*SUM_W-1:0] pv_sum_data_i = 0;
  wire pv_row_valid_o;
  wire pv_row_index_o;
  wire pv_row_half_o;
  wire [COLS*SUM_W-1:0] pv_row_data_o;
  wire delta_col_valid_o;
  wire delta_col_index_o;
  wire [STRIPE_ROWS*SCORE_W-1:0] delta_col_data_o;
  wire tail_mac_last_o;
  integer errors = 0;

  fsa_stripe #(
    .STRIPE_ROWS(STRIPE_ROWS), .COLS(COLS), .DATA_W(DATA_W),
    .SCORE_W(SCORE_W), .PROB_W(PROB_W), .SUM_W(SUM_W)
  ) dut (.*);

  always #5 clk = ~clk;
  `TB_TIMEOUT(120, "tb_fsa_stripe")

  initial begin
    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    @(negedge clk);
    pv_row_load_row_i = 1'b1;
    pv_row_load_half_i = 1'b0;
    pv_row_load_data_i = {32'd22, 32'd11};
    pv_row_load_valid_i = 1'b1;
    @(negedge clk);
    pv_row_load_valid_i = 1'b0;
    #1;
    `TB_CHECK(pv_seed_rows_o[SUM_W +: SUM_W] == 32'd11,
              "row-local old-O seed load")

    ws_pv_i = 1'b1;
    pv_issue_half_i = 1'b0;
    pv_issue_valid_i = 1'b1;
    @(posedge clk); #1;
    pv_issue_valid_i = 1'b0;
    `TB_CHECK(pv_seed_rows_o[SUM_W +: SUM_W] == 32'd22,
              "row-local seed advances by feature")

    @(negedge clk);
    ws_pv_i = 1'b0;
    prob_col_load_col_i = 1'b0;
    prob_col_load_data_i = {16'd0, 16'd7};
    prob_col_load_valid_i = 1'b1;
    @(negedge clk);
    prob_col_load_col_i = 1'b1;
    prob_col_load_data_i = {16'd0, 16'd9};
    @(negedge clk);
    prob_col_load_valid_i = 1'b0;
    sum_start_valid_i = 2'b01;
    @(negedge clk);
    sum_start_valid_i = 2'b00;
    @(posedge clk); #1;
    `TB_CHECK(sum_done_valid_o[0] && sum_done_data_o[SUM_W-1:0] == 32'd16,
              "softmax rowsum remains intact")

    `TB_FINISH("tb_fsa_stripe")
  end
endmodule
