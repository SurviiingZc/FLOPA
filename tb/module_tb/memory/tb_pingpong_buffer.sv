`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"

module tb_pingpong_buffer;
  `TB_FSDB_DUMP("tb_pingpong_buffer.fsdb", tb_pingpong_buffer)
  reg clk=0,rst_n=0,clear_i=0,load_commit_i=0,load_bank_i=0,consume_i=0,switch_i=0;
  wire active_bank_o,active_valid_o,next_valid_o,protocol_error_o;
  wire [1:0] bank_valid_o;
  integer errors=0;
  pingpong_buffer dut (.*);
  always #5 clk=~clk;
  `TB_TIMEOUT(100, "tb_pingpong_buffer")
  task pulse_load; input bank; begin @(negedge clk); load_bank_i=bank; load_commit_i=1; @(negedge clk); load_commit_i=0; end endtask
  initial begin
    repeat(3) @(posedge clk); rst_n=1;
    pulse_load(0); #1;
    `TB_CHECK(active_valid_o && bank_valid_o==2'b01, "active bank commit")
    pulse_load(1); #1;
    `TB_CHECK(next_valid_o && bank_valid_o==2'b11, "next bank commit")
    @(negedge clk); consume_i=1; switch_i=1;
    @(posedge clk); #1;
    `TB_CHECK(active_bank_o==1 && active_valid_o && bank_valid_o==2'b10, "consume and switch")
    @(negedge clk); consume_i=0; switch_i=0;
    pulse_load(1); #1;
    `TB_CHECK(protocol_error_o, "double commit rejected")
    @(negedge clk); clear_i=1; @(posedge clk); #1;
    `TB_CHECK(bank_valid_o==0 && !protocol_error_o, "clear state")
    `TB_FINISH("tb_pingpong_buffer")
  end
endmodule
