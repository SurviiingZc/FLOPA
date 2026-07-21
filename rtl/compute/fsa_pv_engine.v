`timescale 1ns/1ps
`include "attention_defines.vh"

// Issues V in feature-major order for probability-stationary WS-PV. Each returned
// V[:,d] is tagged with d so the array can address persistent O and write it back.
module fsa_pv_engine #(
  parameter integer CACHE_ADDR_W = `ATTN_CACHE_ADDR_W,
  parameter integer CACHE_WORD_W = `ATTN_CACHE_WORD_W,
  parameter integer CACHE_ELEM_W = `ATTN_DATA_W,
  parameter integer ARRAY_COLS = `ATTN_ARRAY_COLS,
  parameter integer ARRAY_DATA_W = `ATTN_ARRAY_DATA_W,
  parameter integer HEAD_DIM = `ATTN_HEAD_DIM,
  parameter integer FEATURE_IDX_W = (HEAD_DIM < 2) ? 1 : $clog2(HEAD_DIM)
)(
  input                              clk,
  input                              rst_n,
  input                              clear_i,
  input                              start_i,
  input                              first_kv_tile_i,
  output reg                         v_rd_en_o,
  output reg [CACHE_ADDR_W-1:0]      v_rd_addr_o,
  input      [CACHE_WORD_W-1:0]      v_rd_data_i,
  input                              v_rd_valid_i,
  output reg                         array_start_o,
  input                              array_ready_i,
  output reg                         array_seed_zero_o,
  output reg                         array_valid_o,
  output reg [FEATURE_IDX_W-1:0]     array_feature_o,
  output reg [ARRAY_COLS*ARRAY_DATA_W-1:0] array_cols_o,
  input                              array_done_i,
  output reg                         done_o,
  output reg                         busy_o,
  output reg                         error_o
);

  localparam ST_IDLE = 3'd0;
  localparam ST_ARRAY_START = 3'd1;
  localparam ST_ARRAY_READY = 3'd2;
  localparam ST_ISSUE = 3'd3;
  localparam ST_DRAIN = 3'd4;
  localparam ST_DONE = 3'd5;
  localparam integer CACHE_LANES = CACHE_WORD_W / CACHE_ELEM_W;
  localparam [FEATURE_IDX_W:0] FEATURE_LIMIT = HEAD_DIM;
  localparam [FEATURE_IDX_W:0] FEATURE_LAST = HEAD_DIM - 1;

  reg [2:0] state_q;
  reg [FEATURE_IDX_W:0] issue_count_q;
  reg [FEATURE_IDX_W:0] receive_count_q;
  integer col;

`ifndef SYNTHESIS
  initial begin
    if (ARRAY_COLS != CACHE_LANES)
      $fatal(1, "fsa_pv_engine physical columns must equal CACHE_LANES");
    if (ARRAY_DATA_W != CACHE_ELEM_W)
      $fatal(1, "fsa_pv_engine requires a native INT8 array data path");
    if (CACHE_ADDR_W < FEATURE_IDX_W)
      $fatal(1, "fsa_pv_engine cache address is narrower than HEAD_DIM");
  end
`endif

  // receive_count_q is the feature ID of v_rd_data_i because cache responses are
  // ordered. array_feature_o and array_cols_o therefore describe the same V[:,d].
  always @(*) begin
    v_rd_en_o = (state_q == ST_ISSUE && issue_count_q < FEATURE_LIMIT);
    v_rd_addr_o = issue_count_q[CACHE_ADDR_W-1:0];
    array_start_o = (state_q == ST_ARRAY_START);
    array_seed_zero_o = first_kv_tile_i;
    array_valid_o = 1'b0;
    array_feature_o = receive_count_q[FEATURE_IDX_W-1:0];
    array_cols_o = {ARRAY_COLS*ARRAY_DATA_W{1'b0}};
    if ((state_q == ST_ISSUE || state_q == ST_DRAIN) && v_rd_valid_i) begin
      array_valid_o = 1'b1;
      // V remains signed INT8 on the same 32 vertical lanes used by K.
      for (col = 0; col < ARRAY_COLS; col = col + 1) begin
        array_cols_o[col*ARRAY_DATA_W +: ARRAY_DATA_W] =
            v_rd_data_i[col*CACHE_ELEM_W +: CACHE_ELEM_W];
      end
    end
  end

  // Start waits for the fused array to switch phase, then streams all HEAD_DIM
  // features continuously and drains the rightmost PE result.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      issue_count_q <= {(FEATURE_IDX_W+1){1'b0}};
      receive_count_q <= {(FEATURE_IDX_W+1){1'b0}};
      done_o <= 1'b0;
      busy_o <= 1'b0;
      error_o <= 1'b0;
    end else if (clear_i) begin
      state_q <= ST_IDLE;
      issue_count_q <= {(FEATURE_IDX_W+1){1'b0}};
      receive_count_q <= {(FEATURE_IDX_W+1){1'b0}};
      done_o <= 1'b0;
      busy_o <= 1'b0;
      error_o <= 1'b0;
    end else begin
      done_o <= 1'b0;
      case (state_q)
        ST_IDLE: begin
          busy_o <= 1'b0;
          if (start_i) begin
            busy_o <= 1'b1;
            state_q <= ST_ARRAY_START;
          end
        end
        ST_ARRAY_START: state_q <= ST_ARRAY_READY;
        ST_ARRAY_READY: begin
          if (array_ready_i) begin
            issue_count_q <= {(FEATURE_IDX_W+1){1'b0}};
            receive_count_q <= {(FEATURE_IDX_W+1){1'b0}};
            state_q <= ST_ISSUE;
          end
        end
        ST_ISSUE: begin
          if (issue_count_q < FEATURE_LIMIT)
            issue_count_q <= issue_count_q + 1'b1;
          if (v_rd_valid_i) begin
            receive_count_q <= receive_count_q + 1'b1;
            if (receive_count_q == FEATURE_LAST) state_q <= ST_DRAIN;
          end
        end
        ST_DRAIN: if (array_done_i) state_q <= ST_DONE;
        ST_DONE: begin
          done_o <= 1'b1;
          busy_o <= 1'b0;
          if (!start_i) state_q <= ST_IDLE;
        end
        default: begin
          error_o <= 1'b1;
          busy_o <= 1'b0;
          state_q <= ST_IDLE;
        end
      endcase
    end
  end

endmodule
