`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"

module tb_output_buffer;
  `TB_FSDB_DUMP("tb_output_buffer.fsdb", tb_output_buffer)
  reg clk=0,rst_n=0,clear_tile_i=0;
  reg acc_wr_valid_i=0; reg [4:0] acc_wr_row_i=0; reg acc_wr_half_i=0; reg [1023:0] acc_wr_data_i=0;
  reg acc_rd_en_i=0; reg [4:0] acc_rd_row_i=0; reg acc_rd_half_i=0; wire [1023:0] acc_rd_data_o; wire acc_rd_valid_o;
  reg out_wr_valid_i=0; reg [4:0] out_wr_row_i=0; reg out_wr_half_i=0; reg [255:0] out_wr_data_i=0;
  reg stream_start_i=0; reg [15:0] stream_bytes_i=0; wire [127:0] stream_data_o; wire [15:0] stream_strb_o;
  wire stream_valid_o; reg stream_ready_i=0; wire stream_last_o,stream_busy_o,stream_done_o;
  integer errors=0;
  output_buffer dut (.*);
  always #5 clk=~clk;
  `TB_TIMEOUT(250, "tb_output_buffer")
  initial begin
    repeat(3) @(posedge clk); rst_n=1;
    @(negedge clk); acc_wr_valid_i=1; acc_wr_row_i=31; acc_wr_half_i=1; acc_wr_data_i={32{32'hdeadbeef}};
    @(negedge clk); acc_wr_valid_i=0; acc_rd_en_i=1; acc_rd_row_i=31; acc_rd_half_i=1;
    @(negedge clk); acc_rd_en_i=0;
    wait(acc_rd_valid_o); #1;
    `TB_CHECK(acc_rd_data_o=={32{32'hdeadbeef}}, "accumulator readback")
    @(negedge clk); out_wr_valid_i=1; out_wr_row_i=0; out_wr_half_i=0;
    out_wr_data_i=256'hffeeddccbbaa99887766554433221100_0123456789abcdef0011223344556677;
    @(negedge clk); out_wr_valid_i=0; stream_bytes_i=20; stream_start_i=1;
    @(negedge clk); stream_start_i=0;
    wait(stream_valid_o); #1;
    `TB_CHECK(stream_data_o==128'h0123456789abcdef0011223344556677 && stream_strb_o==16'hffff && !stream_last_o, "first stream beat")
    repeat(2) @(posedge clk); #1;
    `TB_CHECK(stream_valid_o && stream_data_o==128'h0123456789abcdef0011223344556677, "stream backpressure hold")
    @(negedge clk); stream_ready_i=1; @(posedge clk); #1; @(negedge clk); stream_ready_i=0;
    wait(stream_valid_o); #1;
    `TB_CHECK(stream_data_o==128'hffeeddccbbaa99887766554433221100 && stream_strb_o==16'h000f && stream_last_o, "partial final beat")
    @(negedge clk); stream_ready_i=1; @(posedge clk); #1;
    `TB_CHECK(stream_done_o && !stream_busy_o, "stream completion")
    `TB_FINISH("tb_output_buffer")
  end
endmodule
