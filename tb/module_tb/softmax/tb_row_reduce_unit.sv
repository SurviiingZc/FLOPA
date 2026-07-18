`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "attention_defines.vh"

module tb_row_reduce_unit;
  `TB_FSDB_DUMP("tb_row_reduce_unit.fsdb", tb_row_reduce_unit)
  reg clk;
  reg rst_n;
  reg valid_i;
  reg mode_i;
  reg [31:0] lane_valid_i;
  reg [511:0] data_i;
  wire valid_o;
  wire signed [31:0] result_o;
  integer lane;

  row_reduce_unit dut (
    .clk(clk), .rst_n(rst_n), .valid_i(valid_i), .mode_i(mode_i),
    .lane_valid_i(lane_valid_i), .data_i(data_i), .valid_o(valid_o), .result_o(result_o)
  );
  always #5 clk = ~clk;

  task launch;
    input mode;
    begin
      @(negedge clk); mode_i = mode; valid_i = 1'b1;
      @(negedge clk); valid_i = 1'b0;
      wait (valid_o); #1;
    end
  endtask

  initial begin
    clk = 0; rst_n = 0; valid_i = 0; mode_i = 0; lane_valid_i = 32'hffff_ffff; data_i = 0;
    repeat (3) @(posedge clk); rst_n = 1;
    for (lane = 0; lane < 32; lane = lane + 1) data_i[lane*16 +: 16] = lane - 16;
    launch(`ATTN_REDUCE_MAX);
    if (result_o !== 32'sd15) $fatal(1, "max mismatch: %0d", result_o);
    for (lane = 0; lane < 32; lane = lane + 1) data_i[lane*16 +: 16] = lane + 1;
    launch(`ATTN_REDUCE_SUM);
    if (result_o !== 32'd528) $fatal(1, "sum mismatch: %0d", result_o);
    lane_valid_i = 32'h0000_ffff;
    launch(`ATTN_REDUCE_SUM);
    if (result_o !== 32'd136) $fatal(1, "masked sum mismatch: %0d", result_o);
    $display("[PASS] tb_row_reduce_unit");
    $finish;
  end
endmodule
