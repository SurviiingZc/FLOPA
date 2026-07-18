`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"

module tb_row_broadcast;
  `TB_FSDB_DUMP("tb_row_broadcast.fsdb", tb_row_broadcast)
  reg clk=0,rst_n=0,valid_i=0; reg [15:0] row_value_i=0; wire valid_o; wire [127:0] lane_values_o;
  integer errors=0,lane;
  row_broadcast #(.LANES(8),.DATA_W(16)) dut (.*);
  always #5 clk=~clk;
  `TB_TIMEOUT(60, "tb_row_broadcast")
  initial begin
    repeat(3) @(posedge clk); rst_n=1;
    @(negedge clk); row_value_i=16'h8bad; valid_i=1;
    @(posedge clk); #1;
    `TB_CHECK(valid_o, "broadcast valid")
    for(lane=0;lane<8;lane=lane+1) `TB_CHECK(lane_values_o[lane*16 +:16]==16'h8bad, "broadcast lane")
    @(negedge clk); valid_i=0; @(posedge clk); #1;
    `TB_CHECK(!valid_o && lane_values_o=={8{16'h8bad}}, "broadcast output holds")
    `TB_FINISH("tb_row_broadcast")
  end
endmodule
