`timescale 1ns/1ps

module stream_fifo #(
  parameter DATA_W = 128,
  parameter DEPTH = 4,
  parameter PTR_W = 2
)(
  input                   clk,
  input                   rst_n,
  input                   clear_i,
  input      [DATA_W-1:0] in_data_i,
  input                   in_valid_i,
  output                  in_ready_o,
  output     [DATA_W-1:0] out_data_o,
  output                  out_valid_o,
  input                   out_ready_i,
  output reg [PTR_W:0]    level_o
);

  reg [DATA_W-1:0] mem [0:DEPTH-1];
  reg [PTR_W-1:0] wr_ptr_q;
  reg [PTR_W-1:0] rd_ptr_q;
  wire push_w;
  wire pop_w;

  assign in_ready_o = (level_o < DEPTH);
  assign out_valid_o = (level_o != 0);
  assign out_data_o = mem[rd_ptr_q];
  assign push_w = in_valid_i && in_ready_o;
  assign pop_w = out_valid_o && out_ready_i;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr_q <= {PTR_W{1'b0}};
      rd_ptr_q <= {PTR_W{1'b0}};
      level_o <= {(PTR_W+1){1'b0}};
    end else if (clear_i) begin
      wr_ptr_q <= {PTR_W{1'b0}};
      rd_ptr_q <= {PTR_W{1'b0}};
      level_o <= {(PTR_W+1){1'b0}};
    end else begin
      if (push_w) begin
        mem[wr_ptr_q] <= in_data_i;
        wr_ptr_q <= (wr_ptr_q == DEPTH-1) ? {PTR_W{1'b0}} : wr_ptr_q + 1'b1;
      end
      if (pop_w) begin
        rd_ptr_q <= (rd_ptr_q == DEPTH-1) ? {PTR_W{1'b0}} : rd_ptr_q + 1'b1;
      end
      case ({push_w, pop_w})
        2'b10: level_o <= level_o + 1'b1;
        2'b01: level_o <= level_o - 1'b1;
        default: level_o <= level_o;
      endcase
    end
  end

endmodule
