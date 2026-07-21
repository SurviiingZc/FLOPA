`timescale 1ns/1ps
`include "tb_fsdb.svh"

module tb_fa_signed_mult_pipe2;
  `TB_FSDB_DUMP("tb_fa_signed_mult_pipe2.fsdb", tb_fa_signed_mult_pipe2)

  localparam A_W=48, B_W=16, PRODUCT_W=A_W+B_W;
  reg clk=0,rst_n=0,valid_i=0;
  reg signed [A_W-1:0] a_i=0;
  reg signed [B_W-1:0] b_i=0;
  wire valid_o;
  wire signed [PRODUCT_W-1:0] product_o;
  reg ref_valid_s1=0,ref_valid_s2=0;
  reg signed [PRODUCT_W-1:0] ref_product_s1;
  reg signed [PRODUCT_W-1:0] ref_product_s2;
  integer errors=0;
  integer vector_index;
  reg [31:0] random_hi;
  reg [31:0] random_lo;

  fa_signed_mult_pipe2 #(
    .A_W(A_W), .B_W(B_W), .SPLIT_W(24)
  ) dut (.*);

  always #5 clk=~clk;

  // Independent two-cycle reference queue. Explicit A extension establishes
  // the full 64-bit product context for mixed-width Verilog multiplication.
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      ref_valid_s1<=0;
      ref_valid_s2<=0;
    end else begin
      ref_valid_s1<=valid_i;
      ref_valid_s2<=ref_valid_s1;
      if(valid_i)
        ref_product_s1<=
            $signed({{B_W{a_i[A_W-1]}},a_i})*$signed(b_i);
      if(ref_valid_s1)
        ref_product_s2<=ref_product_s1;
    end
  end

  always @(negedge clk) begin
    if(rst_n) begin
      if(valid_o!==ref_valid_s2) begin
        $error("[FAIL] multiplier valid got=%b expected=%b",valid_o,ref_valid_s2);
        errors=errors+1;
      end else if(valid_o && product_o!==ref_product_s2) begin
        $error("[FAIL] multiplier a=%0d b=%0d got=%0d expected=%0d",
               $signed(a_i),$signed(b_i),$signed(product_o),
               $signed(ref_product_s2));
        errors=errors+1;
      end
    end
  end

  task drive;
    input signed [A_W-1:0] a;
    input signed [B_W-1:0] b;
    input valid;
    begin
      @(negedge clk); a_i=a; b_i=b; valid_i=valid;
    end
  endtask

  initial begin
    repeat(3) @(posedge clk); rst_n=1;
    drive(48'sh7fff_ffff_ffff,16'sh7fff,1);
    drive(48'sh8000_0000_0000,16'sh8000,1);
    drive(48'sh8000_0000_0000,16'sh7fff,1);
    drive(48'sh7fff_ffff_ffff,16'sh8000,1);
    drive(48'sh0000_00ff_ffff,16'shffff,1);
    drive(48'shffff_ff00_0001,16'sh0003,1);
    drive(0,0,0);
    for(vector_index=0;vector_index<300;vector_index=vector_index+1) begin
      random_hi=$random;
      random_lo=$random;
      drive({random_hi[15:0],random_lo},$random,(vector_index%7)!=3);
    end
    drive(0,0,0); drive(0,0,0); drive(0,0,0);
    if(errors==0) $display("[PASS] tb_fa_signed_mult_pipe2");
    else $fatal(1,"tb_fa_signed_mult_pipe2 failed errors=%0d",errors);
    $finish;
  end

  initial begin repeat(400) @(posedge clk); $fatal(1,"timeout"); end
endmodule
