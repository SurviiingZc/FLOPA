`timescale 1ns/1ps
`include "attention_defines.vh"

// Ping-pong Q/K/V tile cache. Each 256-bit word contains 32 INT8 lanes; cache
// depth is HEAD_DIM features, while the model-level KV history remains in DDR.
module qkv_tile_cache #(
  parameter ADDR_W = `ATTN_CACHE_ADDR_W,
  parameter BANKS = `ATTN_NUM_BANKS,
  parameter BANK_W = 16
)(
  input                     clk,
  input                     rst_n,
  input                     clear_i,
  input      [1:0]          load_kind_i,
  input                     load_bank_i,
  input      [ADDR_W-1:0]   load_addr_i,
  input                     load_half_i,
  input      [127:0]        load_data_i,
  input                     load_valid_i,
  output                    load_ready_o,
  input      [1:0]          commit_kind_i,
  input                     commit_bank_i,
  input                     commit_valid_i,
  input                     q_consume_i,
  input                     q_switch_i,
  input                     kv_consume_i,
  input                     kv_switch_i,
  output                    q_active_valid_o,
  output                    kv_active_valid_o,
  output                    q_next_valid_o,
  output                    kv_next_valid_o,
  output                    q_active_bank_o,
  output                    kv_active_bank_o,
  input                     q_rd_en_i,
  input      [ADDR_W-1:0]   q_rd_addr_i,
  output     [255:0]        q_rd_data_o,
  output                    q_rd_valid_o,
  input                     k_rd_en_i,
  input      [ADDR_W-1:0]   k_rd_addr_i,
  output     [255:0]        k_rd_data_o,
  output                    k_rd_valid_o,
  input                     v_rd_en_i,
  input      [ADDR_W-1:0]   v_rd_addr_i,
  output     [255:0]        v_rd_data_o,
  output                    v_rd_valid_o,
  output reg                protocol_error_o
);

  reg pending_half_q;
  reg [1:0] pending_kind_q;
  reg pending_bank_q;
  reg [ADDR_W-1:0] pending_addr_q;
  reg [127:0] pending_data_q;
  reg word_wr_valid_q;
  reg [1:0] word_wr_kind_q;
  reg word_wr_bank_q;
  reg [ADDR_W-1:0] word_wr_addr_q;
  reg [255:0] word_wr_data_q;

  wire q0_valid_w;
  wire q1_valid_w;
  wire k0_valid_w;
  wire k1_valid_w;
  wire v0_valid_w;
  wire v1_valid_w;
  wire [255:0] q0_data_w;
  wire [255:0] q1_data_w;
  wire [255:0] k0_data_w;
  wire [255:0] k1_data_w;
  wire [255:0] v0_data_w;
  wire [255:0] v1_data_w;
  wire q_pp_error_w;
  wire k_pp_error_w;
  wire v_pp_error_w;
  wire k_active_bank_w;
  wire v_active_bank_w;
  wire k_active_valid_w;
  wire v_active_valid_w;
  wire k_next_valid_w;
  wire v_next_valid_w;

  // Exactly one active bank responds per tensor, so valid safely selects its data.
  assign load_ready_o = 1'b1;
  assign q_rd_data_o = q0_valid_w ? q0_data_w : q1_data_w;
  assign q_rd_valid_o = q0_valid_w | q1_valid_w;
  assign k_rd_data_o = k0_valid_w ? k0_data_w : k1_data_w;
  assign k_rd_valid_o = k0_valid_w | k1_valid_w;
  assign v_rd_data_o = v0_valid_w ? v0_data_w : v1_data_w;
  assign v_rd_valid_o = v0_valid_w | v1_valid_w;
  assign kv_active_valid_o = k_active_valid_w & v_active_valid_w & (k_active_bank_w == v_active_bank_w);
  assign kv_next_valid_o = k_next_valid_w & v_next_valid_w;
  assign kv_active_bank_o = k_active_bank_w;

  // Assemble two 128-bit loader beats into one 256-bit cache word. The second half
  // must match kind, bank, and address captured with the first half.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pending_half_q <= 1'b0;
      pending_kind_q <= 2'd0;
      pending_bank_q <= 1'b0;
      pending_addr_q <= {ADDR_W{1'b0}};
      pending_data_q <= 128'd0;
      word_wr_valid_q <= 1'b0;
      word_wr_kind_q <= 2'd0;
      word_wr_bank_q <= 1'b0;
      word_wr_addr_q <= {ADDR_W{1'b0}};
      word_wr_data_q <= 256'd0;
      protocol_error_o <= 1'b0;
    end else if (clear_i) begin
      pending_half_q <= 1'b0;
      word_wr_valid_q <= 1'b0;
      protocol_error_o <= 1'b0;
    end else begin
      word_wr_valid_q <= 1'b0;
      protocol_error_o <= q_pp_error_w | k_pp_error_w | v_pp_error_w;
      if (load_valid_i) begin
        if (!load_half_i) begin
          pending_half_q <= 1'b1;
          pending_kind_q <= load_kind_i;
          pending_bank_q <= load_bank_i;
          pending_addr_q <= load_addr_i;
          pending_data_q <= load_data_i;
        end else if (pending_half_q && pending_kind_q == load_kind_i &&
                     pending_bank_q == load_bank_i && pending_addr_q == load_addr_i) begin
          word_wr_valid_q <= 1'b1;
          word_wr_kind_q <= load_kind_i;
          word_wr_bank_q <= load_bank_i;
          word_wr_addr_q <= load_addr_i;
          word_wr_data_q <= {load_data_i, pending_data_q};
          pending_half_q <= 1'b0;
        end else begin
          protocol_error_o <= 1'b1;
        end
      end
    end
  end

  // Q has independent lifetime; K and V switch/consume together as a KV pair.
  pingpong_buffer u_q_pp (
    .clk(clk), .rst_n(rst_n), .clear_i(clear_i),
    .load_commit_i(commit_valid_i && commit_kind_i == `ATTN_CACHE_Q), .load_bank_i(commit_bank_i),
    .consume_i(q_consume_i), .switch_i(q_switch_i), .active_bank_o(q_active_bank_o),
    .active_valid_o(q_active_valid_o), .next_valid_o(q_next_valid_o), .bank_valid_o(),
    .protocol_error_o(q_pp_error_w)
  );

  pingpong_buffer u_k_pp (
    .clk(clk), .rst_n(rst_n), .clear_i(clear_i),
    .load_commit_i(commit_valid_i && commit_kind_i == `ATTN_CACHE_K), .load_bank_i(commit_bank_i),
    .consume_i(kv_consume_i), .switch_i(kv_switch_i), .active_bank_o(k_active_bank_w),
    .active_valid_o(k_active_valid_w), .next_valid_o(k_next_valid_w), .bank_valid_o(),
    .protocol_error_o(k_pp_error_w)
  );

  pingpong_buffer u_v_pp (
    .clk(clk), .rst_n(rst_n), .clear_i(clear_i),
    .load_commit_i(commit_valid_i && commit_kind_i == `ATTN_CACHE_V), .load_bank_i(commit_bank_i),
    .consume_i(kv_consume_i), .switch_i(kv_switch_i), .active_bank_o(v_active_bank_w),
    .active_valid_o(v_active_valid_w), .next_valid_o(v_next_valid_w), .bank_valid_o(),
    .protocol_error_o(v_pp_error_w)
  );

  // Six physical memories implement Q/K/V x ping/pong. Only the active compute
  // bank is read while the inactive bank may be filled for the next tile.
  banked_sram #(.BANKS(BANKS), .BANK_W(BANK_W), .ADDR_W(ADDR_W)) u_q0 (
    .clk(clk), .rst_n(rst_n),
    .wr_en_i(word_wr_valid_q && word_wr_kind_q == `ATTN_CACHE_Q && !word_wr_bank_q),
    .wr_addr_i(word_wr_addr_q), .wr_data_i(word_wr_data_q), .wr_bank_en_i({BANKS{1'b1}}),
    .rd_en_i(q_rd_en_i && !q_active_bank_o), .rd_addr_i(q_rd_addr_i),
    .rd_data_o(q0_data_w), .rd_valid_o(q0_valid_w)
  );
  banked_sram #(.BANKS(BANKS), .BANK_W(BANK_W), .ADDR_W(ADDR_W)) u_q1 (
    .clk(clk), .rst_n(rst_n),
    .wr_en_i(word_wr_valid_q && word_wr_kind_q == `ATTN_CACHE_Q && word_wr_bank_q),
    .wr_addr_i(word_wr_addr_q), .wr_data_i(word_wr_data_q), .wr_bank_en_i({BANKS{1'b1}}),
    .rd_en_i(q_rd_en_i && q_active_bank_o), .rd_addr_i(q_rd_addr_i),
    .rd_data_o(q1_data_w), .rd_valid_o(q1_valid_w)
  );
  banked_sram #(.BANKS(BANKS), .BANK_W(BANK_W), .ADDR_W(ADDR_W)) u_k0 (
    .clk(clk), .rst_n(rst_n),
    .wr_en_i(word_wr_valid_q && word_wr_kind_q == `ATTN_CACHE_K && !word_wr_bank_q),
    .wr_addr_i(word_wr_addr_q), .wr_data_i(word_wr_data_q), .wr_bank_en_i({BANKS{1'b1}}),
    .rd_en_i(k_rd_en_i && !k_active_bank_w), .rd_addr_i(k_rd_addr_i),
    .rd_data_o(k0_data_w), .rd_valid_o(k0_valid_w)
  );
  banked_sram #(.BANKS(BANKS), .BANK_W(BANK_W), .ADDR_W(ADDR_W)) u_k1 (
    .clk(clk), .rst_n(rst_n),
    .wr_en_i(word_wr_valid_q && word_wr_kind_q == `ATTN_CACHE_K && word_wr_bank_q),
    .wr_addr_i(word_wr_addr_q), .wr_data_i(word_wr_data_q), .wr_bank_en_i({BANKS{1'b1}}),
    .rd_en_i(k_rd_en_i && k_active_bank_w), .rd_addr_i(k_rd_addr_i),
    .rd_data_o(k1_data_w), .rd_valid_o(k1_valid_w)
  );
  banked_sram #(.BANKS(BANKS), .BANK_W(BANK_W), .ADDR_W(ADDR_W)) u_v0 (
    .clk(clk), .rst_n(rst_n),
    .wr_en_i(word_wr_valid_q && word_wr_kind_q == `ATTN_CACHE_V && !word_wr_bank_q),
    .wr_addr_i(word_wr_addr_q), .wr_data_i(word_wr_data_q), .wr_bank_en_i({BANKS{1'b1}}),
    .rd_en_i(v_rd_en_i && !v_active_bank_w), .rd_addr_i(v_rd_addr_i),
    .rd_data_o(v0_data_w), .rd_valid_o(v0_valid_w)
  );
  banked_sram #(.BANKS(BANKS), .BANK_W(BANK_W), .ADDR_W(ADDR_W)) u_v1 (
    .clk(clk), .rst_n(rst_n),
    .wr_en_i(word_wr_valid_q && word_wr_kind_q == `ATTN_CACHE_V && word_wr_bank_q),
    .wr_addr_i(word_wr_addr_q), .wr_data_i(word_wr_data_q), .wr_bank_en_i({BANKS{1'b1}}),
    .rd_en_i(v_rd_en_i && v_active_bank_w), .rd_addr_i(v_rd_addr_i),
    .rd_data_o(v1_data_w), .rd_valid_o(v1_valid_w)
  );

endmodule
