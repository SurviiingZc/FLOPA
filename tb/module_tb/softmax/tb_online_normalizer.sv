`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"

module tb_online_normalizer;
  `TB_FSDB_DUMP("tb_online_normalizer.fsdb", tb_online_normalizer)
  reg clk=0,rst_n=0,valid_i=0; reg [1023:0] acc_row_i=0; reg [31:0] l_i=0,out_scale_i=0;
  wire valid_o; wire [255:0] out_row_o; integer errors=0;
  online_normalizer dut (.*);
  always #5 clk=~clk;
  `TB_TIMEOUT(80, "tb_online_normalizer")
  initial begin
    repeat(3) @(posedge clk); rst_n=1;
    acc_row_i[31:0]=32'sd32768; acc_row_i[63:32]=-32'sd32768; acc_row_i[95:64]=32'sd1;
    l_i=32'd32768; out_scale_i=32'd1;
    @(negedge clk); valid_i=1; @(negedge clk); valid_i=0;
    wait(valid_o); #1;
    `TB_CHECK($signed(out_row_o[7:0])==127, "normalizer positive saturation")
    `TB_CHECK($signed(out_row_o[15:8])==-128, "normalizer negative saturation")
    `TB_CHECK($signed(out_row_o[23:16])==0, "normalizer small value")
    `TB_FINISH("tb_online_normalizer")
  end
endmodule
