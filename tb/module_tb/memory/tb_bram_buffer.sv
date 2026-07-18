`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"

module tb_bram_buffer;
  `TB_FSDB_DUMP("tb_bram_buffer.fsdb", tb_bram_buffer)
  reg clk=0,wr_en_i=0,rd_en_i=0; reg [2:0] wr_addr_i=0,rd_addr_i=0; reg [31:0] wr_data_i=0;
  wire [31:0] rd_data_o; wire rd_valid_o; integer errors=0;
  bram_buffer #(.DATA_W(32),.ADDR_W(3),.DEPTH(8)) dut (.*);
  always #5 clk=~clk;
  `TB_TIMEOUT(80, "tb_bram_buffer")
  initial begin
    repeat(2) @(posedge clk);
    @(negedge clk); wr_en_i=1; wr_addr_i=7; wr_data_i=32'hdeadbeef;
    @(negedge clk); wr_en_i=0; rd_en_i=1; rd_addr_i=7;
    @(negedge clk); rd_en_i=0;
    wait(rd_valid_o); #1;
    `TB_CHECK(rd_data_o==32'hdeadbeef, "BRAM boundary readback")
    `TB_FINISH("tb_bram_buffer")
  end
endmodule
