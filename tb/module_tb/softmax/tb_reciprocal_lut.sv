`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"

module tb_reciprocal_lut;
  `TB_FSDB_DUMP("tb_reciprocal_lut.fsdb", tb_reciprocal_lut)
  reg clk=0,rst_n=0,valid_i=0; reg [31:0] value_i=0; wire valid_o; wire [31:0] reciprocal_o;
  integer errors=0;
  reciprocal_lut dut (.*);
  always #5 clk=~clk;
  `TB_TIMEOUT(80, "tb_reciprocal_lut")
  task check_recip; input [31:0] value; input [31:0] expected; begin
    @(negedge clk); value_i=value; valid_i=1; @(negedge clk); valid_i=0;
    wait(valid_o); #1; `TB_CHECK(reciprocal_o==expected, "reciprocal LUT value");
  end endtask
  initial begin
    repeat(3) @(posedge clk); rst_n=1;
    check_recip(0,0);
    check_recip(32'd32768,32'd32767);
    check_recip(32'd65536,32'd16383);
    check_recip(32'd1,32'h3fff8000);
    `TB_FINISH("tb_reciprocal_lut")
  end
endmodule
