`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"
module tb_output_buffer;
  `TB_FSDB_DUMP("tb_output_buffer.fsdb",tb_output_buffer)
  localparam ROWS=32,NORM_LANES=8,HEAD_DIM=50,OUT_W=8;
  localparam STRIPE_IDX_W=2,FEATURE_IDX_W=6;
  reg clk=0,rst_n=0,clock_en_i=1,clear_tile_i=0,norm_valid_i=0;
  reg [STRIPE_IDX_W-1:0] norm_stripe_i=0; reg [FEATURE_IDX_W-1:0] norm_feature_i=0;
  reg [NORM_LANES*OUT_W-1:0] norm_data_i=0; wire norm_ready_o,norm_group_done_o;
  reg stream_start_i=0; reg [15:0] stream_bytes_i=0; wire [127:0] stream_data_o;
  wire [15:0] stream_strb_o; wire stream_valid_o; reg stream_ready_i=0;
  wire stream_last_o,stream_busy_o,stream_done_o;
  reg [127:0] expected_first,expected_second;
  reg [255:0] expected_lane1,expected_lane7;
  reg [255:0] expected_partial0,expected_partial7;
  integer feature,lane,errors=0;
  output_buffer #(.HEAD_DIM(HEAD_DIM)) dut(.*);
  always #5 clk=~clk; `TB_TIMEOUT(600,"tb_output_buffer")
  initial begin
    expected_first=0; expected_second=0;
    expected_lane1=0; expected_lane7=0;
    expected_partial0=0; expected_partial7=0;
    for(feature=0;feature<16;feature=feature+1)
      expected_first[feature*8 +: 8]=feature[7:0];
    for(feature=0;feature<16;feature=feature+1)
      expected_second[feature*8 +: 8]=(feature+16);
    for(feature=0;feature<32;feature=feature+1) begin
      expected_lane1[feature*8 +: 8]=feature+1;
      expected_lane7[feature*8 +: 8]=feature+7;
    end
    for(feature=32;feature<HEAD_DIM;feature=feature+1) begin
      expected_partial0[(feature-32)*8 +: 8]=feature;
      expected_partial7[(feature-32)*8 +: 8]=feature+7;
    end
    repeat(3) @(posedge clk); rst_n=1;
    for(feature=0;feature<32;feature=feature+1) begin
      @(negedge clk); wait(norm_ready_o);
      norm_valid_i=1; norm_stripe_i=0; norm_feature_i=feature;
      for(lane=0;lane<NORM_LANES;lane=lane+1)
        norm_data_i[lane*OUT_W +: OUT_W]=feature+lane;
    end
    @(negedge clk); norm_valid_i=0;
    wait(norm_group_done_o);
    #1;
    `TB_CHECK(dut.out_mem[2]===expected_lane1,"fixed-port flush preserves lane 1")
    `TB_CHECK(dut.out_mem[14]===expected_lane7,"fixed-port flush preserves lane 7")
    @(negedge clk); stream_bytes_i=20; stream_start_i=1;
    @(negedge clk); stream_start_i=0;
    wait(stream_valid_o); #1;
    `TB_CHECK(stream_data_o==expected_first && stream_strb_o==16'hffff && !stream_last_o,"first packed beat")
    repeat(2) @(posedge clk); #1;
    `TB_CHECK(stream_valid_o && stream_data_o==expected_first,"stream backpressure hold")
    @(negedge clk); stream_ready_i=1; @(posedge clk); #1; @(negedge clk); stream_ready_i=0;
    wait(stream_valid_o); #1;
    `TB_CHECK(stream_data_o==expected_second && stream_strb_o==16'h000f && stream_last_o,"partial second beat")
    @(negedge clk); stream_ready_i=1; @(posedge clk); #1;
    `TB_CHECK(stream_done_o && !stream_busy_o,"stream completion")

    @(negedge clk); stream_ready_i=0;
    for(feature=32;feature<HEAD_DIM;feature=feature+1) begin
      @(negedge clk); wait(norm_ready_o);
      norm_valid_i=1; norm_stripe_i=0; norm_feature_i=feature;
      for(lane=0;lane<NORM_LANES;lane=lane+1)
        norm_data_i[lane*OUT_W +: OUT_W]=feature+lane;
    end
    @(negedge clk); norm_valid_i=0;
    wait(norm_group_done_o); #1;
    `TB_CHECK(dut.out_mem[1]===expected_partial0,"partial final group lane 0")
    `TB_CHECK(dut.out_mem[15]===expected_partial7,"partial final group lane 7")
    `TB_FINISH("tb_output_buffer")
  end
endmodule
