`timescale 1ns/1ps
`include "attention_defines.vh"

module os_fsa_array #(
  parameter ROWS = `ATTN_ARRAY_ROWS,
  parameter COLS = `ATTN_ARRAY_COLS,
  parameter DATA_W = `ATTN_ARRAY_DATA_W,
  parameter ACC_W = `ATTN_ACC_W
)(
  input                              clk,
  input                              rst_n,
  input                              valid_i,
  input                              last_i,
  input      [2:0]                   mode_i,
  input                              clear_acc_i,
  input                              load_acc_i,
  input      [ROWS*COLS*ACC_W-1:0]   load_matrix_i,
  input      [ROWS*DATA_W-1:0]       row_data_i,
  input      [COLS*DATA_W-1:0]       col_data_i,
  input signed [15:0]                scale_mant_i,
  input      [5:0]                   scale_shift_i,
  output reg                         valid_o,
  output reg                         last_o,
  output reg [ROWS*COLS*ACC_W-1:0]   matrix_o
);

  wire [ROWS*COLS*ACC_W-1:0] pe_acc_w;
  wire pe00_valid_w;
  wire pe00_last_w;
  reg capture_last_q;
  genvar stripe;
  genvar local_row;
  genvar col;

  generate
    for (stripe = 0; stripe < ROWS/8; stripe = stripe + 1) begin : g_stripe
    //seperate the whole array into stripes of 8 rows each, and instantiate 8xCOLS PEs for each stripe
      reg stripe_valid_q;
      reg stripe_last_q;
      reg [2:0] stripe_mode_q;
      reg stripe_clear_q;
      reg stripe_load_q;
      reg [8*DATA_W-1:0] stripe_rows_q;
      reg [COLS*DATA_W-1:0] stripe_cols_q;
      reg [8*COLS*ACC_W-1:0] stripe_load_matrix_q;
      reg signed [15:0] stripe_scale_q;
      reg [5:0] stripe_shift_q;

      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          stripe_valid_q <= 1'b0;
          stripe_last_q <= 1'b0;
          stripe_mode_q <= `ATTN_PE_HOLD;
          stripe_clear_q <= 1'b0;
          stripe_load_q <= 1'b0;
          stripe_rows_q <= {(8*DATA_W){1'b0}};
          stripe_cols_q <= {(COLS*DATA_W){1'b0}};
          stripe_load_matrix_q <= {(8*COLS*ACC_W){1'b0}};
          stripe_scale_q <= 16'sd0;
          stripe_shift_q <= 6'd0;
        end else begin
          stripe_valid_q <= valid_i;
          stripe_last_q <= last_i;
          stripe_mode_q <= mode_i;
          stripe_clear_q <= clear_acc_i;
          stripe_load_q <= load_acc_i;
          stripe_rows_q <= row_data_i[stripe*8*DATA_W +: 8*DATA_W];
          stripe_cols_q <= col_data_i;
          stripe_load_matrix_q <= load_matrix_i[stripe*8*COLS*ACC_W +: 8*COLS*ACC_W];
          stripe_scale_q <= scale_mant_i;
          stripe_shift_q <= scale_shift_i;
        end
      end

      for (local_row = 0; local_row < 8; local_row = local_row + 1) begin : g_row
        for (col = 0; col < COLS; col = col + 1) begin : g_col
          localparam integer ROW_INDEX = stripe*8 + local_row;
          wire pe_valid_w;
          wire pe_last_w;
          wire signed [ACC_W-1:0] pe_result_w;
          wire signed [ACC_W-1:0] pe_acc_local_w;
          os_fsa_pe #(.DATA_W(DATA_W), .ACC_W(ACC_W)) u_pe (
            .clk(clk), .rst_n(rst_n), .valid_i(stripe_valid_q), .last_i(stripe_last_q), .mode_i(stripe_mode_q),
            .clear_acc_i(stripe_clear_q), .load_acc_i(stripe_load_q),
            .load_data_i(stripe_load_matrix_q[(local_row*COLS+col)*ACC_W +: ACC_W]),
            .operand_a_i(stripe_rows_q[local_row*DATA_W +: DATA_W]),
            .operand_b_i(stripe_cols_q[col*DATA_W +: DATA_W]),
            .scale_mant_i(stripe_scale_q), .scale_shift_i(stripe_shift_q),
            .valid_o(pe_valid_w), .last_o(pe_last_w), .result_o(pe_result_w), .acc_o(pe_acc_local_w)
          );
          assign pe_acc_w[(ROW_INDEX*COLS+col)*ACC_W +: ACC_W] = pe_acc_local_w;
          if (ROW_INDEX == 0 && col == 0) begin : g_status
            assign pe00_valid_w = pe_valid_w;
            assign pe00_last_w = pe_last_w;
          end
        end
      end
    end
  endgenerate

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_o <= 1'b0;
      last_o <= 1'b0;
      capture_last_q <= 1'b0;
      matrix_o <= {(ROWS*COLS*ACC_W){1'b0}};
    end else begin
      valid_o <= pe00_valid_w;
      capture_last_q <= pe00_valid_w && pe00_last_w;
      last_o <= capture_last_q;
      if (capture_last_q) matrix_o <= pe_acc_w;
    end
  end

endmodule
