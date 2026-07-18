`timescale 1ns/1ps
`include "attention_defines.vh"

module fsa_pv_engine #(
  parameter integer CACHE_ADDR_W = `ATTN_CACHE_ADDR_W,
  parameter integer CACHE_WORD_W = `ATTN_CACHE_WORD_W,
  parameter integer CACHE_ELEM_W = `ATTN_DATA_W,
  parameter integer ARRAY_ROWS = `ATTN_ARRAY_ROWS,
  parameter integer ARRAY_COLS = `ATTN_ARRAY_COLS,
  parameter integer ARRAY_DATA_W = `ATTN_ARRAY_DATA_W,
  parameter integer ACC_W = `ATTN_ACC_W,
  parameter integer BETA_W = `ATTN_BETA_W
)(
  input                              clk,
  input                              rst_n,
  input                              clear_i,
  input                              start_i,
  input                              feature_half_i,
  input                              first_kv_tile_i,
  input      [ARRAY_ROWS*BETA_W-1:0] alpha_rows_i,

  output reg                         old_acc_rd_en_o,
  output reg [((ARRAY_ROWS < 2) ? 1 : $clog2(ARRAY_ROWS))-1:0] old_acc_rd_row_o,
  output reg                         old_acc_rd_half_o,
  input      [ARRAY_COLS*ACC_W-1:0]  old_acc_rd_data_i,
  input                              old_acc_rd_valid_i,

  output reg                         v_rd_en_o,
  output reg [CACHE_ADDR_W-1:0]      v_rd_addr_o,
  input      [CACHE_WORD_W-1:0]      v_rd_data_i,
  input                              v_rd_valid_i,

  output reg                         array_start_o,
  input                              array_ready_i,
  output reg                         array_clear_acc_o,
  output reg                         array_load_row_valid_o,
  output reg [((ARRAY_ROWS < 2) ? 1 : $clog2(ARRAY_ROWS))-1:0] array_load_row_index_o,
  output reg [ARRAY_COLS*ACC_W-1:0]  array_load_row_data_o,
  output reg                         array_valid_o,
  output reg                         array_last_o,
  output reg [ARRAY_COLS*ARRAY_DATA_W-1:0] array_cols_o,
  input                              array_done_i,

  output reg                         done_o,
  output reg                         busy_o,
  output reg                         error_o
);

  localparam ST_IDLE = 4'd0;
  localparam ST_CLEAR_ACC = 4'd1;
  localparam ST_READ_OLD = 4'd2;
  localparam ST_WAIT_OLD = 4'd3;
  localparam ST_ARRAY_START = 4'd4;
  localparam ST_ARRAY_READY = 4'd5;
  localparam ST_ISSUE = 4'd6;
  localparam ST_DRAIN = 4'd7;
  localparam ST_DONE = 4'd8;
  localparam integer ROW_IDX_W = (ARRAY_ROWS < 2) ? 1 : $clog2(ARRAY_ROWS);
  localparam integer COL_IDX_W = (ARRAY_COLS < 2) ? 1 : $clog2(ARRAY_COLS);
  localparam integer EXT_W = ARRAY_DATA_W - CACHE_ELEM_W;
  localparam integer RESCALE_W = ACC_W + BETA_W;
  localparam integer RESCALE_SHIFT = `ATTN_BETA_FRAC;
  localparam [ROW_IDX_W-1:0] ROW_LAST = ARRAY_ROWS - 1;
  localparam [COL_IDX_W:0] COL_LIMIT = ARRAY_COLS;
  localparam [COL_IDX_W:0] COL_LAST = ARRAY_COLS - 1;

  reg [3:0] state_q;
  reg [ROW_IDX_W-1:0] row_count_q;
  reg [COL_IDX_W:0] issue_count_q;
  reg [COL_IDX_W:0] receive_count_q;
  reg signed [RESCALE_W-1:0] rescale_product_w;
  integer col;

  always @(*) begin
    old_acc_rd_en_o = (state_q == ST_READ_OLD);
    old_acc_rd_row_o = row_count_q;
    old_acc_rd_half_o = feature_half_i;
    v_rd_en_o = (state_q == ST_ISSUE && issue_count_q < COL_LIMIT);
    v_rd_addr_o = {{(CACHE_ADDR_W-COL_IDX_W-1){1'b0}},
                   issue_count_q[COL_IDX_W-1:0], feature_half_i};

    array_start_o = (state_q == ST_ARRAY_START);
    array_clear_acc_o = (state_q == ST_CLEAR_ACC);
    array_load_row_valid_o = (state_q == ST_WAIT_OLD && old_acc_rd_valid_i);
    array_load_row_index_o = row_count_q;
    array_load_row_data_o = {ARRAY_COLS*ACC_W{1'b0}};
    for (col = 0; col < ARRAY_COLS; col = col + 1) begin
      rescale_product_w =
          $signed({{BETA_W{old_acc_rd_data_i[col*ACC_W+ACC_W-1]}},
                   old_acc_rd_data_i[col*ACC_W +: ACC_W]}) *
          $signed({1'b0, alpha_rows_i[row_count_q*BETA_W +: BETA_W]});
      array_load_row_data_o[col*ACC_W +: ACC_W] =
          rescale_product_w[RESCALE_SHIFT+ACC_W-1:RESCALE_SHIFT];
    end

    array_valid_o = 1'b0;
    array_last_o = 1'b0;
    array_cols_o = {ARRAY_COLS*ARRAY_DATA_W{1'b0}};
    if ((state_q == ST_ISSUE || state_q == ST_DRAIN) && v_rd_valid_i) begin
      array_valid_o = 1'b1;
      array_last_o = (receive_count_q == COL_LAST);
      for (col = 0; col < ARRAY_COLS; col = col + 1) begin
        array_cols_o[col*ARRAY_DATA_W +: ARRAY_DATA_W] =
            {{EXT_W{v_rd_data_i[col*CACHE_ELEM_W+CACHE_ELEM_W-1]}},
             v_rd_data_i[col*CACHE_ELEM_W +: CACHE_ELEM_W]};
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      row_count_q <= {ROW_IDX_W{1'b0}};
      issue_count_q <= {(COL_IDX_W+1){1'b0}};
      receive_count_q <= {(COL_IDX_W+1){1'b0}};
      done_o <= 1'b0;
      busy_o <= 1'b0;
      error_o <= 1'b0;
    end else if (clear_i) begin
      state_q <= ST_IDLE;
      row_count_q <= {ROW_IDX_W{1'b0}};
      issue_count_q <= {(COL_IDX_W+1){1'b0}};
      receive_count_q <= {(COL_IDX_W+1){1'b0}};
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
            row_count_q <= {ROW_IDX_W{1'b0}};
            if (first_kv_tile_i)
              state_q <= ST_CLEAR_ACC;
            else
              state_q <= ST_READ_OLD;
          end
        end
        ST_CLEAR_ACC: state_q <= ST_ARRAY_START;
        ST_READ_OLD: state_q <= ST_WAIT_OLD;
        ST_WAIT_OLD: begin
          if (old_acc_rd_valid_i) begin
            if (row_count_q == ROW_LAST)
              state_q <= ST_ARRAY_START;
            else begin
              row_count_q <= row_count_q + 1'b1;
              state_q <= ST_READ_OLD;
            end
          end
        end
        ST_ARRAY_START: state_q <= ST_ARRAY_READY;
        ST_ARRAY_READY: begin
          if (array_ready_i) begin
            issue_count_q <= {(COL_IDX_W+1){1'b0}};
            receive_count_q <= {(COL_IDX_W+1){1'b0}};
            state_q <= ST_ISSUE;
          end
        end
        ST_ISSUE: begin
          if (issue_count_q < COL_LIMIT) issue_count_q <= issue_count_q + 1'b1;
          if (v_rd_valid_i) begin
            receive_count_q <= receive_count_q + 1'b1;
            if (receive_count_q == COL_LAST) state_q <= ST_DRAIN;
          end
        end
        ST_DRAIN: begin
          if (array_done_i) state_q <= ST_DONE;
        end
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
