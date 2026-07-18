`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"

module tb_uram_bank;
  `TB_FSDB_DUMP("tb_uram_bank.fsdb", tb_uram_bank)
  reg clk=0,wr_en_i=0,rd_en_i=0; reg [2:0] wr_addr_i=0,rd_addr_i=0; reg [71:0] wr_data_i=0;
  wire [71:0] rd_data_o; wire rd_valid_o; integer errors=0;
  uram_bank #(.DATA_W(72),.ADDR_W(3),.DEPTH(8)) dut (.*);
  always #5 clk=~clk;
  `TB_TIMEOUT(80, "tb_uram_bank")
  initial begin
    repeat(2) @(posedge clk);
    @(negedge clk); wr_en_i=1; wr_addr_i=0; wr_data_i=72'h123456789abcdef012;
    @(negedge clk); wr_en_i=0; rd_en_i=1; rd_addr_i=0;
    @(negedge clk); rd_en_i=0;
    wait(rd_valid_o); #1;
    `TB_CHECK(rd_data_o==72'h123456789abcdef012, "URAM readback")
    `TB_FINISH("tb_uram_bank")
  end
endmodule
