`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"
module tb_o_accumulator_bank;
  `TB_FSDB_DUMP("tb_o_accumulator_bank.fsdb",tb_o_accumulator_bank)
  localparam ROWS=4,HEAD_DIM=64,GROUP_SIZE=32,DATA_W=32,FEATURE_IDX_W=6;
  reg clk=0,rst_n=0,clear_i=0,rd_en_i=0;
  reg [FEATURE_IDX_W-1:0] rd_feature_i=0; wire rd_valid_o;
  wire [ROWS*DATA_W-1:0] rd_data_o;
  reg [ROWS-1:0] wr_valid_i=0;
  reg [ROWS*FEATURE_IDX_W-1:0] wr_feature_i=0;
  reg [ROWS*DATA_W-1:0] wr_data_i=0;
  integer row,errors=0;
  o_accumulator_bank #(.ROWS(ROWS),.HEAD_DIM(HEAD_DIM),.GROUP_SIZE(GROUP_SIZE),
    .DATA_W(DATA_W),.FEATURE_IDX_W(FEATURE_IDX_W)) dut(.*);
  always #5 clk=~clk; `TB_TIMEOUT(100,"tb_o_accumulator_bank")
  task write_feature;
    input [FEATURE_IDX_W-1:0] feature;
    begin
      @(negedge clk); wr_valid_i={ROWS{1'b1}};
      for(row=0;row<ROWS;row=row+1) begin
        wr_feature_i[row*FEATURE_IDX_W +: FEATURE_IDX_W]=feature;
        wr_data_i[row*DATA_W +: DATA_W]=feature*100+row;
      end
      @(negedge clk); wr_valid_i=0;
    end
  endtask
  task read_feature;
    input [FEATURE_IDX_W-1:0] feature;
    begin
      @(negedge clk); rd_en_i=1; rd_feature_i=feature;
      @(negedge clk); rd_en_i=0; wait(rd_valid_o); #1;
      for(row=0;row<ROWS;row=row+1)
        if(rd_data_o[row*DATA_W +: DATA_W]!==feature*100+row) begin
          $error("[FAIL] feature=%0d row=%0d",feature,row); errors=errors+1;
        end
    end
  endtask
  initial begin
    repeat(3) @(posedge clk); rst_n=1;
    write_feature(3); write_feature(35); read_feature(3); read_feature(35);
    `TB_FINISH("tb_o_accumulator_bank")
  end
endmodule
