`timescale 1ns/1ps

module bram_buffer #(
  parameter DATA_W = 32,
  parameter ADDR_W = 10,
  parameter DEPTH = (1 << ADDR_W)
)(
  input                   clk,
  input                   wr_en_i,
  input      [ADDR_W-1:0] wr_addr_i,
  input      [DATA_W-1:0] wr_data_i,
  input                   rd_en_i,
  input      [ADDR_W-1:0] rd_addr_i,
  output reg [DATA_W-1:0] rd_data_o,
  output reg              rd_valid_o
);

  (* ram_style = "block" *) reg [DATA_W-1:0] mem [0:DEPTH-1];
  reg [ADDR_W-1:0] rd_addr_q;
  reg rd_en_q;

  always @(posedge clk) begin
    if (wr_en_i) mem[wr_addr_i] <= wr_data_i;
    rd_addr_q <= rd_addr_i;
    rd_en_q <= rd_en_i;
    rd_valid_o <= rd_en_q;
    if (rd_en_q) rd_data_o <= mem[rd_addr_q];
  end

endmodule
