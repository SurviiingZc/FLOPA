`timescale 1ns/1ps
`include "attention_defines.vh"

module qk_engine #(
  parameter CACHE_ADDR_W = `ATTN_CACHE_ADDR_W
)(
  input                              clk,
  input                              rst_n,
  input                              clear_i,
  input                              start_i,
  input      [7:0]                   head_dim_i,
  output reg                         q_rd_en_o,
  output reg [CACHE_ADDR_W-1:0]      q_rd_addr_o,
  input      [255:0]                 q_rd_data_i,
  input                              q_rd_valid_i,
  output reg                         k_rd_en_o,
  output reg [CACHE_ADDR_W-1:0]      k_rd_addr_o,
  input      [255:0]                 k_rd_data_i,
  input                              k_rd_valid_i,
  output reg                         array_clear_o,
  output reg                         array_valid_o,
  output reg                         array_last_o,
  output reg [32*16-1:0]             array_rows_o,
  output reg [32*16-1:0]             array_cols_o,
  input                              array_last_i,
  input      [32*32*32-1:0]          array_matrix_i,
  output reg [32*32*32-1:0]          score_tile_o,
  output reg                         done_o,
  output reg                         busy_o,
  output reg                         error_o
);

  localparam ST_IDLE = 3'd0;
  localparam ST_CLEAR = 3'd1;
  localparam ST_ISSUE = 3'd2;
  localparam ST_DRAIN = 3'd3;
  localparam ST_DONE = 3'd4;
  reg [2:0] state_q;
  reg [7:0] issue_count_q;
  reg [7:0] receive_count_q;
  integer lane;

  always @(*) begin
    q_rd_en_o = 1'b0;
    k_rd_en_o = 1'b0;
    q_rd_addr_o = {{(CACHE_ADDR_W-8){1'b0}}, issue_count_q};
    k_rd_addr_o = {{(CACHE_ADDR_W-8){1'b0}}, issue_count_q};
    array_clear_o = (state_q == ST_CLEAR);
    array_valid_o = 1'b0;
    array_last_o = 1'b0;
    array_rows_o = 512'd0;
    array_cols_o = 512'd0;
    if (state_q == ST_ISSUE && issue_count_q < head_dim_i) begin
      q_rd_en_o = 1'b1;
      k_rd_en_o = 1'b1;
    end
    if ((state_q == ST_ISSUE || state_q == ST_DRAIN) && q_rd_valid_i && k_rd_valid_i) begin
      array_valid_o = 1'b1;
      array_last_o = (receive_count_q == head_dim_i - 1'b1);
      for (lane = 0; lane < 32; lane = lane + 1) begin
        array_rows_o[lane*16 +: 16] = {{8{q_rd_data_i[lane*8+7]}}, q_rd_data_i[lane*8 +: 8]};
        array_cols_o[lane*16 +: 16] = {{8{k_rd_data_i[lane*8+7]}}, k_rd_data_i[lane*8 +: 8]};
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      issue_count_q <= 8'd0;
      receive_count_q <= 8'd0;
      score_tile_o <= {(32*32*32){1'b0}};
      done_o <= 1'b0;
      busy_o <= 1'b0;
      error_o <= 1'b0;
    end else if (clear_i) begin
      state_q <= ST_IDLE;
      issue_count_q <= 8'd0;
      receive_count_q <= 8'd0;
      done_o <= 1'b0;
      busy_o <= 1'b0;
      error_o <= 1'b0;
    end else begin
      done_o <= 1'b0;
      case (state_q)
        ST_IDLE: begin
          busy_o <= 1'b0;
          if (start_i) begin
            if (head_dim_i == 0 || head_dim_i > `ATTN_HEAD_DIM) begin
              error_o <= 1'b1;
            end else begin
              issue_count_q <= 8'd0;
              receive_count_q <= 8'd0;
              busy_o <= 1'b1;
              state_q <= ST_CLEAR;
            end
          end
        end
        ST_CLEAR: state_q <= ST_ISSUE;
        ST_ISSUE: begin
          if (issue_count_q < head_dim_i) issue_count_q <= issue_count_q + 1'b1;
          if (q_rd_valid_i ^ k_rd_valid_i) begin
            error_o <= 1'b1;
            state_q <= ST_IDLE;
            busy_o <= 1'b0;
          end else if (q_rd_valid_i && k_rd_valid_i) begin
            receive_count_q <= receive_count_q + 1'b1;
            if (receive_count_q == head_dim_i - 1'b1) state_q <= ST_DRAIN;
          end
        end
        ST_DRAIN: begin
          if (array_last_i) begin
            score_tile_o <= array_matrix_i;
            state_q <= ST_DONE;
          end
        end
        ST_DONE: begin
          done_o <= 1'b1;
          busy_o <= 1'b0;
          if (!start_i) state_q <= ST_IDLE;
        end
        default: begin
          error_o <= 1'b1;
          state_q <= ST_IDLE;
          busy_o <= 1'b0;
        end
      endcase
    end
  end

endmodule
