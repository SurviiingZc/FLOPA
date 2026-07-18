`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "attention_defines.vh"
`include "tb_common.svh"

module tb_os_fsa_array;
  `TB_FSDB_DUMP("tb_os_fsa_array.fsdb", tb_os_fsa_array)
  localparam ROWS=8, COLS=2, DATA_W=16, ACC_W=32;
  reg clk=0, rst_n=0, valid_i=0, last_i=0, clear_acc_i=0, load_acc_i=0;
  reg [2:0] mode_i=`ATTN_PE_MAC_INT8;
  reg [ROWS*COLS*ACC_W-1:0] load_matrix_i=0;
  reg [ROWS*DATA_W-1:0] row_data_i=0;
  reg [COLS*DATA_W-1:0] col_data_i=0;
  reg signed [15:0] scale_mant_i=0;
  reg [5:0] scale_shift_i=0;
  wire valid_o, last_o;
  wire [ROWS*COLS*ACC_W-1:0] matrix_o;
  integer errors=0, row, col;
  reg signed [31:0] observed;
  os_fsa_array #(.ROWS(ROWS),.COLS(COLS),.DATA_W(DATA_W),.ACC_W(ACC_W)) dut (.*);
  always #5 clk=~clk;
  `TB_TIMEOUT(150, "tb_os_fsa_array")

  initial begin
    repeat (3) @(posedge clk); rst_n=1;
    @(negedge clk); clear_acc_i=1;
    @(negedge clk); clear_acc_i=0;
    repeat (3) @(posedge clk);
    for (row=0; row<ROWS; row=row+1) row_data_i[row*DATA_W +: DATA_W]=row+1;
    col_data_i[0 +: DATA_W]=16'sd2;
    col_data_i[DATA_W +: DATA_W]=-16'sd3;
    @(negedge clk); valid_i=1; last_i=1;
    @(negedge clk); valid_i=0; last_i=0;
    wait(last_o); #1;
    for (row=0; row<ROWS; row=row+1) begin
      for (col=0; col<COLS; col=col+1) begin
        observed=matrix_o[(row*COLS+col)*ACC_W +: ACC_W];
        if (col==0) begin
          if (observed !== (row+1)*2) begin
            $error("[FAIL] array positive MAC row=%0d got=%0d expected=%0d", row, observed, (row+1)*2);
            errors=errors+1;
          end
        end else begin
          if (observed !== -((row+1)*3)) begin
            $error("[FAIL] array negative MAC row=%0d got=%0d expected=%0d", row, observed, -((row+1)*3));
            errors=errors+1;
          end
        end
      end
    end
    `TB_FINISH("tb_os_fsa_array")
  end
endmodule
