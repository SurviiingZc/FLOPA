`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "attention_defines.vh"

module tb_axi4_slave_if;
  `TB_FSDB_DUMP("tb_axi4_slave_if.fsdb", tb_axi4_slave_if)
  reg clk;
  reg rst_n;
  reg wr_block_i;
  reg rd_block_i;
  reg [31:0] awaddr;
  reg awvalid;
  wire awready;
  reg [31:0] wdata;
  reg [3:0] wstrb;
  reg wvalid;
  wire wready;
  reg [31:0] araddr;
  reg arvalid;
  wire arready;
  wire wr_fire;
  wire rd_fire;
  wire [31:0] wr_addr;
  wire [31:0] wr_data;
  wire [3:0] wr_strb;
  wire [31:0] rd_addr;

  axi4_slave_if dut (
    .clk(clk),
    .rst_n(rst_n),
    .wr_block_i(wr_block_i),
    .rd_block_i(rd_block_i),
    .s_axi_awaddr(awaddr),
    .s_axi_awvalid(awvalid),
    .s_axi_awready(awready),
    .s_axi_wdata(wdata),
    .s_axi_wstrb(wstrb),
    .s_axi_wvalid(wvalid),
    .s_axi_wready(wready),
    .s_axi_araddr(araddr),
    .s_axi_arvalid(arvalid),
    .s_axi_arready(arready),
    .wr_fire_o(wr_fire),
    .rd_fire_o(rd_fire),
    .wr_addr_o(wr_addr),
    .wr_data_o(wr_data),
    .wr_strb_o(wr_strb),
    .rd_addr_o(rd_addr)
  );

  always #5 clk = ~clk;

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    wr_block_i = 1'b0;
    rd_block_i = 1'b0;
    awaddr = 32'd0;
    awvalid = 1'b0;
    wdata = 32'd0;
    wstrb = 4'd0;
    wvalid = 1'b0;
    araddr = 32'd0;
    arvalid = 1'b0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    awaddr = 32'h0000_0040;
    wdata = 32'h5a5a_1234;
    wstrb = 4'hf;
    awvalid = 1'b1;
    wvalid = 1'b1;
    @(posedge clk);
    #1;
    if (!wr_fire) $fatal(1, "write fire missing");
    if (wr_addr != 32'h0000_0040) $fatal(1, "write addr mismatch");
    if (wr_data != 32'h5a5a_1234) $fatal(1, "write data mismatch");
    if (wr_strb != 4'hf) $fatal(1, "write strb mismatch");
    awvalid = 1'b0;
    wvalid = 1'b0;

    @(posedge clk);
    araddr = 32'h0000_0074;
    arvalid = 1'b1;
    @(posedge clk);
    #1;
    if (!rd_fire) $fatal(1, "read fire missing");
    if (rd_addr != 32'h0000_0074) $fatal(1, "read addr mismatch");
    arvalid = 1'b0;

    @(posedge clk);
    wr_block_i = 1'b1;
    #1;
    if (awready !== 1'b0 || wready !== 1'b0) $fatal(1, "write block did not deassert ready");
    wr_block_i = 1'b0;
    rd_block_i = 1'b1;
    #1;
    if (arready !== 1'b0) $fatal(1, "read block did not deassert ready");

    $display("[PASS] tb_axi4_slave_if");
    $finish;
  end
endmodule
