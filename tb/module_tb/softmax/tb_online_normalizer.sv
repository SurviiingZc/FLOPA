`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"
module tb_online_normalizer;
  `TB_FSDB_DUMP("tb_online_normalizer.fsdb",tb_online_normalizer)
  localparam LANES=8,ACC_W=32,LSE_W=32,OUT_W=8,TAG_W=8;
  reg clk=0,rst_n=0,clock_en_i=1,valid_i=0; reg [LANES*ACC_W-1:0] acc_rows_i=0;
  reg [LANES*LSE_W-1:0] l_rows_i=0; reg [31:0] out_scale_i=0; reg [TAG_W-1:0] tag_i=0;
  wire valid_o; wire [LANES*OUT_W-1:0] out_rows_o; wire [TAG_W-1:0] tag_o;
  integer lane,seen,negative_expected,errors=0;
  online_normalizer #(.LANES(LANES),.TAG_W(TAG_W)) dut(.*);
  always #5 clk=~clk; `TB_TIMEOUT(100,"tb_online_normalizer")
  initial begin
    repeat(3) @(posedge clk); rst_n=1;

    // Two adjacent requests followed by a bubble and a third request prove that
    // lane data, tag, and shift metadata share the latency-2 multiplier contract.
    @(negedge clk);
    for(lane=0;lane<LANES;lane=lane+1) begin
      acc_rows_i[lane*ACC_W +: ACC_W]=(lane[0])?-32'sd32768:32'sd32768;
      l_rows_i[lane*LSE_W +: LSE_W]=32'd32768;
    end
    out_scale_i=32'd1; tag_i=8'ha5; valid_i=1;

    @(negedge clk);
    for(lane=0;lane<LANES;lane=lane+1)
      acc_rows_i[lane*ACC_W +: ACC_W]=(lane[0])?32'sd32768:-32'sd32768;
    tag_i=8'h3c;

    @(negedge clk); valid_i=0;
    @(negedge clk);
    for(lane=0;lane<LANES;lane=lane+1)
      acc_rows_i[lane*ACC_W +: ACC_W]=(lane[0])?-32'sd32768:32'sd32768;
    tag_i=8'h7e; valid_i=1;
    @(negedge clk); valid_i=0;

    // Regression for negative saturation after rounding. The reciprocal path
    // preserves -513 for l=32768; scale=1 and shift=2 produce shifted=-129
    // with increment=1, whose mathematically rounded result is exactly -128.
    @(negedge clk);
    for(lane=0;lane<LANES;lane=lane+1)
      acc_rows_i[lane*ACC_W +: ACC_W]=-32'sd513;
    out_scale_i=32'h0002_0001; tag_i=8'hd1; valid_i=1;
    @(negedge clk); valid_i=0;

    seen=0;
    while(seen<4) begin
      @(negedge clk);
      if(valid_o) begin
        case(seen)
          0: `TB_CHECK(tag_o==8'ha5,"normalizer first tag alignment")
          1: `TB_CHECK(tag_o==8'h3c,"normalizer adjacent tag alignment")
          2: `TB_CHECK(tag_o==8'h7e,"normalizer bubble tag alignment")
          default: `TB_CHECK(tag_o==8'hd1,"normalizer saturation tag alignment")
        endcase
        for(lane=0;lane<LANES;lane=lane+1) begin
          negative_expected = (seen==3) ? 1 :
                              ((seen==1) ? !lane[0] : lane[0]);
          if(negative_expected) begin
            `TB_CHECK($signed(out_rows_o[lane*OUT_W +: OUT_W])==-128,
                      "negative lane")
          end else begin
            `TB_CHECK($signed(out_rows_o[lane*OUT_W +: OUT_W])==127,
                      "positive lane")
          end
        end
        seen=seen+1;
      end
    end
    `TB_FINISH("tb_online_normalizer")
  end
endmodule
