`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "fixed_defs.vh"
`include "tb_common.svh"

module tb_scale_requant_unit;
  `TB_FSDB_DUMP("tb_scale_requant_unit.fsdb", tb_scale_requant_unit)
  reg clk = 0;
  reg rst_n = 0;
  reg valid_i = 0;
  reg signed [31:0] data_i;
  reg signed [15:0] scale_mant_i;
  reg [5:0] shift_i;
  reg signed [15:0] zero_point_i;
  reg [1:0] round_mode_i;
  reg [1:0] sat_mode_i;
  wire valid_o;
  wire signed [15:0] data_o;
  integer errors = 0;

  scale_requant_unit dut (.*);
  always #5 clk = ~clk;
  `TB_TIMEOUT(200, "tb_scale_requant_unit")

  task check_value;
    input signed [31:0] data;
    input signed [15:0] scale;
    input [5:0] shift;
    input signed [15:0] zp;
    input [1:0] round_mode;
    input [1:0] sat_mode;
    input signed [15:0] expected;
    begin
      @(negedge clk);
      data_i = data; scale_mant_i = scale; shift_i = shift;
      zero_point_i = zp; round_mode_i = round_mode; sat_mode_i = sat_mode;
      valid_i = 1;
      @(negedge clk); valid_i = 0;
      wait (valid_o); #1;
      if (data_o !== expected) begin
        $error("[FAIL] requant data=%0d scale=%0d shift=%0d got=%0d expected=%0d",
               data, scale, shift, data_o, expected);
        errors = errors + 1;
      end
      @(negedge clk);
    end
  endtask

  initial begin
    data_i = 0; scale_mant_i = 0; shift_i = 0; zero_point_i = 0;
    round_mode_i = 0; sat_mode_i = 0;
    repeat (3) @(posedge clk); rst_n = 1;
    check_value(32'sd10, 16'sd3, 1, 16'sd1, `ATTN_ROUND_ZERO, `ATTN_SAT_INT16, 16'sd16);
    check_value(32'sd5, 16'sd1, 1, 16'sd0, `ATTN_ROUND_NEAREST, `ATTN_SAT_INT16, 16'sd3);
    check_value(-32'sd5, 16'sd1, 1, 16'sd0, `ATTN_ROUND_NEAREST, `ATTN_SAT_INT16, -16'sd3);
    check_value(32'sd1000, 16'sd2, 0, 16'sd0, `ATTN_ROUND_ZERO, `ATTN_SAT_INT8, 16'sd127);
    check_value(-32'sd1000, 16'sd2, 0, 16'sd0, `ATTN_ROUND_ZERO, `ATTN_SAT_INT8, -16'sd128);
    `TB_FINISH("tb_scale_requant_unit")
  end
endmodule
