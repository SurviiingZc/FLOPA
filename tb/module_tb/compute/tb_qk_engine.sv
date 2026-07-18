`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"

module tb_qk_engine;
  `TB_FSDB_DUMP("tb_qk_engine.fsdb", tb_qk_engine)
  reg clk=0, rst_n=0, clear_i=0, start_i=0;
  reg [7:0] head_dim_i=2;
  wire q_rd_en_o, k_rd_en_o;
  wire [9:0] q_rd_addr_o, k_rd_addr_o;
  reg [255:0] q_rd_data_i=0, k_rd_data_i=0;
  reg q_rd_valid_i=0, k_rd_valid_i=0;
  wire array_clear_o, array_valid_o, array_last_o;
  wire [511:0] array_rows_o, array_cols_o;
  reg array_last_i=0;
  reg [32767:0] array_matrix_i=0;
  wire [32767:0] score_tile_o;
  wire done_o, busy_o, error_o;
  integer errors=0, beat;
  qk_engine dut (.*);
  always #5 clk=~clk;
  `TB_TIMEOUT(200, "tb_qk_engine")

  initial begin
    q_rd_data_i[7:0]=8'hfe; q_rd_data_i[15:8]=8'h03;
    k_rd_data_i[7:0]=8'h04; k_rd_data_i[15:8]=8'hfb;
    array_matrix_i[31:0]=32'h1234abcd;
    repeat(3) @(posedge clk); rst_n=1;
    @(negedge clk); start_i=1;
    wait(array_clear_o); #1;
    for (beat=0; beat<2; beat=beat+1) begin
      wait(q_rd_en_o && k_rd_en_o);
      @(negedge clk); q_rd_valid_i=1; k_rd_valid_i=1; #1;
      `TB_CHECK(array_valid_o, "array input valid")
      `TB_CHECK($signed(array_rows_o[15:0]) == -2, "Q sign extension")
      `TB_CHECK($signed(array_cols_o[31:16]) == -5, "K sign extension")
      if (beat==1) `TB_CHECK(array_last_o, "last head-dimension beat")
      @(posedge clk); #1;
      @(negedge clk); q_rd_valid_i=0; k_rd_valid_i=0;
    end
    @(negedge clk); array_last_i=1;
    @(negedge clk); array_last_i=0;
    wait(done_o); #1;
    `TB_CHECK(score_tile_o[31:0] == 32'h1234abcd && !busy_o, "score capture and done")
    start_i=0;
    @(negedge clk); clear_i=1;
    @(negedge clk); clear_i=0; head_dim_i=0; start_i=1;
    @(posedge clk); #1;
    `TB_CHECK(error_o && !busy_o, "invalid head dimension")
    `TB_FINISH("tb_qk_engine")
  end
endmodule
