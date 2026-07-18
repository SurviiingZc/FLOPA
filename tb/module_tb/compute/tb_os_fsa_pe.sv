`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "attention_defines.vh"

module tb_os_fsa_pe;
  `TB_FSDB_DUMP("tb_os_fsa_pe.fsdb", tb_os_fsa_pe)
  reg clk;
  reg rst_n;
  reg valid_i;
  reg last_i;
  reg [2:0] mode_i;
  reg clear_acc_i;
  reg load_acc_i;
  reg signed [31:0] load_data_i;
  reg signed [15:0] operand_a_i;
  reg signed [15:0] operand_b_i;
  wire valid_o;
  wire last_o;
  wire signed [31:0] result_o;
  wire signed [31:0] acc_o;

  os_fsa_pe dut (
    .clk(clk), .rst_n(rst_n), .valid_i(valid_i), .last_i(last_i), .mode_i(mode_i),
    .clear_acc_i(clear_acc_i), .load_acc_i(load_acc_i), .load_data_i(load_data_i),
    .operand_a_i(operand_a_i), .operand_b_i(operand_b_i), .scale_mant_i(16'sd1),
    .scale_shift_i(6'd0), .valid_o(valid_o), .last_o(last_o), .result_o(result_o), .acc_o(acc_o)
  );

  always #5 clk = ~clk;

  task send_op;
    input [2:0] mode;
    input signed [15:0] a;
    input signed [15:0] b;
    input last;
    begin
      @(negedge clk);
      mode_i = mode;
      operand_a_i = a;
      operand_b_i = b;
      last_i = last;
      valid_i = 1'b1;
      @(negedge clk);
      valid_i = 1'b0;
      last_i = 1'b0;
      wait (valid_o);
      #1;
    end
  endtask

  task send_continuous_mac;
    @(negedge clk);
    clear_acc_i = 1; 
    @(negedge clk); 
    clear_acc_i = 0;
    mode_i = `ATTN_PE_MAC_INT8;
    valid_i = 1;
    last_i = 0;
    operand_a_i = 16'sd1; operand_b_i = 16'sd2; 
    @(negedge clk);
    operand_a_i = 16'sd3; operand_b_i = 16'sd4; 
    @(negedge clk);
    operand_a_i = 16'sd5; operand_b_i = 16'sd6; 
    @(negedge clk);
    operand_a_i = 16'sd7; operand_b_i = 16'sd8; last_i = 1;
    @(negedge clk);
    valid_i = 0;
    last_i = 0;
    wait (last_o);  
    #1;
  endtask

  initial begin
    clk = 0; rst_n = 0; valid_i = 0; last_i = 0; mode_i = `ATTN_PE_HOLD;
    clear_acc_i = 0; load_acc_i = 0; load_data_i = 0; operand_a_i = 0; operand_b_i = 0;
    repeat (3) @(posedge clk); rst_n = 1;
    @(negedge clk); clear_acc_i = 1; @(negedge clk); clear_acc_i = 0;
    send_op(`ATTN_PE_MAC_INT8, 16'sd3, -16'sd2, 1'b0);
    send_op(`ATTN_PE_MAC_INT8, -16'sd4, 16'sd5, 1'b1);
    if (acc_o !== -32'sd26 || !last_o) $fatal(1, "MAC accumulation mismatch: %0d", acc_o);
    if (dut.scale_product_w !== 0) $fatal(1, "SCALE product must be zero in MAC mode");
    @(negedge clk); clear_acc_i = 1; @(negedge clk); clear_acc_i = 0;
    send_op(`ATTN_PE_MAC_INT8, 16'sd127, -16'sd128, 1'b0);
    if (acc_o !== -32'sd16256) $fatal(1, "INT8 boundary MAC mismatch: %0d", acc_o);
    send_op(`ATTN_PE_SUB, 16'sd9, 16'sd4, 1'b0);
    if (result_o !== 32'sd5) $fatal(1, "SUB mismatch: %0d", result_o);
    if (dut.product_w !== 0) $fatal(1, "MAC product must be zero in SUB mode");
    send_op(`ATTN_PE_MAX_PASS, -16'sd3, -16'sd7, 1'b0);
    if (result_o !== -32'sd3) $fatal(1, "MAX mismatch: %0d", result_o);
    
    send_continuous_mac();
    if (acc_o !== 32'sd100) $fatal(1, "Continuous MAC mismatch: expected 100, got %0d", acc_o);
    $display("[PASS] tb_os_fsa_pe");
    $finish;
  end
endmodule
