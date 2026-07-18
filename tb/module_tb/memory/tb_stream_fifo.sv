`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"

module tb_stream_fifo;
  `TB_FSDB_DUMP("tb_stream_fifo.fsdb", tb_stream_fifo)
  reg clk=0,rst_n=0,clear_i=0;
  reg [15:0] in_data_i=0; reg in_valid_i=0; wire in_ready_o;
  wire [15:0] out_data_o; wire out_valid_o; reg out_ready_i=0; wire [2:0] level_o;
  integer errors=0,i;
  stream_fifo #(.DATA_W(16),.DEPTH(4),.PTR_W(2)) dut (.*);
  always #5 clk=~clk;
  `TB_TIMEOUT(150, "tb_stream_fifo")
  initial begin
    repeat(3) @(posedge clk); rst_n=1;
    for(i=0;i<4;i=i+1) begin @(negedge clk); in_valid_i=1; in_data_i=16'h100+i; end
    @(negedge clk); in_valid_i=0; #1;
    `TB_CHECK(level_o==4 && !in_ready_o, "FIFO full")
    for(i=0;i<4;i=i+1) begin
      #1; `TB_CHECK(out_valid_o && out_data_o==16'h100+i, "FIFO ordering")
      @(negedge clk); out_ready_i=1; @(posedge clk); #1; @(negedge clk); out_ready_i=0;
    end
    #1; `TB_CHECK(level_o==0 && !out_valid_o, "FIFO empty")
    @(negedge clk); in_valid_i=1; in_data_i=16'h55aa; out_ready_i=1;
    @(posedge clk); #1; @(negedge clk); in_valid_i=0;
    `TB_CHECK(level_o==1, "push into empty while ready")
    @(negedge clk); clear_i=1; @(posedge clk); #1;
    `TB_CHECK(level_o==0, "FIFO clear")
    `TB_FINISH("tb_stream_fifo")
  end
endmodule
