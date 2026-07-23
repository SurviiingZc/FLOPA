`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "attention_defines.vh"

module tb_fsa_fused_array;
  `TB_FSDB_DUMP("tb_fsa_fused_array.fsdb", tb_fsa_fused_array)
  localparam ROWS=4, STRIPE_ROWS=2, COLS=4, DATA_W=8;
  localparam SCORE_W=32, PROB_W=16, ACC_W=32, LSE_W=32, HEAD_DIM=8;
  localparam FEATURE_IDX_W=3, STRIPE_IDX_W=1;
  reg clk=0,rst_n=0,clock_en_i=1,clear_i=0,clear_rows_i=0;
  reg qk_clear_i=0,qk_valid_i=0,qk_last_i=0;
  reg [ROWS*DATA_W-1:0] qk_rows_i=0;
  reg [COLS*DATA_W-1:0] qk_cols_i=0;
  wire qk_last_o;
  reg softmax_start_i=0;
  reg [31:0] score_scale_i=32'h0000_0100;
  reg [15:0] q_base_i=0,k_base_i=0,seq_q_i=ROWS,seq_kv_i=COLS;
  reg causal_en_i=0;
  wire softmax_pv_ready_o,softmax_done_o,softmax_busy_o;
  reg pv_start_i=0,pv_seed_zero_i=1,pv_valid_i=0;
  reg [FEATURE_IDX_W-1:0] pv_feature_i=0;
  reg [COLS*DATA_W-1:0] pv_cols_i=0;
  wire pv_ready_o,pv_done_o;
  reg norm_rd_en_i=0;
  reg [STRIPE_IDX_W-1:0] norm_rd_stripe_i=0;
  reg [FEATURE_IDX_W-1:0] norm_rd_feature_i=0;
  wire norm_rd_valid_o;
  wire [STRIPE_ROWS*ACC_W-1:0] norm_rd_acc_o;
  wire [STRIPE_ROWS*LSE_W-1:0] norm_rd_l_o;
  wire [STRIPE_IDX_W-1:0] norm_rd_stripe_o;
  wire [FEATURE_IDX_W-1:0] norm_rd_feature_o;
  wire error_o;
  integer row,col,feature,errors=0;
  reg signed [31:0] observed;
  reg [15:0] expected_prob [0:ROWS-1][0:COLS-1];
  reg [31:0] expected_l [0:ROWS-1];

  fsa_fused_array #(
    .ROWS(ROWS),.STRIPE_ROWS(STRIPE_ROWS),.COLS(COLS),.DATA_W(DATA_W),
    .SCORE_W(SCORE_W),.PROB_W(PROB_W),.ACC_W(ACC_W),.LSE_W(LSE_W),
    .HEAD_DIM(HEAD_DIM),.FEATURE_IDX_W(FEATURE_IDX_W)
  ) dut (.*);
  always #5 clk=~clk;

  task check_o_feature;
    input [STRIPE_IDX_W-1:0] stripe;
    input [FEATURE_IDX_W-1:0] feature_id;
    integer local_row;
    integer global_row;
    begin
      @(negedge clk);
      norm_rd_en_i=1; norm_rd_stripe_i=stripe; norm_rd_feature_i=feature_id;
      @(negedge clk); norm_rd_en_i=0;
      wait(norm_rd_valid_o); #1;
      if(norm_rd_stripe_o!==stripe || norm_rd_feature_o!==feature_id) begin
        $error("[FAIL] norm read tag"); errors=errors+1;
      end
      for(local_row=0;local_row<STRIPE_ROWS;local_row=local_row+1) begin
        global_row=stripe*STRIPE_ROWS+local_row;
        observed=norm_rd_acc_o[local_row*ACC_W +: ACC_W];
        if(observed!==expected_prob[global_row][feature_id%COLS]) begin
          $error("[FAIL] O stripe=%0d row=%0d feature=%0d got=%0d exp=%0d",
                 stripe,local_row,feature_id,observed,
                 expected_prob[global_row][feature_id%COLS]);
          errors=errors+1;
        end
        if(norm_rd_l_o[local_row*LSE_W +: LSE_W]!==expected_l[global_row]) begin
          $error("[FAIL] l row=%0d got=%0d exp=%0d", global_row,
                 norm_rd_l_o[local_row*LSE_W +: LSE_W], expected_l[global_row]);
          errors=errors+1;
        end
      end
    end
  endtask

  // Continuous feature-major reads are the normalizer use case. The response
  // tag must select the same O[:,d] payload even while the next O-bank address
  // is issued, otherwise every output feature is shifted by one.
  task check_norm_read_stream;
    input [STRIPE_IDX_W-1:0] stripe;
    integer sent_feature;
    integer seen_feature;
    integer local_row;
    integer global_row;
    reg signed [31:0] stream_observed;
    begin
      seen_feature = 0;
      fork
        begin
          for (sent_feature = 0; sent_feature < HEAD_DIM;
               sent_feature = sent_feature + 1) begin
            @(negedge clk);
            norm_rd_en_i = 1'b1;
            norm_rd_stripe_i = stripe;
            norm_rd_feature_i = sent_feature[FEATURE_IDX_W-1:0];
          end
          @(negedge clk);
          norm_rd_en_i = 1'b0;
        end
        begin
          while (seen_feature < HEAD_DIM) begin
            @(negedge clk);
            if (norm_rd_valid_o) begin
              if (norm_rd_stripe_o !== stripe ||
                  norm_rd_feature_o !== seen_feature[FEATURE_IDX_W-1:0]) begin
                $error("[FAIL] streamed norm tag stripe=%0d feature=%0d exp_feature=%0d",
                       norm_rd_stripe_o, norm_rd_feature_o, seen_feature);
                errors = errors + 1;
              end
              for (local_row = 0; local_row < STRIPE_ROWS;
                   local_row = local_row + 1) begin
                global_row = stripe*STRIPE_ROWS + local_row;
                stream_observed =
                    norm_rd_acc_o[local_row*ACC_W +: ACC_W];
                if (stream_observed !==
                    expected_prob[global_row][seen_feature%COLS]) begin
                  $error("[FAIL] streamed O stripe=%0d row=%0d feature=%0d got=%0d exp=%0d",
                         stripe, local_row, seen_feature, stream_observed,
                         expected_prob[global_row][seen_feature%COLS]);
                  errors = errors + 1;
                end
              end
              seen_feature = seen_feature + 1;
            end
          end
        end
      join
    end
  endtask

  initial begin
    expected_prob[0][0]=16'd1632; expected_prob[0][1]=16'd4435;
    expected_prob[0][2]=16'd12055; expected_prob[0][3]=16'd32767;
    expected_prob[1][0]=16'd81; expected_prob[1][1]=16'd600;
    expected_prob[1][2]=16'd4435; expected_prob[1][3]=16'd32767;
    expected_prob[2][0]=16'd0; expected_prob[2][1]=16'd81;
    expected_prob[2][2]=16'd1632; expected_prob[2][3]=16'd32767;
    expected_prob[3][0]=16'd0; expected_prob[3][1]=16'd0;
    expected_prob[3][2]=16'd600; expected_prob[3][3]=16'd32767;
    expected_l[0]=32'd50889; expected_l[1]=32'd37883;
    expected_l[2]=32'd34480; expected_l[3]=32'd33367;
    repeat(4) @(posedge clk); rst_n=1;
    @(negedge clk); qk_clear_i=1; clear_rows_i=1;
    @(negedge clk); qk_clear_i=0; clear_rows_i=0;
    for(row=0;row<ROWS;row=row+1)
      qk_rows_i[row*DATA_W +: DATA_W]=row+1;
    for(col=0;col<COLS;col=col+1)
      qk_cols_i[col*DATA_W +: DATA_W]=col+1;
    qk_valid_i=1; qk_last_i=1;
    @(negedge clk); qk_valid_i=0; qk_last_i=0;
    wait(qk_last_o);
    @(negedge clk); softmax_start_i=1;
    @(negedge clk); softmax_start_i=0;
    wait(softmax_done_o);

    @(negedge clk); pv_start_i=1;
    @(negedge clk); pv_start_i=0;
    wait(pv_ready_o);
    for(feature=0;feature<HEAD_DIM;feature=feature+1) begin
      @(negedge clk);
      pv_cols_i=0;
      for(col=0;col<COLS;col=col+1)
        pv_cols_i[col*DATA_W +: DATA_W]=(col==(feature%COLS))?8'sd1:8'sd0;
      pv_feature_i=feature[FEATURE_IDX_W-1:0];
      pv_valid_i=1;
    end
    @(negedge clk); pv_valid_i=0;
    wait(pv_done_o);
    check_norm_read_stream(0);
    check_norm_read_stream(1);
    check_o_feature(0,0); check_o_feature(0,7);
    check_o_feature(1,3); check_o_feature(1,6);
    @(negedge clk);
    causal_en_i=1; qk_clear_i=1;
    @(negedge clk);
    qk_clear_i=0; #1;
    if(dut.lane_valid_q[0*COLS +: COLS]!==4'b0001 ||
       dut.lane_valid_q[1*COLS +: COLS]!==4'b0011 ||
       dut.lane_valid_q[2*COLS +: COLS]!==4'b0111 ||
       dut.lane_valid_q[3*COLS +: COLS]!==4'b1111) begin
      $error("[FAIL] registered causal thermometer mask=%b",dut.lane_valid_q);
      errors=errors+1;
    end
    if(softmax_busy_o || error_o) begin
      $error("[FAIL] status busy=%b error=%b",softmax_busy_o,error_o);
      errors=errors+1;
    end
    if(errors==0) $display("[PASS] tb_fsa_fused_array");
    else $fatal(1,"tb_fsa_fused_array failed errors=%0d",errors);
    $finish;
  end
  initial begin repeat(1400) @(posedge clk); $fatal(1,"timeout"); end
endmodule
