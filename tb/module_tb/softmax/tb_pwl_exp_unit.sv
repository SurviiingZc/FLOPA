`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"

module tb_pwl_exp_unit;
  `TB_FSDB_DUMP("tb_pwl_exp_unit.fsdb", tb_pwl_exp_unit)
  reg clk=0,rst_n=0,valid_i=0; reg signed [15:0] x_i=0; wire valid_o; wire [15:0] y_o;
  integer errors=0;
  pwl_exp_unit dut (.*);
  always #5 clk=~clk;
  `TB_TIMEOUT(100, "tb_pwl_exp_unit")
  task check_exp; input signed [15:0] x; input [15:0] expected; begin
    @(negedge clk); x_i=x; valid_i=1; @(negedge clk); valid_i=0;
    wait(valid_o); #1; `TB_CHECK(y_o==expected, "PWL exp value"); @(negedge clk);
  end endtask
  initial begin
    repeat(3) @(posedge clk); rst_n=1;
    check_exp(16'sd1,16'd32767);
    check_exp(16'sd0,16'd32767);
    check_exp(-16'sd256,16'd12055);
    check_exp(-16'sd128,16'd22411);
    check_exp(-16'sd2048,16'd0);
    `TB_FINISH("tb_pwl_exp_unit")
  end
endmodule
