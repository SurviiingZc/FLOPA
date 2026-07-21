`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"
module tb_fsa_stripe;
  `TB_FSDB_DUMP("tb_fsa_stripe.fsdb",tb_fsa_stripe)
  localparam STRIPE_ROWS=2,COLS=2,HEAD_DIM=4,DATA_W=8,SCORE_W=32;
  localparam PROB_W=16,SUM_W=32,TAG_W=2;
  reg clk=0,rst_n=0,clear_i=0,clear_score_i=0,ws_pv_i=0;
  reg [STRIPE_ROWS*DATA_W-1:0] q_rows_i=0; reg [STRIPE_ROWS-1:0] q_valid_i=0,qk_row_done_i=0;
  reg [COLS*DATA_W-1:0] k_top_data_i=0; reg [COLS-1:0] k_top_valid_i=0;
  wire [COLS*DATA_W-1:0] k_bottom_data_o; wire [COLS-1:0] k_bottom_valid_o;
  reg [STRIPE_ROWS*COLS-1:0] lane_valid_i={STRIPE_ROWS*COLS{1'b1}};
  wire [STRIPE_ROWS-1:0] max_done_valid_o; wire [STRIPE_ROWS*SCORE_W-1:0] max_done_data_o;
  reg [STRIPE_ROWS-1:0] m_start_valid_i=0; reg [STRIPE_ROWS*SCORE_W-1:0] m_start_data_i=0;
  reg [STRIPE_ROWS-1:0] sum_start_valid_i=0; wire [STRIPE_ROWS-1:0] sum_done_valid_o;
  wire [STRIPE_ROWS*SUM_W-1:0] sum_done_data_o; wire [STRIPE_ROWS*TAG_W-1:0] sum_done_tag_o;
  reg prob_col_load_valid_i=0; reg prob_col_load_col_i=0;
  reg [STRIPE_ROWS*PROB_W-1:0] prob_col_load_data_i=0;
  reg [STRIPE_ROWS-1:0] pv_sum_valid_i=0;
  reg [STRIPE_ROWS*SUM_W-1:0] pv_sum_data_i=0; reg [STRIPE_ROWS*TAG_W-1:0] pv_sum_tag_i=0;
  reg pv_seed_operand_valid_i=0,pv_seed_zero_i=0;
  reg [STRIPE_ROWS*PROB_W-1:0] pv_seed_alpha_i=0;
  reg [TAG_W-1:0] pv_seed_feature_i=0;
  wire pv_seed_valid_o; wire [STRIPE_ROWS*SUM_W-1:0] pv_seed_data_o;
  wire [TAG_W-1:0] pv_seed_feature_o;
  reg o_rd_en_i=0; reg [TAG_W-1:0] o_rd_feature_i=0; wire o_rd_valid_o;
  wire [STRIPE_ROWS*SUM_W-1:0] o_rd_data_o;
  wire delta_col_valid_o,delta_col_index_o; wire [STRIPE_ROWS*SCORE_W-1:0] delta_col_data_o;
  integer errors=0;
  fsa_stripe #(.STRIPE_ROWS(STRIPE_ROWS),.COLS(COLS),.HEAD_DIM(HEAD_DIM),
    .DATA_W(DATA_W),.SCORE_W(SCORE_W),.PROB_W(PROB_W),.SUM_W(SUM_W),.TAG_W(TAG_W)) dut(.*);
  always #5 clk=~clk; `TB_TIMEOUT(160,"tb_fsa_stripe")
  initial begin
    repeat(3) @(posedge clk); rst_n=1;
    @(negedge clk); prob_col_load_col_i=0; prob_col_load_data_i={16'd0,16'd7}; prob_col_load_valid_i=1;
    @(negedge clk); prob_col_load_col_i=1; prob_col_load_data_i={16'd0,16'd9};
    @(negedge clk); prob_col_load_valid_i=0; sum_start_valid_i=2'b01;
    @(negedge clk); sum_start_valid_i=0;
    wait(sum_done_valid_o[0]); #1;
    `TB_CHECK(sum_done_data_o[SUM_W-1:0]==32'd16,"softmax rowsum")
    @(negedge clk); ws_pv_i=1;
    repeat(2) @(negedge clk);
    k_top_data_i={8'sd3,8'sd2}; k_top_valid_i=2'b01;
    pv_sum_valid_i=2'b01; pv_sum_data_i=0; pv_sum_data_i[SUM_W-1:0]=32'd11;
    pv_sum_tag_i=0; pv_sum_tag_i[TAG_W-1:0]=2'd3;
    @(negedge clk); k_top_valid_i=2'b10; pv_sum_valid_i=0;
    @(negedge clk); k_top_valid_i=0;
    repeat(5) @(posedge clk);
    @(negedge clk); o_rd_en_i=1; o_rd_feature_i=3;
    @(negedge clk); o_rd_en_i=0;
    wait(o_rd_valid_o); #1;
    if (o_rd_data_o[SUM_W-1:0]!==32'd52) begin
      $error("[FAIL] WS-PV O-bank got=%0d expected=52",
             $signed(o_rd_data_o[SUM_W-1:0]));
      errors=errors+1;
    end
    @(negedge clk); o_rd_en_i=1; o_rd_feature_i=3;
    @(negedge clk); o_rd_en_i=0; pv_seed_operand_valid_i=1;
    pv_seed_alpha_i=0; pv_seed_alpha_i[PROB_W-1:0]=16'd16384;
    pv_seed_feature_i=2;
    @(negedge clk); pv_seed_operand_valid_i=0;
    wait(pv_seed_valid_o); #1;
    if ($signed(pv_seed_data_o[SUM_W-1:0])!==32'sd26) begin
      $error("[FAIL] registered O-seed got=%0d expected=26",
             $signed(pv_seed_data_o[SUM_W-1:0]));
      errors=errors+1;
    end
    `TB_CHECK(pv_seed_feature_o==2,"registered O-seed feature")
    `TB_FINISH("tb_fsa_stripe")
  end
endmodule
