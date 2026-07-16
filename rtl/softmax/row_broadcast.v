`timescale 1ns/1ps

module row_broadcast #(
  parameter LANES = 32,
  parameter DATA_W = 16
)(
  input                         clk,
  input                         rst_n,
  input                         valid_i,
  input      [DATA_W-1:0]       row_value_i,
  output reg                    valid_o,
  output reg [LANES*DATA_W-1:0] lane_values_o
);

  integer lane;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_o <= 1'b0;
      lane_values_o <= {(LANES*DATA_W){1'b0}};
    end else begin
      valid_o <= valid_i;
      if (valid_i) begin
        for (lane = 0; lane < LANES; lane = lane + 1) begin
          lane_values_o[lane*DATA_W +: DATA_W] <= row_value_i;
        end
      end
    end
  end

endmodule
