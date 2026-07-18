`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"

module tb_block_lse_update;
  `TB_FSDB_DUMP("tb_block_lse_update.fsdb", tb_block_lse_update)
  reg clk=0,rst_n=0,valid_i=0,init_i=0; reg signed [15:0] m_old_i=0,block_max_i=0;
  reg [31:0] l_old_i=0,block_sum_i=0; wire valid_o; wire signed [15:0] m_new_o; wire [31:0] l_new_o; wire [15:0] alpha_o;
  integer errors=0;
  block_lse_update dut (.*);
  always #5 clk=~clk;
  `TB_TIMEOUT(100, "tb_block_lse_update")
  task launch; begin @(negedge clk); valid_i=1; @(negedge clk); valid_i=0; wait(valid_o); #1; end endtask
  initial begin
    repeat(3) @(posedge clk); rst_n=1;
    init_i=1; block_max_i=100; block_sum_i=200; launch();
    `TB_CHECK(m_new_o==100 && l_new_o==200 && alpha_o==0, "initial LSE state")
    init_i=0; m_old_i=100; l_old_i=100; block_max_i=100; block_sum_i=50; launch();
    `TB_CHECK(m_new_o==100 && l_new_o==149 && alpha_o==32767, "online LSE equal max")
    `TB_FINISH("tb_block_lse_update")
  end
endmodule
