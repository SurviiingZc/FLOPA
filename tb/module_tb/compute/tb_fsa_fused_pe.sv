`timescale 1ns/1ps
`include "tb_fsdb.svh"

module tb_fsa_fused_pe;
  `TB_FSDB_DUMP("tb_fsa_fused_pe.fsdb", tb_fsa_fused_pe)

  localparam DATA_W=8, SCORE_W=32, PROB_W=16, SUM_W=32, TAG_W=6;
  reg clk=0,rst_n=0,clear_i=0,clear_score_i=0;
  reg q_valid_i=0; reg [DATA_W-1:0] q_data_i=0; wire q_valid_o; wire [DATA_W-1:0] q_data_o;
  reg k_valid_i=0; reg [DATA_W-1:0] k_data_i=0; wire k_valid_o; wire [DATA_W-1:0] k_data_o;
  reg score_lane_valid_i=1;
  reg max_valid_i=0; reg [SCORE_W-1:0] max_data_i=0; wire max_valid_o; wire [SCORE_W-1:0] max_data_o;
  reg m_valid_i=0; reg [SCORE_W-1:0] m_data_i=0; wire m_valid_o; wire [SCORE_W-1:0] m_data_o;
  wire [SCORE_W-1:0] delta_o;
  reg prob_load_i=0; reg [PROB_W-1:0] prob_data_i=0;
  reg pv_mac_valid_i=0;
  reg sum_valid_i=0; reg [SUM_W-1:0] sum_data_i=0; reg [TAG_W-1:0] sum_tag_i=0;
  wire sum_valid_o; wire [SUM_W-1:0] sum_data_o; wire [TAG_W-1:0] sum_tag_o;
  integer errors=0;

  fsa_fused_pe #(.DATA_W(DATA_W),.SCORE_W(SCORE_W),.PROB_W(PROB_W),
    .SUM_W(SUM_W),.TAG_W(TAG_W)) dut(.*);

  always #5 clk=~clk;

  task clear_score;
    begin
      @(negedge clk); clear_score_i=1;
      @(negedge clk); clear_score_i=0;
    end
  endtask

  task qk_mac;
    input signed [7:0] q;
    input signed [7:0] k;
    input signed [31:0] expected;
    begin
      @(negedge clk); q_data_i=q; k_data_i=k; q_valid_i=1; k_valid_i=1;
      @(negedge clk); q_valid_i=0; k_valid_i=0;
      #1;
      if ($signed(delta_o)!==expected) begin
        $error("[FAIL] QK q=%0d k=%0d got=%0d exp=%0d",q,k,$signed(delta_o),expected);
        errors=errors+1;
      end
    end
  endtask

  initial begin
    repeat(3) @(posedge clk); rst_n=1;
    clear_score(); qk_mac(-8'sd128,-8'sd128,32'sd16384);
    clear_score(); qk_mac(8'sd127,-8'sd128,-32'sd16256);
    clear_score(); qk_mac(-8'sd128,8'sd127,-32'sd16256);

    @(negedge clk); prob_data_i=16'd32767; prob_load_i=1;
    @(negedge clk); prob_load_i=0;
    k_data_i=-8'sd128; k_valid_i=1; sum_valid_i=1; pv_mac_valid_i=1;
    sum_data_i=32'sd100; sum_tag_i=6'd17;
    @(negedge clk); k_valid_i=0; sum_valid_i=0; pv_mac_valid_i=0;
    wait(sum_valid_o); #1;
    if($signed(sum_data_o)!==-32'sd4194076 || sum_tag_o!==6'd17) begin
      $error("[FAIL] PV negative got=%0d tag=%0d",$signed(sum_data_o),sum_tag_o);
      errors=errors+1;
    end

    @(negedge clk); k_data_i=8'sd127; k_valid_i=1; sum_valid_i=1; pv_mac_valid_i=1;
    sum_data_i=-32'sd9; sum_tag_i=6'd31;
    @(negedge clk); k_valid_i=0; sum_valid_i=0; pv_mac_valid_i=0;
    wait(sum_valid_o); #1;
    if($signed(sum_data_o)!==32'sd4161400 || sum_tag_o!==6'd31) begin
      $error("[FAIL] PV positive got=%0d tag=%0d",$signed(sum_data_o),sum_tag_o);
      errors=errors+1;
    end

    if(errors==0) $display("[PASS] tb_fsa_fused_pe");
    else $fatal(1,"tb_fsa_fused_pe failed errors=%0d",errors);
    $finish;
  end

  initial begin repeat(100) @(posedge clk); $fatal(1,"timeout"); end
endmodule
