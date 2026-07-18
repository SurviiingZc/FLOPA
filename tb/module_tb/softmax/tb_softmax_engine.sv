`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"

module tb_softmax_engine;
  `TB_FSDB_DUMP("tb_softmax_engine.fsdb", tb_softmax_engine)
  reg clk=0,rst_n=0,clear_i=0,clear_rows_i=0,start_i=0;
  reg [32767:0] score_tile_i=0; reg [31:0] score_scale_i=32'd1;
  reg [15:0] q_base_i=0,k_base_i=0,seq_q_i=1,seq_kv_i=1; reg causal_en_i=0;
  wire [16383:0] beta_tile_o; wire [511:0] alpha_rows_o,m_rows_o; wire [1023:0] l_rows_o;
  wire done_o,busy_o,error_o; integer errors=0;
  softmax_engine dut (.*);
  always #5 clk=~clk;
  `TB_TIMEOUT(2500, "tb_softmax_engine")
  initial begin
    repeat(3) @(posedge clk); rst_n=1;
    @(negedge clk); start_i=1;
    wait(done_o); #1;
    `TB_CHECK(!busy_o && !error_o, "softmax completion")
    `TB_CHECK(beta_tile_o[15:0]==16'd32767, "single unmasked beta")
    `TB_CHECK(beta_tile_o[31:16]==0 && beta_tile_o[32*16 +:16]==0, "masked beta lanes and rows")
    `TB_CHECK($signed(m_rows_o[15:0])==0 && l_rows_o[31:0]==32767 && alpha_rows_o[15:0]==0, "row LSE state")
    start_i=0;
    @(negedge clk); clear_rows_i=1; @(posedge clk); #1;
    `TB_CHECK(m_rows_o==0 && l_rows_o==0 && beta_tile_o==0, "row-state clear")
    `TB_FINISH("tb_softmax_engine")
  end
endmodule
