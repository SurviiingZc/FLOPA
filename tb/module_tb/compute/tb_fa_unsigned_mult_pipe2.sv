`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"

module tb_fa_unsigned_mult_pipe2;
  `TB_FSDB_DUMP("tb_fa_unsigned_mult_pipe2.fsdb", tb_fa_unsigned_mult_pipe2)

  reg clk = 0;
  reg rst_n = 0;
  reg valid_i = 0;
  reg [31:0] a_i = 0;
  reg [15:0] b_i = 0;
  wire valid_o;
  wire [47:0] product_o;
  integer seen = 0;
  integer errors = 0;

  fa_unsigned_mult_pipe2 dut (.*);
  always #5 clk = ~clk;
  `TB_TIMEOUT(100, "tb_fa_unsigned_mult_pipe2")

  always @(negedge clk) begin
    if (rst_n && valid_o) begin
      case (seen)
        0: `TB_CHECK(product_o == 48'd30, "unsigned multiply token 0")
        1: `TB_CHECK(product_o == 48'd4294967295,
                     "unsigned multiply token 1")
        2: `TB_CHECK(product_o == 48'd4294967296,
                     "unsigned multiply bubble token")
        default: `TB_CHECK(product_o == 48'd281470681677825,
                           "unsigned multiply maximum")
      endcase
      seen = seen + 1;
    end
  end

  initial begin
    repeat (3) @(posedge clk); rst_n = 1;
    @(negedge clk); a_i = 32'd10; b_i = 16'd3; valid_i = 1;
    @(negedge clk); a_i = 32'hffff_ffff; b_i = 16'd1;
    @(negedge clk); valid_i = 0;
    @(negedge clk); a_i = 32'h8000_0000; b_i = 16'd2; valid_i = 1;
    @(negedge clk); a_i = 32'hffff_ffff; b_i = 16'hffff;
    @(negedge clk); valid_i = 0;
    while (seen < 4) @(negedge clk);
    `TB_FINISH("tb_fa_unsigned_mult_pipe2")
  end
endmodule
