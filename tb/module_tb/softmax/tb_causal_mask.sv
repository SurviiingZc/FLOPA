`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "fixed_defs.vh"
`include "tb_common.svh"

module tb_causal_mask;
  `TB_FSDB_DUMP("tb_causal_mask.fsdb", tb_causal_mask)
  reg [127:0] score_i=0; reg [15:0] query_index_i,key_base_i,seq_q_i,seq_kv_i; reg causal_en_i;
  wire [127:0] score_o; wire [7:0] lane_valid_o; wire row_valid_o;
  integer errors=0,lane;
  causal_mask #(.LANES(8),.SCORE_W(16)) dut (.*);
  initial begin
    for(lane=0;lane<8;lane=lane+1) score_i[lane*16 +:16]=lane+10;
    query_index_i=3; key_base_i=0; seq_q_i=4; seq_kv_i=6; causal_en_i=1; #1;
    `TB_CHECK(row_valid_o && lane_valid_o==8'h0f, "causal lane mask")
    `TB_CHECK(score_o[3*16 +:16]==16'd13 && score_o[4*16 +:16]==`ATTN_SCORE_MIN, "masked score value")
    causal_en_i=0; #1;
    `TB_CHECK(lane_valid_o==8'h3f, "sequence tail mask")
    query_index_i=4; #1;
    `TB_CHECK(!row_valid_o && lane_valid_o==0, "query tail row mask")
    `TB_FINISH("tb_causal_mask")
  end
endmodule
