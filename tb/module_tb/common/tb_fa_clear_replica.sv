`timescale 1ns/1ps
`include "tb_fsdb.svh"

module tb_fa_clear_replica;
  reg clk;
  reg rst_n;
  reg clear_i;
  reg token_i;
  wire token_o;

  fa_clear_replica dut (
    .clk(clk), .rst_n(rst_n), .clear_i(clear_i),
    .token_i(token_i), .token_o(token_o)
  );

  `TB_FSDB_DUMP("tb_fa_clear_replica.fsdb", tb_fa_clear_replica)

  always #5 clk = ~clk;

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_i = 1'b0;
    token_i = 1'b0;
    #2;
    if (token_o !== 1'b0) $fatal(1, "asynchronous reset failed");

    @(negedge clk);
    rst_n = 1'b1;
    token_i = 1'b1;
    @(negedge clk);
    if (token_o !== 1'b1) $fatal(1, "token capture failed");

    token_i = 1'b0;
    @(negedge clk);
    if (token_o !== 1'b0) $fatal(1, "token deassertion failed");

    token_i = 1'b1;
    clear_i = 1'b1;
    @(negedge clk);
    if (token_o !== 1'b0) $fatal(1, "clear priority failed");

    clear_i = 1'b0;
    @(negedge clk);
    if (token_o !== 1'b1) $fatal(1, "post-clear capture failed");

    #2 rst_n = 1'b0;
    #1;
    if (token_o !== 1'b0) $fatal(1, "late asynchronous reset failed");

    $display("[PASS] tb_fa_clear_replica");
    $finish;
  end
endmodule
