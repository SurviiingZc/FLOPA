`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"

module tb_pv_engine;
  `TB_FSDB_DUMP("tb_pv_engine.fsdb", tb_pv_engine)
  reg clk=0, rst_n=0, clear_i=0, start_i=0, feature_half_i=1, first_kv_tile_i=1;
  reg [16383:0] beta_tile_i=0;
  reg [511:0] alpha_rows_i=0;
  wire old_acc_rd_en_o; wire [4:0] old_acc_rd_row_o; wire old_acc_rd_half_o;
  reg [1023:0] old_acc_rd_data_i=0; reg old_acc_rd_valid_i=0;
  wire v_rd_en_o; wire [9:0] v_rd_addr_o;
  reg [255:0] v_rd_data_i=0; reg v_rd_valid_i=0;
  wire array_load_o; wire [32767:0] array_load_matrix_o;
  wire array_valid_o, array_last_o; wire [511:0] array_rows_o, array_cols_o;
  reg array_last_i=0; reg [32767:0] array_matrix_i=0;
  wire row_valid_o; reg row_ready_i=0; wire [4:0] row_index_o; wire row_half_o;
  wire [1023:0] row_data_o; wire done_o, busy_o, error_o;
  integer errors=0, beat, row;
  pv_engine dut (.*);
  always #5 clk=~clk;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) v_rd_valid_i <= 0;
    else v_rd_valid_i <= v_rd_en_o;
  end
  `TB_TIMEOUT(500, "tb_pv_engine")

  initial begin
    for (row=0; row<32; row=row+1) begin
      beta_tile_i[(row*32)*16 +: 16]=row+1;
      array_matrix_i[row*1024 +: 32]=32'h1000+row;
    end
    v_rd_data_i[7:0]=8'hfe;
    repeat(3) @(posedge clk); rst_n=1;
    @(negedge clk); start_i=1;
    wait(array_load_o); #1;
    `TB_CHECK(array_load_matrix_o == 0, "first tile clears accumulator")
    for (beat=0; beat<32; beat=beat+1) begin
      wait(array_valid_o); #1;
      `TB_CHECK(array_valid_o, "PV array valid")
      `TB_CHECK($signed(array_cols_o[15:0]) == -2, "V sign extension")
      if (beat==31) `TB_CHECK(array_last_o, "PV last beat")
      @(posedge clk); #1;
    end
    @(negedge clk); array_last_i=1;
    @(negedge clk); array_last_i=0;
    wait(row_valid_o); #1;
    `TB_CHECK(row_index_o==0 && row_half_o && row_data_o[31:0]==32'h1000, "first streamed row")
    repeat(2) @(posedge clk); #1;
    `TB_CHECK(row_index_o==0 && row_valid_o, "output backpressure hold")
    row_ready_i=1;
    for (row=0; row<32; row=row+1) begin
      wait(row_valid_o); #1;
      `TB_CHECK(row_index_o==row, "row order")
      @(posedge clk); #1;
    end
    row_ready_i=0; start_i=0;
    wait(done_o); #1;
    `TB_CHECK(!busy_o && !error_o, "PV completion")
    `TB_FINISH("tb_pv_engine")
  end
endmodule
