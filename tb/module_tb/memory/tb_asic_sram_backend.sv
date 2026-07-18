`timescale 1ns/1ps
`include "tb_fsdb.svh"

module tb_asic_sram_backend;
  `TB_FSDB_DUMP("tb_asic_sram_backend.fsdb", tb_asic_sram_backend)
  reg clk;
  reg rst_n;
  reg wr_en;
  reg [9:0] wr_addr;
  reg [255:0] wr_data;
  reg [15:0] wr_bank_en;
  reg rd_en;
  reg [9:0] rd_addr;
  wire [255:0] rd_data;
  wire rd_valid;

  reg wide_en;
  reg wide_wr_en;
  reg [7:0] wide_addr;
  reg [31:0] wide_wr_data;
  wire [31:0] wide_rd_data;

  banked_sram #(
    .BANKS(16),
    .BANK_W(16),
    .ADDR_W(10),
    .DEPTH(1024)
  ) dut_banked (
    .clk(clk),
    .rst_n(rst_n),
    .wr_en_i(wr_en),
    .wr_addr_i(wr_addr),
    .wr_data_i(wr_data),
    .wr_bank_en_i(wr_bank_en),
    .rd_en_i(rd_en),
    .rd_addr_i(rd_addr),
    .rd_data_o(rd_data),
    .rd_valid_o(rd_valid)
  );

  asic_sram_256xwide #(.WIDTH(32)) dut_wide (
    .clk(clk),
    .en_i(wide_en),
    .wr_en_i(wide_wr_en),
    .addr_i(wide_addr),
    .wr_data_i(wide_wr_data),
    .rd_data_o(wide_rd_data)
  );

  always #5 clk = ~clk;

  task write_banked;
    input [9:0] addr;
    input [255:0] data;
    begin
      @(negedge clk);
      wr_addr = addr;
      wr_data = data;
      wr_bank_en = 16'hffff;
      wr_en = 1'b1;
      @(negedge clk);
      wr_en = 1'b0;
      wr_bank_en = 16'h0000;
      @(posedge clk);
      #1;
    end
  endtask

  task read_check_banked;
    input [9:0] addr;
    input [255:0] expected;
    begin
      @(negedge clk);
      rd_addr = addr;
      rd_en = 1'b1;
      @(negedge clk);
      rd_en = 1'b0;
      wait (rd_valid === 1'b1);
      #1;
      if (rd_data !== expected) begin
        $fatal(1, "banked SRAM mismatch addr=%0d got=%h expected=%h", addr, rd_data, expected);
      end
      @(posedge clk);
    end
  endtask

  task write_wide;
    input [7:0] addr;
    input [31:0] data;
    begin
      @(negedge clk);
      wide_en = 1'b1;
      wide_wr_en = 1'b1;
      wide_addr = addr;
      wide_wr_data = data;
      @(posedge clk);
      #1;
      @(negedge clk);
      wide_en = 1'b0;
      wide_wr_en = 1'b0;
    end
  endtask

  task read_check_wide;
    input [7:0] addr;
    input [31:0] expected;
    begin
      @(negedge clk);
      wide_en = 1'b1;
      wide_wr_en = 1'b0;
      wide_addr = addr;
      @(posedge clk);
      #1;
      if (wide_rd_data !== expected) begin
        $fatal(1, "wide SRAM mismatch addr=%0d got=%h expected=%h", addr, wide_rd_data, expected);
      end
      @(negedge clk);
      wide_en = 1'b0;
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    wr_en = 1'b0;
    wr_addr = 10'd0;
    wr_data = 256'd0;
    wr_bank_en = 16'd0;
    rd_en = 1'b0;
    rd_addr = 10'd0;
    wide_en = 1'b0;
    wide_wr_en = 1'b0;
    wide_addr = 8'd0;
    wide_wr_data = 32'd0;

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    write_banked(10'd0,    {16{16'h1001}});
    write_banked(10'd255,  {16{16'h25a5}});
    write_banked(10'd256,  {16{16'h3c3c}});
    write_banked(10'd1023, {16{16'h4f0f}});

    read_check_banked(10'd0,    {16{16'h1001}});
    read_check_banked(10'd255,  {16{16'h25a5}});
    read_check_banked(10'd256,  {16{16'h3c3c}});
    read_check_banked(10'd1023, {16{16'h4f0f}});

    write_wide(8'd3, 32'h0123_4567);
    write_wide(8'd254, 32'h89ab_cdef);
    read_check_wide(8'd3, 32'h0123_4567);
    read_check_wide(8'd254, 32'h89ab_cdef);

    @(negedge clk);
    #1;
    if (dut_banked.g_bank[0].u_bank.g_depth[0].g_byte[0].u_sram.CEB !== 1'b1 ||
        dut_banked.g_bank[0].u_bank.g_depth[1].g_byte[0].u_sram.CEB !== 1'b1 ||
        dut_wide.g_byte[0].u_sram.CEB !== 1'b1) begin
      $fatal(1, "SRAM CEB must be inactive while idle");
    end

    $display("[PASS] tb_asic_sram_backend");
    $finish;
  end

endmodule
