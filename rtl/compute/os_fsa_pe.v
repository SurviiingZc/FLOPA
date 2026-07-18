`timescale 1ns/1ps
`include "attention_defines.vh"

module os_fsa_pe #(
  parameter DATA_W = `ATTN_ARRAY_DATA_W,
  parameter ACC_W = `ATTN_ACC_W
)(
  input                        clk,
  input                        rst_n,
  input                        valid_i,
  input                        last_i,
  input      [2:0]             mode_i,
  input                        clear_acc_i,
  input                        load_acc_i,
  input signed [ACC_W-1:0]     load_data_i,
  input signed [DATA_W-1:0]    operand_a_i,
  input signed [DATA_W-1:0]    operand_b_i,
  input signed [15:0]          scale_mant_i,
  input      [5:0]             scale_shift_i,
  output reg                   valid_o,
  output reg                   last_o,
  output reg signed [ACC_W-1:0] result_o,
  output reg signed [ACC_W-1:0] acc_o
);
  
  reg valid_q;
  reg last_q;
  reg [2:0] mode_q;
  reg signed [DATA_W-1:0] a_q;
  reg signed [DATA_W-1:0] b_q;
  reg signed [15:0] scale_q;
  reg [5:0] shift_q;
  reg signed [2*DATA_W-1:0] product_w;
  reg signed [ACC_W:0] arithmetic_w;
  reg signed [DATA_W+16-1:0] scale_product_w;
  
  //gating signals for the arithmetic operations
  wire [DATA_W-1:0] a_mac = (mode_q == `ATTN_PE_MAC_INT8) ? a_q : {DATA_W{1'b0}};
  wire [DATA_W-1:0] b_mac = (mode_q == `ATTN_PE_MAC_INT8) ? b_q : {DATA_W{1'b0}};
    
  wire [DATA_W-1:0] a_scale = (mode_q == `ATTN_PE_SCALE) ? a_q : {DATA_W{1'b0}};
  wire [15:0]       s_scale = (mode_q == `ATTN_PE_SCALE) ? scale_q : 16'sd0;

  always @(*) begin
    product_w = {(2*DATA_W){1'b0}};
    scale_product_w = {(DATA_W+16){1'b0}};
    case (mode_q)
      `ATTN_PE_MAC_INT8: begin
        product_w = $signed({{DATA_W{a_mac[DATA_W-1]}}, a_mac}) *
                    $signed({{DATA_W{b_mac[DATA_W-1]}}, b_mac});
        arithmetic_w = {acc_o[ACC_W-1], acc_o} +
                       {product_w[2*DATA_W-1], product_w};
      end
      `ATTN_PE_SUB: arithmetic_w = {{(ACC_W+1-DATA_W){a_q[DATA_W-1]}}, a_q} -
                                    {{(ACC_W+1-DATA_W){b_q[DATA_W-1]}}, b_q};
      `ATTN_PE_MAX_PASS: arithmetic_w = ($signed(a_q) >= $signed(b_q)) ?
                                         {{(ACC_W+1-DATA_W){a_q[DATA_W-1]}}, a_q} :
                                         {{(ACC_W+1-DATA_W){b_q[DATA_W-1]}}, b_q};
      `ATTN_PE_ADD_PASS: arithmetic_w = {{(ACC_W+1-DATA_W){a_q[DATA_W-1]}}, a_q} +
                                         {{(ACC_W+1-DATA_W){b_q[DATA_W-1]}}, b_q};
      `ATTN_PE_SCALE: begin
        scale_product_w = $signed({{16{a_scale[DATA_W-1]}}, a_scale}) *
                          $signed(s_scale); 
        arithmetic_w = $signed({scale_product_w[DATA_W+15], scale_product_w}) >>> shift_q;
      end
      default: arithmetic_w = {acc_o[ACC_W-1], acc_o};
    endcase
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_q <= 1'b0;
      last_q <= 1'b0;
      mode_q <= `ATTN_PE_HOLD;
      a_q <= {DATA_W{1'b0}};
      b_q <= {DATA_W{1'b0}};
      scale_q <= 16'sd0;
      shift_q <= 6'd0;
      valid_o <= 1'b0;
      last_o <= 1'b0;
      result_o <= {ACC_W{1'b0}};
      acc_o <= {ACC_W{1'b0}};
    end else begin
      //update pipeline registers and output registers
      valid_q <= valid_i;
      last_q <= last_i;
      valid_o <= valid_q;
      last_o <= last_q && valid_q;
      if (valid_i) begin
        mode_q <= mode_i;
        a_q <= operand_a_i;
        b_q <= operand_b_i;
        scale_q <= scale_mant_i;
        shift_q <= scale_shift_i;
      end

      if (clear_acc_i) begin
        acc_o <= {ACC_W{1'b0}};
        result_o <= {ACC_W{1'b0}};
      end else if (load_acc_i) begin
        acc_o <= load_data_i;
        result_o <= load_data_i;
      end else if (valid_q) begin
        result_o <= arithmetic_w[ACC_W-1:0];
        if (mode_q == `ATTN_PE_MAC_INT8 || mode_q == `ATTN_PE_HOLD)
          acc_o <= arithmetic_w[ACC_W-1:0];
      end
    end
  end

endmodule
