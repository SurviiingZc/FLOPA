`timescale 1ns/1ps
`include "fixed_defs.vh"

module causal_mask #(
  parameter LANES = 32,
  parameter SCORE_W = 16
)(
  input      [LANES*SCORE_W-1:0] score_i,
  input      [15:0]              query_index_i,
  input      [15:0]              key_base_i,
  input      [15:0]              seq_q_i,
  input      [15:0]              seq_kv_i,
  input                          causal_en_i,
  output reg [LANES*SCORE_W-1:0] score_o,
  output reg [LANES-1:0]         lane_valid_o,
  output                         row_valid_o
);

  integer lane;
  reg [15:0] key_index_w;
  reg lane_valid_w;

  assign row_valid_o = (query_index_i < seq_q_i);

  always @(*) begin
    score_o = {LANES*SCORE_W{1'b0}};
    lane_valid_o = {LANES{1'b0}};
    for (lane = 0; lane < LANES; lane = lane + 1) begin
      key_index_w = key_base_i + lane[15:0];
      lane_valid_w = row_valid_o && (key_index_w < seq_kv_i) &&
                     (!causal_en_i || (key_index_w <= query_index_i));
      lane_valid_o[lane] = lane_valid_w;
      if (lane_valid_w) score_o[lane*SCORE_W +: SCORE_W] = score_i[lane*SCORE_W +: SCORE_W];
      else score_o[lane*SCORE_W +: SCORE_W] = `ATTN_SCORE_MIN;
    end
  end

endmodule
