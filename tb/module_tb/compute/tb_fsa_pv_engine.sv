`timescale 1ns/1ps
`include "tb_fsdb.svh"

// Locks the V-cache response/tag contract used by WS-PV. In particular, the
// response for feature d must carry d through the array interface, including
// the final feature, rather than relying on a response counter.
module tb_fsa_pv_engine;
  `TB_FSDB_DUMP("tb_fsa_pv_engine.fsdb", tb_fsa_pv_engine)

  localparam CACHE_ADDR_W = 3;
  localparam CACHE_ELEM_W = 8;
  localparam ARRAY_COLS = 4;
  localparam CACHE_WORD_W = ARRAY_COLS * CACHE_ELEM_W;
  localparam HEAD_DIM = 8;
  localparam FEATURE_IDX_W = 3;

  reg clk = 1'b0;
  reg rst_n = 1'b0;
  reg clear_i = 1'b0;
  reg start_i = 1'b0;
  reg first_kv_tile_i = 1'b1;
  wire v_rd_en_o;
  wire [CACHE_ADDR_W-1:0] v_rd_addr_o;
  reg [CACHE_WORD_W-1:0] v_rd_data_i = {CACHE_WORD_W{1'b0}};
  reg v_rd_valid_i = 1'b0;
  wire array_start_o;
  reg array_ready_i = 1'b0;
  wire array_seed_zero_o;
  wire array_valid_o;
  wire [FEATURE_IDX_W-1:0] array_feature_o;
  wire [ARRAY_COLS*CACHE_ELEM_W-1:0] array_cols_o;
  reg array_done_i = 1'b0;
  wire done_o;
  wire busy_o;
  wire error_o;

  // This is the qkv_tile_cache read timing: request is registered once, then
  // its data and valid return together on the following clock edge.
  reg cache_request_q;
  reg [CACHE_ADDR_W-1:0] cache_addr_q;
  integer lane;
  integer received_count;
  integer errors;

  function [CACHE_WORD_W-1:0] v_word;
    input [FEATURE_IDX_W-1:0] feature;
    integer word_lane;
    begin
      v_word = {CACHE_WORD_W{1'b0}};
      for (word_lane = 0; word_lane < ARRAY_COLS;
           word_lane = word_lane + 1)
        v_word[word_lane*CACHE_ELEM_W +: CACHE_ELEM_W] =
            feature * ARRAY_COLS + word_lane;
    end
  endfunction

  fsa_pv_engine #(
    .CACHE_ADDR_W(CACHE_ADDR_W), .CACHE_WORD_W(CACHE_WORD_W),
    .CACHE_ELEM_W(CACHE_ELEM_W), .ARRAY_COLS(ARRAY_COLS),
    .ARRAY_DATA_W(CACHE_ELEM_W), .HEAD_DIM(HEAD_DIM),
    .FEATURE_IDX_W(FEATURE_IDX_W), .V_RD_LATENCY(2)
  ) dut (.*);

  always #5 clk = ~clk;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cache_request_q <= 1'b0;
      cache_addr_q <= {CACHE_ADDR_W{1'b0}};
      v_rd_valid_i <= 1'b0;
      v_rd_data_i <= {CACHE_WORD_W{1'b0}};
    end else begin
      v_rd_valid_i <= cache_request_q;
      if (cache_request_q) v_rd_data_i <= v_word(cache_addr_q);
      cache_request_q <= v_rd_en_o;
      if (v_rd_en_o) cache_addr_q <= v_rd_addr_o;
    end
  end

  // Sample after registered cache outputs settle. Each feature is uniquely
  // encoded in its data so a tag-only check cannot mask a one-cycle skew.
  always @(negedge clk) begin
    if (rst_n && array_valid_o) begin
      if (array_feature_o !== received_count[FEATURE_IDX_W-1:0]) begin
        $error("[FAIL] feature tag got=%0d expected=%0d",
               array_feature_o, received_count);
        errors = errors + 1;
      end
      for (lane = 0; lane < ARRAY_COLS; lane = lane + 1) begin
        if (array_cols_o[lane*CACHE_ELEM_W +: CACHE_ELEM_W] !==
            received_count * ARRAY_COLS + lane) begin
          $error("[FAIL] data/tag skew feature=%0d lane=%0d got=%0d expected=%0d",
                 array_feature_o, lane,
                 array_cols_o[lane*CACHE_ELEM_W +: CACHE_ELEM_W],
                 received_count * ARRAY_COLS + lane);
          errors = errors + 1;
        end
      end
      received_count = received_count + 1;
      if (received_count == HEAD_DIM) array_done_i = 1'b1;
    end
  end

  initial begin
    received_count = 0;
    errors = 0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    @(negedge clk);
    start_i = 1'b1;
    @(negedge clk);
    start_i = 1'b0;
    wait (array_start_o);
    @(negedge clk);
    array_ready_i = 1'b1;
    repeat (2) @(posedge clk);
    @(negedge clk);
    array_ready_i = 1'b0;

    wait (done_o || error_o);
    #1;
    if (error_o || !done_o) begin
      $error("[FAIL] PV engine did not complete cleanly");
      errors = errors + 1;
    end
    if (received_count != HEAD_DIM) begin
      $error("[FAIL] received %0d features, expected %0d", received_count, HEAD_DIM);
      errors = errors + 1;
    end
    if (errors == 0) $display("[PASS] tb_fsa_pv_engine");
    else $fatal(1, "tb_fsa_pv_engine failed errors=%0d", errors);
    $finish;
  end

  initial begin
    repeat (160) @(posedge clk);
    $fatal(1, "tb_fsa_pv_engine timeout");
  end
endmodule
