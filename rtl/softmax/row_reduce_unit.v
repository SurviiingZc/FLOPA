`timescale 1ns/1ps
`include "attention_defines.vh"
`include "fixed_defs.vh"

module row_reduce_unit #(
  parameter LANES = 32,
  parameter IN_W = 16,
  parameter OUT_W = 32
)(
  input                         clk,
  input                         rst_n,
  input                         valid_i,
  input                         mode_i,
  input      [LANES-1:0]        lane_valid_i,
  input      [LANES*IN_W-1:0]   data_i,
  output reg                    valid_o,
  output reg signed [OUT_W-1:0] result_o
);

  reg signed [OUT_W-1:0] s1_q [0:15];
  reg signed [OUT_W-1:0] s2_q [0:7];
  reg signed [OUT_W-1:0] s3_q [0:3];
  reg signed [OUT_W-1:0] s4_q [0:1];
  reg signed [OUT_W-1:0] s5_q;
  reg [4:0] valid_q;
  reg [4:0] mode_q;
  reg signed [OUT_W-1:0] lhs_w;
  reg signed [OUT_W-1:0] rhs_w;
  integer idx;

  function signed [OUT_W-1:0] reduce_pair;
    input signed [OUT_W-1:0] lhs;
    input signed [OUT_W-1:0] rhs;
    input op_mode;
    begin
      if (op_mode == `ATTN_REDUCE_SUM) reduce_pair = lhs + rhs;
      else reduce_pair = (lhs >= rhs) ? lhs : rhs;
    end
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_q <= 5'd0;
      mode_q <= 5'd0;
      valid_o <= 1'b0;
      result_o <= {OUT_W{1'b0}};
      s5_q <= {OUT_W{1'b0}};
    end else begin
      valid_q <= {valid_q[3:0], valid_i};
      mode_q <= {mode_q[3:0], mode_i};
      valid_o <= valid_q[4];
      if (valid_i) begin
        for (idx = 0; idx < 16; idx = idx + 1) begin
          if (mode_i == `ATTN_REDUCE_SUM) begin
            lhs_w = lane_valid_i[2*idx] ? {{(OUT_W-IN_W){1'b0}}, data_i[(2*idx)*IN_W +: IN_W]} : {OUT_W{1'b0}};
            rhs_w = lane_valid_i[2*idx+1] ? {{(OUT_W-IN_W){1'b0}}, data_i[(2*idx+1)*IN_W +: IN_W]} : {OUT_W{1'b0}};
          end else begin
            lhs_w = lane_valid_i[2*idx] ? {{(OUT_W-IN_W){data_i[(2*idx+1)*IN_W-1]}}, data_i[(2*idx)*IN_W +: IN_W]} : {{(OUT_W-16){1'b1}}, `ATTN_SCORE_MIN};
            rhs_w = lane_valid_i[2*idx+1] ? {{(OUT_W-IN_W){data_i[(2*idx+2)*IN_W-1]}}, data_i[(2*idx+1)*IN_W +: IN_W]} : {{(OUT_W-16){1'b1}}, `ATTN_SCORE_MIN};
          end
          s1_q[idx] <= reduce_pair(lhs_w, rhs_w, mode_i);
        end
      end
      if (valid_q[0]) begin
        for (idx = 0; idx < 8; idx = idx + 1)
          s2_q[idx] <= reduce_pair(s1_q[2*idx], s1_q[2*idx+1], mode_q[0]);
      end
      if (valid_q[1]) begin
        for (idx = 0; idx < 4; idx = idx + 1)
          s3_q[idx] <= reduce_pair(s2_q[2*idx], s2_q[2*idx+1], mode_q[1]);
      end
      if (valid_q[2]) begin
        for (idx = 0; idx < 2; idx = idx + 1)
          s4_q[idx] <= reduce_pair(s3_q[2*idx], s3_q[2*idx+1], mode_q[2]);
      end
      if (valid_q[3]) s5_q <= reduce_pair(s4_q[0], s4_q[1], mode_q[3]);
      if (valid_q[4]) result_o <= s5_q;
    end
  end

endmodule
