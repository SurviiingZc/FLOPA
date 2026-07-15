`timescale 1ns/1ps

module perf_counter (
  input         clk,
  input         rst_n,
  input         clear_i,
  input         cycle_en_i,
  input         stall_i,
  input         mac_valid_i,
  input         tile_done_i,
  output reg [63:0] cycle_count_o,
  output reg [63:0] stall_count_o,
  output reg [63:0] mac_count_o,
  output reg [31:0] tile_count_o
);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cycle_count_o <= 64'd0;
      stall_count_o <= 64'd0;
      mac_count_o <= 64'd0;
      tile_count_o <= 32'd0;
    end else if (clear_i) begin
      cycle_count_o <= 64'd0;
      stall_count_o <= 64'd0;
      mac_count_o <= 64'd0;
      tile_count_o <= 32'd0;
    end else begin
      if (cycle_en_i) cycle_count_o <= cycle_count_o + 64'd1;
      if (cycle_en_i && stall_i) stall_count_o <= stall_count_o + 64'd1;
      if (mac_valid_i) mac_count_o <= mac_count_o + 64'd1;
      if (tile_done_i) tile_count_o <= tile_count_o + 32'd1;
    end
  end

endmodule
