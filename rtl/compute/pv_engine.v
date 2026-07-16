`timescale 1ns/1ps
`include "attention_defines.vh"

module pv_engine #(
  parameter CACHE_ADDR_W = `ATTN_CACHE_ADDR_W
)(
  input                              clk,
  input                              rst_n,
  input                              clear_i,
  input                              start_i,
  input                              feature_half_i,
  input                              first_kv_tile_i,
  input      [32*32*16-1:0]          beta_tile_i,
  input      [32*16-1:0]             alpha_rows_i,
  output reg                         old_acc_rd_en_o,
  output reg [4:0]                   old_acc_rd_row_o,
  output reg                         old_acc_rd_half_o,
  input      [32*32-1:0]             old_acc_rd_data_i,
  input                              old_acc_rd_valid_i,
  output reg                         v_rd_en_o,
  output reg [CACHE_ADDR_W-1:0]      v_rd_addr_o,
  input      [255:0]                 v_rd_data_i,
  input                              v_rd_valid_i,
  output reg                         array_load_o,
  output reg [32*32*32-1:0]          array_load_matrix_o,
  output reg                         array_valid_o,
  output reg                         array_last_o,
  output reg [32*16-1:0]             array_rows_o,
  output reg [32*16-1:0]             array_cols_o,
  input                              array_last_i,
  input      [32*32*32-1:0]          array_matrix_i,
  output reg                         row_valid_o,
  input                              row_ready_i,
  output reg [4:0]                   row_index_o,
  output reg                         row_half_o,
  output reg [32*32-1:0]             row_data_o,
  output reg                         done_o,
  output reg                         busy_o,
  output reg                         error_o
);

  localparam ST_IDLE = 4'd0;
  localparam ST_READ_OLD = 4'd1;
  localparam ST_WAIT_OLD = 4'd2;
  localparam ST_LOAD = 4'd3;
  localparam ST_ISSUE = 4'd4;
  localparam ST_DRAIN = 4'd5;
  localparam ST_STREAM = 4'd6;
  localparam ST_DONE = 4'd7;
  reg [3:0] state_q;
  reg [4:0] row_count_q;
  reg [5:0] issue_count_q;
  reg [5:0] receive_count_q;
  reg [4:0] stream_row_q;
  reg signed [32*32*32-1:0] init_matrix_q;
  reg signed [47:0] rescale_product_w;
  integer row;
  integer col;

  always @(*) begin
    old_acc_rd_en_o = (state_q == ST_READ_OLD);
    old_acc_rd_row_o = row_count_q;
    old_acc_rd_half_o = feature_half_i;
    v_rd_en_o = (state_q == ST_ISSUE && issue_count_q < 32);
    v_rd_addr_o = {{(CACHE_ADDR_W-6){1'b0}}, issue_count_q[4:0], feature_half_i};
    array_load_o = (state_q == ST_LOAD);
    array_load_matrix_o = init_matrix_q;
    array_valid_o = 1'b0;
    array_last_o = 1'b0;
    array_rows_o = 512'd0;
    array_cols_o = 512'd0;
    if ((state_q == ST_ISSUE || state_q == ST_DRAIN) && v_rd_valid_i) begin
      array_valid_o = 1'b1;
      array_last_o = (receive_count_q == 31);
      for (row = 0; row < 32; row = row + 1) begin
        array_rows_o[row*16 +: 16] = beta_tile_i[(row*32+receive_count_q[4:0])*16 +: 16];
      end
      for (col = 0; col < 32; col = col + 1) begin
        array_cols_o[col*16 +: 16] = {{8{v_rd_data_i[col*8+7]}}, v_rd_data_i[col*8 +: 8]};
      end
    end
    row_valid_o = (state_q == ST_STREAM);
    row_index_o = stream_row_q;
    row_half_o = feature_half_i;
    row_data_o = array_matrix_i[stream_row_q*32*32 +: 32*32];
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      row_count_q <= 5'd0;
      issue_count_q <= 6'd0;
      receive_count_q <= 6'd0;
      stream_row_q <= 5'd0;
      init_matrix_q <= {(32*32*32){1'b0}};
      done_o <= 1'b0;
      busy_o <= 1'b0;
      error_o <= 1'b0;
    end else if (clear_i) begin
      state_q <= ST_IDLE;
      row_count_q <= 5'd0;
      issue_count_q <= 6'd0;
      receive_count_q <= 6'd0;
      stream_row_q <= 5'd0;
      init_matrix_q <= {(32*32*32){1'b0}};
      done_o <= 1'b0;
      busy_o <= 1'b0;
      error_o <= 1'b0;
    end else begin
      done_o <= 1'b0;
      case (state_q)
        ST_IDLE: begin
          busy_o <= 1'b0;
          if (start_i) begin
            row_count_q <= 5'd0;
            busy_o <= 1'b1;
            if (first_kv_tile_i) begin
              init_matrix_q <= {(32*32*32){1'b0}};
              state_q <= ST_LOAD;
            end else begin
              state_q <= ST_READ_OLD;
            end
          end
        end
        ST_READ_OLD: state_q <= ST_WAIT_OLD;
        ST_WAIT_OLD: begin
          if (old_acc_rd_valid_i) begin
            for (col = 0; col < 32; col = col + 1) begin
              rescale_product_w = $signed({{16{old_acc_rd_data_i[col*32+31]}},
                                           old_acc_rd_data_i[col*32 +: 32]}) *
                                  $signed({32'd0, alpha_rows_i[row_count_q*16 +: 16]});
              init_matrix_q[(row_count_q*32+col)*32 +: 32] <= rescale_product_w[46:15];
            end
            if (row_count_q == 31) begin
              state_q <= ST_LOAD;
            end else begin
              row_count_q <= row_count_q + 1'b1;
              state_q <= ST_READ_OLD;
            end
          end
        end
        ST_LOAD: begin
          issue_count_q <= 6'd0;
          receive_count_q <= 6'd0;
          state_q <= ST_ISSUE;
        end
        ST_ISSUE: begin
          if (issue_count_q < 32) issue_count_q <= issue_count_q + 1'b1;
          if (v_rd_valid_i) begin
            receive_count_q <= receive_count_q + 1'b1;
            if (receive_count_q == 31) state_q <= ST_DRAIN;
          end
        end
        ST_DRAIN: begin
          if (array_last_i) begin
            stream_row_q <= 5'd0;
            state_q <= ST_STREAM;
          end
        end
        ST_STREAM: begin
          if (row_ready_i) begin
            if (stream_row_q == 31) state_q <= ST_DONE;
            else stream_row_q <= stream_row_q + 1'b1;
          end
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
