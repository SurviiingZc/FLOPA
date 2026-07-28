`timescale 1ns/1ps
`include "attention_defines.vh"

// Packs eight normalized rows one feature at a time into 256-bit row/group words,
// then exposes each word as two 128-bit AXI beats with a partial final strobe.
module output_buffer #(
  parameter integer ROWS = 32,
  parameter integer NORM_LANES = 8,
  parameter integer HEAD_DIM = 64,
  parameter integer OUT_W = 8,
  parameter integer GROUP_SIZE = 32,
  parameter integer NUM_STRIPES = ROWS / NORM_LANES,
  parameter integer STRIPE_IDX_W = (NUM_STRIPES < 2) ? 1 : $clog2(NUM_STRIPES),
  parameter integer FEATURE_IDX_W = (HEAD_DIM < 2) ? 1 : $clog2(HEAD_DIM),
  parameter integer GROUPS = (HEAD_DIM + GROUP_SIZE - 1) / GROUP_SIZE,
  parameter integer ADDR_W = (ROWS*GROUPS < 2) ? 1 : $clog2(ROWS*GROUPS)
)(
  input                                  clk,
  input                                  rst_n,
  input                                  clock_en_i,
  input                                  clear_tile_i,
  input                                  norm_valid_i,
  input      [STRIPE_IDX_W-1:0]         norm_stripe_i,
  input      [FEATURE_IDX_W-1:0]        norm_feature_i,
  input      [NORM_LANES*OUT_W-1:0]     norm_data_i,
  output                                 norm_ready_o,
  output reg                             norm_group_done_o,
  input                                  stream_start_i,
  input      [15:0]                      stream_bytes_i,
  output     [127:0]                     stream_data_o,
  output reg [15:0]                      stream_strb_o,
  output reg                             stream_valid_o,
  input                                  stream_ready_i,
  output                                 stream_last_o,
  output reg                             stream_busy_o,
  output reg                             stream_done_o
);

  localparam integer OUT_WORD_W = GROUP_SIZE * OUT_W;
  localparam integer DEPTH = ROWS * GROUPS;
  localparam integer LOCAL_ROW_W = (NORM_LANES < 2) ? 1 : $clog2(NORM_LANES);
  localparam integer GROUP_IDX_W = (GROUPS < 2) ? 1 : $clog2(GROUPS);
  localparam integer GROUP_OFFSET_W = (GROUP_SIZE < 2) ? 1 : $clog2(GROUP_SIZE);
  localparam integer ROW_IDX_W = (ROWS < 2) ? 1 : $clog2(ROWS);
  localparam integer FINAL_GROUP_ITEMS = ((HEAD_DIM - 1) % GROUP_SIZE) + 1;
  localparam integer FINAL_PAD_W = (GROUP_SIZE - FINAL_GROUP_ITEMS) * OUT_W;
  localparam [LOCAL_ROW_W-1:0] LOCAL_ROW_LAST = NORM_LANES - 1;
  localparam [GROUP_OFFSET_W-1:0] GROUP_OFFSET_LAST = GROUP_SIZE - 1;
  localparam [FEATURE_IDX_W-1:0] FEATURE_LAST = HEAD_DIM - 1;
  localparam [ADDR_W-1:0] GROUPS_ADDR = GROUPS;

  reg [OUT_WORD_W-1:0] pack_q [0:NORM_LANES-1];
  reg flush_active_q;
  reg [LOCAL_ROW_W-1:0] flush_row_q;
  reg [STRIPE_IDX_W-1:0] flush_stripe_q;
  reg [GROUP_IDX_W-1:0] flush_group_q;
  reg [15:0] stream_ptr_q;
  reg [15:0] bytes_left_q;
  reg [ADDR_W-1:0] loaded_word_addr_q;
  reg loaded_word_valid_q;

  wire [GROUP_OFFSET_W-1:0] norm_offset_w;
  wire [GROUP_IDX_W-1:0] norm_group_w;
  wire [FEATURE_IDX_W-1:0] norm_group_full_w;
  wire norm_group_last_w;
  wire out_wr_valid_w;
  wire [ADDR_W-1:0] out_wr_addr_w;
  wire [ROW_IDX_W-1:0] flush_global_row_w;
  wire [ADDR_W-1:0] flush_global_row_ext_w;
  wire [ADDR_W-1:0] groups_const_w;
  wire [2*ADDR_W-1:0] flush_addr_product_w;
  wire [OUT_WORD_W-1:0] out_wr_data_w;
  wire [ADDR_W-1:0] stream_word_addr_w;
  wire out_mem_rd_en_w;
  wire out_mem_en_w;
  wire [OUT_WORD_W-1:0] out_mem_q_w;
  wire gated_clk_w;
  integer lane;

  fa_clock_gate u_clock_gate (
    .clk_i(clk), .enable_i(!rst_n || clock_en_i || clear_tile_i),
    .test_enable_i(1'b0), .clk_o(gated_clk_w)
  );

`ifndef SYNTHESIS
  reg [GROUP_OFFSET_W-1:0] expected_norm_offset_q;

  initial begin
    if (ROWS % NORM_LANES != 0)
      $fatal(1, "output_buffer ROWS must be divisible by NORM_LANES");
    if ((1 << GROUP_OFFSET_W) != GROUP_SIZE)
      $fatal(1, "output_buffer GROUP_SIZE must be a power of two");
    if (OUT_WORD_W != 256)
      $fatal(1, "output_buffer requires a 256-bit SRAM word");
    if (DEPTH > 256)
      $fatal(1, "output_buffer exceeds the 256-word SRAM depth");
  end

  // Fixed-end packing relies on the normalizer's feature-major contract. Catch
  // an upstream reorder in simulation instead of silently permuting bytes.
  always @(posedge gated_clk_w or negedge rst_n) begin
    if (!rst_n)
      expected_norm_offset_q <= {GROUP_OFFSET_W{1'b0}};
    else if (clear_tile_i)
      expected_norm_offset_q <= {GROUP_OFFSET_W{1'b0}};
    else if (norm_valid_i && norm_ready_o) begin
      if (norm_offset_w != expected_norm_offset_q)
        $fatal(1, "output_buffer non-sequential feature offset got=%0d expected=%0d",
               norm_offset_w, expected_norm_offset_q);
      if (norm_group_last_w)
        expected_norm_offset_q <= {GROUP_OFFSET_W{1'b0}};
      else
        expected_norm_offset_q <= expected_norm_offset_q + 1'b1;
    end
  end
`endif

  // Feature high bits select the 32-feature output group. Low bits identify
  // group boundaries and are checked against the required ascending stream.
  assign norm_ready_o = !flush_active_q && !stream_busy_o;
  assign norm_offset_w = norm_feature_i[GROUP_OFFSET_W-1:0];
  assign norm_group_full_w = norm_feature_i >> GROUP_OFFSET_W;
  assign norm_group_w = norm_group_full_w[GROUP_IDX_W-1:0];
  assign norm_group_last_w = (norm_offset_w == GROUP_OFFSET_LAST) ||
                             (norm_feature_i == FEATURE_LAST);
  assign out_wr_valid_w = flush_active_q;
  assign flush_global_row_w = {flush_stripe_q, flush_row_q};
  assign flush_global_row_ext_w =
      {{(ADDR_W-ROW_IDX_W){1'b0}}, flush_global_row_w};
  assign groups_const_w = GROUPS_ADDR;
  assign flush_addr_product_w = flush_global_row_ext_w * groups_const_w;
  assign out_wr_addr_w = flush_addr_product_w[ADDR_W-1:0] +
      {{(ADDR_W-GROUP_IDX_W){1'b0}}, flush_group_q};
  // Completed rows are destructively shifted toward lane zero during flush, so
  // the SRAM data port never sees an 8:1, 256-bit runtime row selector.
  assign out_wr_data_w = pack_q[0];
  assign stream_word_addr_w = stream_ptr_q[ADDR_W+4:5];
  assign out_mem_rd_en_w = stream_busy_o && !stream_valid_o &&
      !(loaded_word_valid_q && loaded_word_addr_q == stream_word_addr_w);
  assign out_mem_en_w = out_wr_valid_w || out_mem_rd_en_w;
  assign stream_data_o = stream_ptr_q[4] ?
      out_mem_q_w[255:128] : out_mem_q_w[127:0];
  assign stream_last_o = stream_valid_o && (bytes_left_q <= 16);

  // Compute the final AXI strobe. Feature packing itself uses fixed-end shifts
  // in the sequential block instead of a 32-way dynamic byte write.
  always @(*) begin
    if (bytes_left_q >= 16)
      stream_strb_o = 16'hffff;
    else
      stream_strb_o = ~(16'hffff << bytes_left_q[3:0]);
  end

`ifdef ATTN_ASIC
  // Writes have priority over reads because the characterized SRAM is single-port.
  asic_sram_256xwide #(.WIDTH(OUT_WORD_W)) u_out_mem (
    .clk(gated_clk_w), .en_i(out_mem_en_w), .wr_en_i(out_wr_valid_w),
    .addr_i({{(8-ADDR_W){1'b0}},
             out_wr_valid_w ? out_wr_addr_w : stream_word_addr_w}),
    .wr_data_i(out_wr_data_w), .rd_data_o(out_mem_q_w)
  );
`else
  (* ram_style = "block" *) reg [OUT_WORD_W-1:0] out_mem [0:DEPTH-1];
  reg [OUT_WORD_W-1:0] out_mem_q;
  assign out_mem_q_w = out_mem_q;
  always @(posedge gated_clk_w) begin
    if (out_wr_valid_w)
      out_mem[out_wr_addr_w] <= out_wr_data_w;
    else if (out_mem_rd_en_w)
      out_mem_q <= out_mem[stream_word_addr_w];
  end
`endif

  // At a group boundary, flush the eight completed row words sequentially; after
  // normalization, stream them as 16-byte beats under AXI backpressure.
  always @(posedge gated_clk_w or negedge rst_n) begin
    if (!rst_n) begin
      flush_active_q <= 1'b0;
      flush_row_q <= {LOCAL_ROW_W{1'b0}};
      flush_stripe_q <= {STRIPE_IDX_W{1'b0}};
      flush_group_q <= {GROUP_IDX_W{1'b0}};
      norm_group_done_o <= 1'b0;
      stream_valid_o <= 1'b0;
      stream_busy_o <= 1'b0;
      stream_done_o <= 1'b0;
      stream_ptr_q <= 16'd0;
      bytes_left_q <= 16'd0;
      loaded_word_addr_q <= {ADDR_W{1'b0}};
      loaded_word_valid_q <= 1'b0;
      for (lane = 0; lane < NORM_LANES; lane = lane + 1)
        pack_q[lane] <= {OUT_WORD_W{1'b0}};
    end else begin
      norm_group_done_o <= 1'b0;
      stream_done_o <= 1'b0;

      if (clear_tile_i) begin
        flush_active_q <= 1'b0;
        stream_valid_o <= 1'b0;
        stream_busy_o <= 1'b0;
        stream_ptr_q <= 16'd0;
        bytes_left_q <= 16'd0;
        loaded_word_valid_q <= 1'b0;
      end else begin
        if (norm_valid_i && norm_ready_o) begin
          // Normalizer features arrive in ascending order. Insert each byte at
          // the fixed high end; after GROUP_SIZE beats feature zero has shifted
          // to the low byte and the packed word matches the SRAM/AXI layout.
          for (lane = 0; lane < NORM_LANES; lane = lane + 1) begin
            if (norm_offset_w == 0) begin
              if ((FINAL_PAD_W != 0) && (norm_feature_i == FEATURE_LAST))
                pack_q[lane] <=
                    {norm_data_i[lane*OUT_W +: OUT_W],
                     {(OUT_WORD_W-OUT_W){1'b0}}} >> FINAL_PAD_W;
              else
                pack_q[lane] <=
                    {norm_data_i[lane*OUT_W +: OUT_W],
                     {(OUT_WORD_W-OUT_W){1'b0}}};
            end else if ((FINAL_PAD_W != 0) &&
                         (norm_feature_i == FEATURE_LAST)) begin
              pack_q[lane] <=
                  {norm_data_i[lane*OUT_W +: OUT_W],
                   pack_q[lane][OUT_WORD_W-1:OUT_W]} >> FINAL_PAD_W;
            end else begin
              pack_q[lane] <=
                  {norm_data_i[lane*OUT_W +: OUT_W],
                   pack_q[lane][OUT_WORD_W-1:OUT_W]};
            end
          end
          if (norm_group_last_w) begin
            flush_active_q <= 1'b1;
            flush_row_q <= {LOCAL_ROW_W{1'b0}};
            flush_stripe_q <= norm_stripe_i;
            flush_group_q <= norm_group_w;
          end
        end

        if (flush_active_q) begin
          // The current lane-zero word is written this cycle. Shift the next
          // completed row into the same fixed data port for the following cycle.
          for (lane = 0; lane < NORM_LANES-1; lane = lane + 1)
            pack_q[lane] <= pack_q[lane+1];
          pack_q[NORM_LANES-1] <= {OUT_WORD_W{1'b0}};
          if (flush_row_q == LOCAL_ROW_LAST) begin
            flush_active_q <= 1'b0;
            norm_group_done_o <= 1'b1;
          end else begin
            flush_row_q <= flush_row_q + 1'b1;
          end
        end

        if (stream_start_i && !stream_busy_o && stream_bytes_i != 0) begin
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
  end

endmodule
