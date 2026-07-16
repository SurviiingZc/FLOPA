`timescale 1ns/1ps
`include "attention_defines.vh"

module output_buffer #(
  parameter ROWS = 32,
  parameter HEAD_DIM = 64,
  parameter ACC_W = 32,
  parameter OUT_W = 8
)(
  input                         clk,
  input                         rst_n,
  input                         clear_tile_i,
  input                         acc_wr_valid_i,
  input      [4:0]              acc_wr_row_i,
  input                         acc_wr_half_i,
  input      [32*ACC_W-1:0]     acc_wr_data_i,
  input                         acc_rd_en_i,
  input      [4:0]              acc_rd_row_i,
  input                         acc_rd_half_i,
  output     [32*ACC_W-1:0]     acc_rd_data_o,
  output reg                    acc_rd_valid_o,
  input                         out_wr_valid_i,
  input      [4:0]              out_wr_row_i,
  input                         out_wr_half_i,
  input      [32*OUT_W-1:0]     out_wr_data_i,
  input                         stream_start_i,
  input      [15:0]             stream_bytes_i,
  output     [127:0]            stream_data_o,
  output reg [15:0]             stream_strb_o,
  output reg                    stream_valid_o,
  input                         stream_ready_i,
  output                        stream_last_o,
  output reg                    stream_busy_o,
  output reg                    stream_done_o
);

  localparam ACC_WORD_W = 32 * ACC_W;
  localparam OUT_WORD_W = 32 * OUT_W;

  wire [5:0] acc_wr_addr_w;
  wire [5:0] acc_rd_addr_w;
  wire [5:0] acc_mem_addr_w;
  wire [5:0] out_wr_addr_w;
  wire [5:0] stream_word_addr_w;
  wire acc_mem_en_w;
  wire out_mem_rd_en_w;
  wire out_mem_en_w;
  wire [ACC_WORD_W-1:0] acc_mem_q_w;
  wire [OUT_WORD_W-1:0] out_mem_q_w;
  reg [15:0] stream_ptr_q;
  reg [15:0] bytes_left_q;
  reg [5:0] loaded_word_addr_q;
  reg loaded_word_valid_q;

  assign acc_wr_addr_w = {acc_wr_row_i, acc_wr_half_i};
  assign acc_rd_addr_w = {acc_rd_row_i, acc_rd_half_i};
  assign acc_mem_addr_w = acc_wr_valid_i ? acc_wr_addr_w : acc_rd_addr_w;
  assign acc_mem_en_w = acc_wr_valid_i | acc_rd_en_i;
  assign out_wr_addr_w = {out_wr_row_i, out_wr_half_i};
  assign stream_word_addr_w = stream_ptr_q[10:5];
  assign out_mem_rd_en_w = stream_busy_o && !stream_valid_o &&
                            !(loaded_word_valid_q && loaded_word_addr_q == stream_word_addr_w);
  assign out_mem_en_w = out_wr_valid_i | out_mem_rd_en_w;
  assign acc_rd_data_o = acc_mem_q_w;
  assign stream_data_o = stream_ptr_q[4] ? out_mem_q_w[255:128] : out_mem_q_w[127:0];
  assign stream_last_o = stream_valid_o && (bytes_left_q <= 16);

  always @(*) begin
    if (bytes_left_q >= 16) stream_strb_o = 16'hffff;
    else stream_strb_o = ~(16'hffff << bytes_left_q[3:0]);
  end

`ifdef ATTN_ASIC
  asic_sram_256xwide #(.WIDTH(ACC_WORD_W)) u_acc_mem (
    .clk(clk),
    .en_i(acc_mem_en_w),
    .wr_en_i(acc_wr_valid_i),
    .addr_i({2'b00, acc_mem_addr_w}),
    .wr_data_i(acc_wr_data_i),
    .rd_data_o(acc_mem_q_w)
  );

  asic_sram_256xwide #(.WIDTH(OUT_WORD_W)) u_out_mem (
    .clk(clk),
    .en_i(out_mem_en_w),
    .wr_en_i(out_wr_valid_i),
    .addr_i({2'b00, out_wr_valid_i ? out_wr_addr_w : stream_word_addr_w}),
    .wr_data_i(out_wr_data_i),
    .rd_data_o(out_mem_q_w)
  );
`else
  (* ram_style = "block" *) reg [ACC_WORD_W-1:0] acc_mem [0:63];
  (* ram_style = "block" *) reg [OUT_WORD_W-1:0] out_mem [0:63];
  reg [ACC_WORD_W-1:0] acc_mem_q;
  reg [OUT_WORD_W-1:0] out_mem_q;

  assign acc_mem_q_w = acc_mem_q;
  assign out_mem_q_w = out_mem_q;

  always @(posedge clk) begin
    if (acc_wr_valid_i) begin
      acc_mem[acc_wr_addr_w] <= acc_wr_data_i;
    end else if (acc_rd_en_i) begin
      acc_mem_q <= acc_mem[acc_rd_addr_w];
    end

    if (out_wr_valid_i) begin
      out_mem[out_wr_addr_w] <= out_wr_data_i;
    end else if (out_mem_rd_en_w) begin
      out_mem_q <= out_mem[stream_word_addr_w];
    end
  end
`endif

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_rd_valid_o <= 1'b0;
      stream_valid_o <= 1'b0;
      stream_busy_o <= 1'b0;
      stream_done_o <= 1'b0;
      stream_ptr_q <= 16'd0;
      bytes_left_q <= 16'd0;
      loaded_word_addr_q <= 6'd0;
      loaded_word_valid_q <= 1'b0;
    end else begin
      acc_rd_valid_o <= acc_rd_en_i && !acc_wr_valid_i;
      stream_done_o <= 1'b0;

      if (clear_tile_i) begin
        stream_valid_o <= 1'b0;
        stream_busy_o <= 1'b0;
        stream_ptr_q <= 16'd0;
        bytes_left_q <= 16'd0;
        loaded_word_valid_q <= 1'b0;
      end else if (stream_start_i && !stream_busy_o && stream_bytes_i != 0) begin
        stream_valid_o <= 1'b0;
        stream_busy_o <= 1'b1;
        stream_ptr_q <= 16'd0;
        bytes_left_q <= stream_bytes_i;
        loaded_word_valid_q <= 1'b0;
      end else if (stream_busy_o) begin
        if (!stream_valid_o) begin
          stream_valid_o <= 1'b1;
          if (out_mem_rd_en_w) begin
            loaded_word_addr_q <= stream_word_addr_w;
            loaded_word_valid_q <= 1'b1;
          end
        end else if (stream_ready_i) begin
          if (bytes_left_q <= 16) begin
            stream_valid_o <= 1'b0;
            stream_busy_o <= 1'b0;
            stream_done_o <= 1'b1;
            bytes_left_q <= 16'd0;
          end else begin
            stream_valid_o <= 1'b0;
            stream_ptr_q <= stream_ptr_q + 16'd16;
            bytes_left_q <= bytes_left_q - 16'd16;
          end
        end
      end
    end
  end

endmodule
