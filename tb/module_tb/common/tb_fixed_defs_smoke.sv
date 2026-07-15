`timescale 1ns/1ps
`include "attention_defines.vh"
`include "fixed_defs.vh"

module tb_fixed_defs_smoke;
  initial begin
    if (`ATTN_AXI_DATA_W != 128) $fatal(1, "ATTN_AXI_DATA_W mismatch");
    if (`ATTN_AXI_LITE_DATA_W != 32) $fatal(1, "ATTN_AXI_LITE_DATA_W mismatch");
    if (`ATTN_DEFAULT_HEAD_DIM != 64) $fatal(1, "ATTN_DEFAULT_HEAD_DIM mismatch");
    if (`ATTN_DEFAULT_TILE_Q != 32) $fatal(1, "ATTN_DEFAULT_TILE_Q mismatch");
    if (`ATTN_INT8_MAX != 8'sd127) $fatal(1, "ATTN_INT8_MAX mismatch");
    if (`ATTN_STATE_QK != 4'd3) $fatal(1, "ATTN_STATE_QK mismatch");
    $display("[PASS] tb_fixed_defs_smoke");
    $finish;
  end
endmodule
