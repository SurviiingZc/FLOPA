`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "attention_defines.vh"
`include "tb_common.svh"

module tb_fsa_controller;
  `TB_FSDB_DUMP("tb_fsa_controller.fsdb", tb_fsa_controller)
  reg clk = 0, rst_n = 0, clear_i = 0;
  reg qk_start_i = 0, pv_start_i = 0, qk_done_i = 0, pv_done_i = 0;
  reg qk_error_i = 0, pv_error_i = 0;
  wire [1:0] phase_o;
  wire qk_go_o, pv_go_o, busy_o, error_o;
  integer errors = 0;
  fsa_controller dut (.*);
  always #5 clk = ~clk;
  `TB_TIMEOUT(100, "tb_fsa_controller")

  initial begin
    repeat (3) @(posedge clk); rst_n = 1;
    @(negedge clk); qk_start_i = 1;
    @(posedge clk); #1;
    `TB_CHECK(phase_o == `ATTN_ARRAY_PHASE_QK && qk_go_o && busy_o, "QK start handshake")
    @(negedge clk); qk_start_i = 0; qk_done_i = 1;
    @(posedge clk); #1;
    `TB_CHECK(phase_o == `ATTN_ARRAY_PHASE_IDLE && !busy_o, "QK completion")
    @(negedge clk); qk_done_i = 0; pv_start_i = 1;
    @(posedge clk); #1;
    `TB_CHECK(phase_o == `ATTN_ARRAY_PHASE_PV && pv_go_o, "PV start handshake")
    @(negedge clk); pv_start_i = 0; pv_error_i = 1;
    @(posedge clk); #1;
    `TB_CHECK(error_o && phase_o == `ATTN_ARRAY_PHASE_IDLE, "PV error propagation")
    @(negedge clk); pv_error_i = 0; clear_i = 1;
    @(posedge clk); #1; clear_i = 0;
    `TB_CHECK(!error_o, "clear error")
    @(negedge clk); qk_start_i = 1; pv_start_i = 1;
    @(posedge clk); #1;
    `TB_CHECK(error_o && !busy_o, "simultaneous starts rejected")
    `TB_FINISH("tb_fsa_controller")
  end
endmodule
