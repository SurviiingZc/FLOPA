`timescale 1ns/1ps
`include "attention_defines.vh"

// Job-level prefill scheduler. It walks head -> Q tile -> KV tile, retains
// online-softmax state across KV tiles, and writes O only after the final KV tile.
module accel_scheduler (
  input        clk,
  input        rst_n,
  input        start_i,
  input        soft_reset_i,
  input        clear_done_i,
  input        clear_error_i,
  input        fatal_error_i,
  input        prefill_en_i,
  input        decode_en_i,
  input [15:0] seq_q_i,
  input [15:0] seq_kv_i,
  input [7:0]  num_q_heads_i,
  input [7:0]  tile_q_i,
  input [7:0]  tile_k_i,
  input        load_q_done_i,
  input        load_kv_done_i,
  input        qk_done_i,
  input        softmax_pv_ready_i,
  input        pv_done_i,
  input        wb_done_i,
  output reg [3:0] state_o,
  output reg   busy_o,
  output reg   done_o,
  output reg   error_o,
  output reg [3:0] error_code_o,
  output reg   idle_o,
  output reg   load_active_o,
  output reg   compute_active_o,
  output reg   writeback_active_o,
  output reg   load_q_en_o,
  output reg   load_kv_en_o,
  output reg   qk_en_o,
  output reg   softmax_en_o,
  output reg   pv_en_o,
  output reg   wb_en_o,
  output reg [7:0] head_index_o,
  output reg [10:0] q_tile_index_o,
  output reg [10:0] kv_tile_index_o,
  output [15:0] q_tile_base_o,
  output [15:0] kv_tile_base_o,
  output       tile_last_o,
  output       run_last_o
);

  reg [3:0] next_state_w;
  reg [11:0] q_tile_count_q;
  reg [11:0] kv_tile_count_q;
  wire illegal_start_busy_w;
  wire illegal_mode_w;
  wire illegal_dimensions_w;
  wire [16:0] q_tile_count_calc_w;
  wire [16:0] kv_tile_count_calc_w;

  // Stage-1 accepts fixed 32x32 prefill only; decode/GQA scheduling is deferred.
  assign illegal_start_busy_w = start_i && busy_o;
  assign illegal_mode_w = start_i && (!prefill_en_i || decode_en_i);
  assign illegal_dimensions_w = start_i &&
      (seq_q_i == 0 || seq_kv_i == 0 || num_q_heads_i == 0 ||
       tile_q_i != `ATTN_TILE_Q || tile_k_i != `ATTN_TILE_K);
  assign q_tile_count_calc_w = ({1'b0, seq_q_i} + 17'd31) >> 5;
  assign kv_tile_count_calc_w = ({1'b0, seq_kv_i} + 17'd31) >> 5;
  assign q_tile_base_o = {q_tile_index_o, 5'b0};
  assign kv_tile_base_o = {kv_tile_index_o, 5'b0};
  assign tile_last_o = ({1'b0, kv_tile_index_o} == kv_tile_count_q - 1'b1);
  assign run_last_o = (head_index_o == num_q_heads_i - 1'b1) &&
                      ({1'b0, q_tile_index_o} == q_tile_count_q - 1'b1);

  // Phase transitions are handshake-driven so cache, array, and AXI latency
  // never appears as a fixed controller delay.
  always @(*) begin
    next_state_w = state_o;
    case (state_o)
      `ATTN_STATE_IDLE: if (start_i && !illegal_mode_w && !illegal_dimensions_w) next_state_w = `ATTN_STATE_LOAD_Q;
      `ATTN_STATE_LOAD_Q: if (load_q_done_i) next_state_w = `ATTN_STATE_LOAD_KV;
      `ATTN_STATE_LOAD_KV: if (load_kv_done_i) next_state_w = `ATTN_STATE_QK;
      `ATTN_STATE_QK: if (qk_done_i) next_state_w = `ATTN_STATE_SOFTMAX;
      `ATTN_STATE_SOFTMAX: if (softmax_pv_ready_i) next_state_w = `ATTN_STATE_PV;
      `ATTN_STATE_PV: begin
        if (pv_done_i) next_state_w = tile_last_o ? `ATTN_STATE_WRITEBACK : `ATTN_STATE_LOAD_KV;
      end
      `ATTN_STATE_WRITEBACK: begin
        if (wb_done_i) next_state_w = run_last_o ? `ATTN_STATE_DONE : `ATTN_STATE_LOAD_Q;
      end
      `ATTN_STATE_DONE: begin
        if (clear_done_i) next_state_w = `ATTN_STATE_IDLE;
        else if (start_i && !illegal_mode_w && !illegal_dimensions_w) next_state_w = `ATTN_STATE_LOAD_Q;
      end
      `ATTN_STATE_ERROR: if (clear_error_i) next_state_w = `ATTN_STATE_IDLE;
      default: next_state_w = `ATTN_STATE_ERROR;
    endcase
    if (fatal_error_i || illegal_start_busy_w || illegal_mode_w || illegal_dimensions_w)
      next_state_w = `ATTN_STATE_ERROR;
    if (soft_reset_i) next_state_w = `ATTN_STATE_IDLE;
  end

  // Tile indices advance only at phase completion. KV resets after writeback,
  // while Q/head advance in row-major job order.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_o <= `ATTN_STATE_IDLE;
      done_o <= 1'b0;
      error_o <= 1'b0;
      error_code_o <= `ATTN_ERR_NONE;
      head_index_o <= 8'd0;
      q_tile_index_o <= 11'd0;
      kv_tile_index_o <= 11'd0;
      q_tile_count_q <= 12'd0;
      kv_tile_count_q <= 12'd0;
    end else begin
      state_o <= next_state_w;
      if (soft_reset_i) begin
        done_o <= 1'b0;
        error_o <= 1'b0;
        error_code_o <= `ATTN_ERR_NONE;
        head_index_o <= 8'd0;
        q_tile_index_o <= 11'd0;
        kv_tile_index_o <= 11'd0;
        q_tile_count_q <= 12'd0;
        kv_tile_count_q <= 12'd0;
      end else begin
        if (start_i && (state_o == `ATTN_STATE_IDLE || state_o == `ATTN_STATE_DONE) &&
            !illegal_mode_w && !illegal_dimensions_w) begin
          head_index_o <= 8'd0;
          q_tile_index_o <= 11'd0;
          kv_tile_index_o <= 11'd0;
          q_tile_count_q <= q_tile_count_calc_w[11:0];
          kv_tile_count_q <= kv_tile_count_calc_w[11:0];
          done_o <= 1'b0;
        end
        if (state_o == `ATTN_STATE_PV && pv_done_i) begin
          if (!tile_last_o) kv_tile_index_o <= kv_tile_index_o + 1'b1;
        end
        if (state_o == `ATTN_STATE_WRITEBACK && wb_done_i) begin
          kv_tile_index_o <= 11'd0;
          if (run_last_o) begin
            done_o <= 1'b1;
          end else if ({1'b0, q_tile_index_o} == q_tile_count_q - 1'b1) begin
            q_tile_index_o <= 11'd0;
            head_index_o <= head_index_o + 1'b1;
          end else begin
            q_tile_index_o <= q_tile_index_o + 1'b1;
          end
        end
        if (clear_done_i) done_o <= 1'b0;

        if (fatal_error_i) begin
          error_o <= 1'b1;
          error_code_o <= `ATTN_ERR_FATAL;
        end else if (illegal_start_busy_w || illegal_mode_w || illegal_dimensions_w) begin
          error_o <= 1'b1;
          error_code_o <= `ATTN_ERR_BAD_CFG;
        end else if (clear_error_i) begin
          error_o <= 1'b0;
          error_code_o <= `ATTN_ERR_NONE;
        end
      end
    end
  end

  // Decode the registered phase into one-hot enables used by the top-level blocks.
  always @(*) begin
    idle_o = (state_o == `ATTN_STATE_IDLE) || (state_o == `ATTN_STATE_DONE);
    busy_o = (state_o != `ATTN_STATE_IDLE) && (state_o != `ATTN_STATE_DONE) && (state_o != `ATTN_STATE_ERROR);
    load_active_o = (state_o == `ATTN_STATE_LOAD_Q) || (state_o == `ATTN_STATE_LOAD_KV);
    compute_active_o = (state_o == `ATTN_STATE_QK) || (state_o == `ATTN_STATE_SOFTMAX) || (state_o == `ATTN_STATE_PV);
    writeback_active_o = (state_o == `ATTN_STATE_WRITEBACK);
    load_q_en_o = (state_o == `ATTN_STATE_LOAD_Q);
    load_kv_en_o = (state_o == `ATTN_STATE_LOAD_KV);
    qk_en_o = (state_o == `ATTN_STATE_QK);
    softmax_en_o = (state_o == `ATTN_STATE_SOFTMAX);
    pv_en_o = (state_o == `ATTN_STATE_PV);
    wb_en_o = (state_o == `ATTN_STATE_WRITEBACK);
  end

endmodule
