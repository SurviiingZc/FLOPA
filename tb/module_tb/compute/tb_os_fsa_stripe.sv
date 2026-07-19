`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"

module tb_os_fsa_stripe;
  `TB_FSDB_DUMP("tb_os_fsa_stripe.fsdb", tb_os_fsa_stripe)

  localparam STRIPE_ROWS = 2;
  localparam COLS = 2;
  localparam DATA_W = 16;
  localparam SCORE_W = 32;
  localparam PROB_W = 16;
  localparam ACC_W = 32;
  localparam SUM_W = 32;

  reg clk = 1'b0;
  reg rst_n = 1'b0;
  reg clear_i = 1'b0;
  reg clear_score_i = 1'b0;
  reg clear_acc_i = 1'b0;
  reg mac_is_pv_i = 1'b0;
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
  reg prob_load_valid_i = 1'b0;
  reg prob_load_row_i = 1'b0;
  reg [COLS*PROB_W-1:0] prob_load_data_i = 0;
  reg prob_shift_load_i = 1'b0;
  reg prob_shift_en_i = 1'b0;
  wire [STRIPE_ROWS*PROB_W-1:0] prob_left_rows_o;
  reg acc_load_valid_i = 1'b0;
  reg acc_load_row_i = 1'b0;
  reg [COLS*ACC_W-1:0] acc_load_data_i = 0;
  reg delta_read_req_i = 1'b0;
  reg delta_read_row_i = 1'b0;
  wire delta_read_valid_o;
  wire [COLS*SCORE_W-1:0] delta_read_data_o;
  reg acc_read_req_i = 1'b0;
  reg acc_read_row_i = 1'b0;
  wire acc_read_valid_o;
  wire [COLS*ACC_W-1:0] acc_read_data_o;
  wire tail_mac_last_o;
  integer errors = 0;

  os_fsa_stripe #(
    .STRIPE_ROWS(STRIPE_ROWS), .COLS(COLS), .DATA_W(DATA_W),
    .SCORE_W(SCORE_W), .PROB_W(PROB_W), .ACC_W(ACC_W), .SUM_W(SUM_W)
  ) dut (.*);

  always #5 clk = ~clk;
  `TB_TIMEOUT(100, "tb_os_fsa_stripe")

  initial begin
    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    @(negedge clk);
    acc_load_row_i = 1'b1;
    acc_load_data_i = {32'd22, 32'd11};
    acc_load_valid_i = 1'b1;
    @(negedge clk);
    acc_load_valid_i = 1'b0;

    acc_read_row_i = 1'b1;
    acc_read_req_i = 1'b1;
    @(posedge clk); #1;
    `TB_CHECK(acc_read_valid_o && acc_read_data_o == {32'd22, 32'd11},
              "registered accumulator row read")
    @(negedge clk);
    acc_read_req_i = 1'b0;

    delta_read_row_i = 1'b1;
    delta_read_req_i = 1'b1;
    @(posedge clk); #1;
    `TB_CHECK(delta_read_valid_o && delta_read_data_o == {32'd22, 32'd11},
              "registered delta row read")
    @(negedge clk);
    delta_read_req_i = 1'b0;

    prob_load_row_i = 1'b0;
    prob_load_data_i = {16'd9, 16'd7};
    prob_load_valid_i = 1'b1;
    @(negedge clk);
    prob_load_valid_i = 1'b0;
    sum_start_valid_i = 2'b01;
    @(negedge clk);
    sum_start_valid_i = 2'b00;
    @(posedge clk); #1;
    `TB_CHECK(sum_done_valid_o[0] && sum_done_data_o[SUM_W-1:0] == 32'd16,
              "PE-local horizontal rowsum")

    `TB_FINISH("tb_os_fsa_stripe")
  end
endmodule
