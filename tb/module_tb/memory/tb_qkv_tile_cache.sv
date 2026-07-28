`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "attention_defines.vh"
`include "tb_common.svh"

module tb_qkv_tile_cache;
  `TB_FSDB_DUMP("tb_qkv_tile_cache.fsdb", tb_qkv_tile_cache)
  reg clk=0,rst_n=0,clear_i=0;
  reg [1:0] load_kind_i=0; reg load_bank_i=0; reg [2:0] load_addr_i=0; reg load_half_i=0;
  reg [127:0] load_data_i=0; reg load_valid_i=0; wire load_ready_o;
  reg [1:0] commit_kind_i=0; reg commit_bank_i=0,commit_valid_i=0;
  reg q_consume_i=0,q_switch_i=0,k_consume_i=0,k_switch_i=0,v_consume_i=0,v_switch_i=0;
  wire q_active_valid_o,kv_active_valid_o,q_next_valid_o,kv_next_valid_o,q_active_bank_o,kv_active_bank_o;
  wire k_next_valid_o,v_next_valid_o;
  reg q_rd_en_i=0,k_rd_en_i=0,v_rd_en_i=0; reg [2:0] q_rd_addr_i=0,k_rd_addr_i=0,v_rd_addr_i=0;
  wire [255:0] q_rd_data_o,k_rd_data_o,v_rd_data_o; wire q_rd_valid_o,k_rd_valid_o,v_rd_valid_o;
  wire protocol_error_o; integer errors=0;
  qkv_tile_cache #(.ADDR_W(3),.BANKS(16),.BANK_W(16)) dut (.*);
  always #5 clk=~clk;
  `TB_TIMEOUT(300, "tb_qkv_tile_cache")

  task load_word;
    input [1:0] kind; input bank; input [2:0] addr; input [255:0] data;
    begin
      @(negedge clk); load_kind_i=kind; load_bank_i=bank; load_addr_i=addr; load_half_i=0; load_data_i=data[127:0]; load_valid_i=1;
      @(negedge clk); load_half_i=1; load_data_i=data[255:128];
      @(negedge clk); load_valid_i=0; load_half_i=0;
      repeat(3) @(posedge clk);
    end
  endtask
  task commit;
    input [1:0] kind; input bank;
    begin @(negedge clk); commit_kind_i=kind; commit_bank_i=bank; commit_valid_i=1; @(negedge clk); commit_valid_i=0; end
  endtask
  initial begin
    repeat(3) @(posedge clk); rst_n=1;
    `TB_CHECK(load_ready_o, "cache load ready")
    load_word(`ATTN_CACHE_Q,0,3,256'h0123456789abcdef00112233445566778899aabbccddeeff1020304050607080);
    commit(`ATTN_CACHE_Q,0); #1;
    `TB_CHECK(q_active_valid_o && !q_active_bank_o, "Q bank commit")
    @(negedge clk); q_rd_addr_i=3; q_rd_en_i=1;
    @(negedge clk); q_rd_en_i=0;
    wait(q_rd_valid_o); #1;
    `TB_CHECK(q_rd_data_o==256'h0123456789abcdef00112233445566778899aabbccddeeff1020304050607080, "Q cache readback")
    @(negedge clk); load_kind_i=`ATTN_CACHE_K; load_bank_i=0; load_addr_i=1; load_half_i=1; load_valid_i=1;
    @(posedge clk); #1;
    `TB_CHECK(protocol_error_o, "upper half without lower rejected")
    @(negedge clk); load_valid_i=0; clear_i=1;
    @(posedge clk); #1;
    `TB_CHECK(!q_active_valid_o && !protocol_error_o, "cache clear")
    @(negedge clk); clear_i=0;

    load_word(`ATTN_CACHE_K,0,0,256'h11); commit(`ATTN_CACHE_K,0);
    load_word(`ATTN_CACHE_V,0,0,256'h22); commit(`ATTN_CACHE_V,0);
    load_word(`ATTN_CACHE_K,1,0,256'h33); commit(`ATTN_CACHE_K,1);
    load_word(`ATTN_CACHE_V,1,0,256'h44); commit(`ATTN_CACHE_V,1); #1;
    `TB_CHECK(kv_active_valid_o && !kv_active_bank_o && k_next_valid_o && v_next_valid_o,
              "initial KV pair and next pair valid")

    @(negedge clk); k_consume_i=1; k_switch_i=1;
    @(negedge clk); k_consume_i=0; k_switch_i=0; #1;
    `TB_CHECK(!kv_active_valid_o && kv_active_bank_o,
              "K switches after QK while V remains on prior bank")

    @(negedge clk); v_consume_i=1; v_switch_i=1;
    @(negedge clk); v_consume_i=0; v_switch_i=0; #1;
    `TB_CHECK(kv_active_valid_o && kv_active_bank_o,
              "V switches after PV and realigns active KV pair")
    `TB_FINISH("tb_qkv_tile_cache")
  end
endmodule
