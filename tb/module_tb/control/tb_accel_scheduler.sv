`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "attention_defines.vh"

module tb_accel_scheduler;
  `TB_FSDB_DUMP("tb_accel_scheduler.fsdb", tb_accel_scheduler)
  reg clk;
  reg rst_n;
  reg start_i;
  reg soft_reset_i;
  reg clear_done_i;
  reg clear_error_i;
  reg fatal_error_i;
  reg mode_sel_i;
  reg causal_en_i;
  reg prefill_en_i;
  reg decode_en_i;
  reg load_q_done_i;
  reg load_kv_done_i;
  reg qk_done_i;
  reg softmax_pv_ready_i;
  reg pv_done_i;
  reg wb_done_i;
  reg [15:0] seq_q_i;
  reg [15:0] seq_kv_i;
  reg [7:0] num_q_heads_i;
  reg [7:0] num_kv_heads_i;
  reg [7:0] tile_q_i;
  reg [7:0] tile_k_i;
  wire [3:0] state_o;
  wire busy_o;
  wire done_o;
  wire error_o;
  wire [3:0] error_code_o;
  wire idle_o;
  wire load_active_o;
  wire compute_active_o;
  wire writeback_active_o;
  wire load_q_en_o;
  wire load_kv_en_o;
  wire qk_en_o;
  wire softmax_en_o;
  wire pv_en_o;
  wire wb_en_o;
  wire decode_active_o;
  wire [7:0] head_index_o;

  accel_scheduler dut (
    .clk(clk), .rst_n(rst_n), .start_i(start_i), .soft_reset_i(soft_reset_i),
    .clear_done_i(clear_done_i), .clear_error_i(clear_error_i), .fatal_error_i(fatal_error_i),
    .mode_sel_i(mode_sel_i), .prefill_en_i(prefill_en_i), .decode_en_i(decode_en_i),
    .load_q_done_i(load_q_done_i), .load_kv_done_i(load_kv_done_i), .qk_done_i(qk_done_i),
    .softmax_pv_ready_i(softmax_pv_ready_i),
    .pv_done_i(pv_done_i), .wb_done_i(wb_done_i),
    .seq_q_i(seq_q_i), .seq_kv_i(seq_kv_i), .num_q_heads_i(num_q_heads_i), .num_kv_heads_i(num_kv_heads_i),
    .tile_q_i(tile_q_i), .tile_k_i(tile_k_i),
    .state_o(state_o), .busy_o(busy_o), .done_o(done_o), .error_o(error_o), .error_code_o(error_code_o),
    .idle_o(idle_o), .load_active_o(load_active_o), .compute_active_o(compute_active_o), .writeback_active_o(writeback_active_o),
    .load_q_en_o(load_q_en_o), .load_kv_en_o(load_kv_en_o), .qk_en_o(qk_en_o), .softmax_en_o(softmax_en_o),
    .pv_en_o(pv_en_o), .wb_en_o(wb_en_o), .head_index_o(head_index_o),
    .q_tile_index_o(),
    .kv_tile_index_o(), .q_tile_base_o(), .kv_tile_base_o(), .tile_last_o(), .run_last_o(),
    .decode_active_o(decode_active_o)
  );

  always #5 clk = ~clk;

  task expect_state;
    input [3:0] exp;
    begin
      #1;
      if (state_o !== exp) $fatal(1, "state mismatch exp=%0d got=%0d", exp, state_o);
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    start_i = 1'b0;
    soft_reset_i = 1'b0;
    clear_done_i = 1'b0;
    clear_error_i = 1'b0;
    fatal_error_i = 1'b0;
    mode_sel_i = 1'b0;
    causal_en_i = 1'b0;
    prefill_en_i = 1'b1;
    decode_en_i = 1'b0;
    load_q_done_i = 1'b0;
    load_kv_done_i = 1'b0;
    qk_done_i = 1'b0;
    softmax_pv_ready_i = 1'b0;
    pv_done_i = 1'b0;
    wb_done_i = 1'b0;
    seq_q_i = 16'd32;
    seq_kv_i = 16'd32;
    num_q_heads_i = 8'd1;
    num_kv_heads_i = 8'd1;
    tile_q_i = 8'd32;
    tile_k_i = 8'd32;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    expect_state(`ATTN_STATE_IDLE);

    start_i = 1'b1;
    @(posedge clk);
    #1;
    start_i = 1'b0;
    expect_state(`ATTN_STATE_LOAD_Q);
    if (!busy_o || !load_q_en_o) $fatal(1, "LOAD_Q outputs wrong");

    load_q_done_i = 1'b1; @(posedge clk); #1; load_q_done_i = 1'b0; expect_state(`ATTN_STATE_LOAD_KV);
    load_kv_done_i = 1'b1; @(posedge clk); #1; load_kv_done_i = 1'b0; expect_state(`ATTN_STATE_QK);
    qk_done_i = 1'b1; @(posedge clk); #1; qk_done_i = 1'b0; expect_state(`ATTN_STATE_SOFTMAX);
    softmax_pv_ready_i = 1'b1; @(posedge clk); #1; softmax_pv_ready_i = 1'b0; expect_state(`ATTN_STATE_PV);
    pv_done_i = 1'b1; @(posedge clk); #1; pv_done_i = 1'b0; expect_state(`ATTN_STATE_WRITEBACK);
    wb_done_i = 1'b1; @(posedge clk); #1; wb_done_i = 1'b0; expect_state(`ATTN_STATE_DONE);
    if (!done_o || busy_o) $fatal(1, "DONE outputs wrong");

    clear_done_i = 1'b1; @(posedge clk); #1; clear_done_i = 1'b0; expect_state(`ATTN_STATE_IDLE);

    // A two-head MHA prefill uses one START and reports done after both heads.
    num_q_heads_i = 8'd2;
    num_kv_heads_i = 8'd2;
    start_i = 1'b1; @(posedge clk); #1; start_i = 1'b0;
    expect_state(`ATTN_STATE_LOAD_Q);
    load_q_done_i = 1'b1; @(posedge clk); #1; load_q_done_i = 1'b0;
    load_kv_done_i = 1'b1; @(posedge clk); #1; load_kv_done_i = 1'b0;
    qk_done_i = 1'b1; @(posedge clk); #1; qk_done_i = 1'b0;
    softmax_pv_ready_i = 1'b1; @(posedge clk); #1; softmax_pv_ready_i = 1'b0;
    pv_done_i = 1'b1; @(posedge clk); #1; pv_done_i = 1'b0;
    wb_done_i = 1'b1; @(posedge clk); #1; wb_done_i = 1'b0;
    expect_state(`ATTN_STATE_LOAD_Q);
    if (done_o || head_index_o != 8'd1) begin
      $fatal(1, "MHA completed before the second head");
    end
    load_q_done_i = 1'b1; @(posedge clk); #1; load_q_done_i = 1'b0;
    load_kv_done_i = 1'b1; @(posedge clk); #1; load_kv_done_i = 1'b0;
    qk_done_i = 1'b1; @(posedge clk); #1; qk_done_i = 1'b0;
    softmax_pv_ready_i = 1'b1; @(posedge clk); #1; softmax_pv_ready_i = 1'b0;
    pv_done_i = 1'b1; @(posedge clk); #1; pv_done_i = 1'b0;
    wb_done_i = 1'b1; @(posedge clk); #1; wb_done_i = 1'b0;
    expect_state(`ATTN_STATE_DONE);
    if (!done_o || head_index_o != 8'd1) $fatal(1, "MHA node did not complete");
    clear_done_i = 1'b1; @(posedge clk); #1; clear_done_i = 1'b0;
    expect_state(`ATTN_STATE_IDLE);
    num_q_heads_i = 8'd1;
    num_kv_heads_i = 8'd1;

    prefill_en_i = 1'b1;
    decode_en_i = 1'b1;
    start_i = 1'b1; @(posedge clk); #1; start_i = 1'b0; expect_state(`ATTN_STATE_ERROR);
    if (!error_o || error_code_o != `ATTN_ERR_BAD_CFG) $fatal(1, "illegal mode did not raise error");

    clear_error_i = 1'b1; @(posedge clk); #1; clear_error_i = 1'b0; expect_state(`ATTN_STATE_IDLE);

    // Single-token MHA decode has one physical Q tile and two KV tiles for
    // a 33-token context. Row masking is handled downstream by the fused array.
    prefill_en_i = 1'b0;
    decode_en_i = 1'b1;
    seq_q_i = 16'd1;
    seq_kv_i = 16'd33;
    start_i = 1'b1; @(posedge clk); #1; start_i = 1'b0; expect_state(`ATTN_STATE_LOAD_Q);
    if (!decode_active_o) $fatal(1, "decode configuration was not latched");
    load_q_done_i = 1'b1; @(posedge clk); #1; load_q_done_i = 1'b0; expect_state(`ATTN_STATE_LOAD_KV);
    load_kv_done_i = 1'b1; @(posedge clk); #1; load_kv_done_i = 1'b0; expect_state(`ATTN_STATE_QK);
    qk_done_i = 1'b1; @(posedge clk); #1; qk_done_i = 1'b0; expect_state(`ATTN_STATE_SOFTMAX);
    softmax_pv_ready_i = 1'b1; @(posedge clk); #1; softmax_pv_ready_i = 1'b0; expect_state(`ATTN_STATE_PV);
    pv_done_i = 1'b1; @(posedge clk); #1; pv_done_i = 1'b0; expect_state(`ATTN_STATE_LOAD_KV);
    load_kv_done_i = 1'b1; @(posedge clk); #1; load_kv_done_i = 1'b0; expect_state(`ATTN_STATE_QK);
    qk_done_i = 1'b1; @(posedge clk); #1; qk_done_i = 1'b0; expect_state(`ATTN_STATE_SOFTMAX);
    softmax_pv_ready_i = 1'b1; @(posedge clk); #1; softmax_pv_ready_i = 1'b0; expect_state(`ATTN_STATE_PV);
    pv_done_i = 1'b1; @(posedge clk); #1; pv_done_i = 1'b0; expect_state(`ATTN_STATE_WRITEBACK);
    wb_done_i = 1'b1; @(posedge clk); #1; wb_done_i = 1'b0; expect_state(`ATTN_STATE_DONE);

    $display("[PASS] tb_accel_scheduler");
    $finish;
  end
endmodule
