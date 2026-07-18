`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"

module tb_banked_sram;
  `TB_FSDB_DUMP("tb_banked_sram.fsdb", tb_banked_sram)
  localparam BANKS=4, BANK_W=8, ADDR_W=3;
  reg clk=0, rst_n=0, wr_en_i=0, rd_en_i=0;
  reg [ADDR_W-1:0] wr_addr_i=0, rd_addr_i=0;
  reg [BANKS*BANK_W-1:0] wr_data_i=0;
  reg [BANKS-1:0] wr_bank_en_i=0;
  wire [BANKS*BANK_W-1:0] rd_data_o;
  wire rd_valid_o;
  integer errors=0;
  banked_sram #(.BANKS(BANKS),.BANK_W(BANK_W),.ADDR_W(ADDR_W),.DEPTH(8)) dut (.*);
  always #5 clk=~clk;
  `TB_TIMEOUT(180, "tb_banked_sram")

  task write_word;
    input [2:0] addr; input [31:0] data; input [3:0] enables;
    begin
      @(negedge clk); wr_addr_i=addr; wr_data_i=data; wr_bank_en_i=enables; wr_en_i=1;
      @(negedge clk); wr_en_i=0; wr_bank_en_i=0;
      @(posedge clk); #1;
    end
  endtask
  task read_word;
    input [2:0] addr; input [31:0] expected;
    begin
      @(negedge clk); rd_addr_i=addr; rd_en_i=1;
      @(negedge clk); rd_en_i=0;
      wait(rd_valid_o); #1;
      `TB_CHECK(rd_data_o===expected, "banked SRAM readback")
    end
  endtask
  initial begin
    repeat(3) @(posedge clk); rst_n=1;
    write_word(0,32'h44332211,4'hf);
    write_word(7,32'h88776655,4'hf);
    write_word(0,32'hddccbbaa,4'b0101);
    read_word(0,32'h44cc22aa);
    read_word(7,32'h88776655);
    @(negedge clk); wr_en_i=1; wr_addr_i=7; wr_data_i=32'h0; wr_bank_en_i=4'hf; rd_en_i=1; rd_addr_i=7;
    @(negedge clk); wr_en_i=0; wr_bank_en_i=0; rd_en_i=0;
    repeat(2) @(posedge clk); #1;
    `TB_CHECK(!rd_valid_o, "write wins read collision")
    `TB_FINISH("tb_banked_sram")
  end
endmodule
