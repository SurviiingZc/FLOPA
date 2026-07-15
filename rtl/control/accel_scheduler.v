`timescale 1ns/1ps
`include "attention_defines.vh"

module accel_scheduler (
  input        clk,
  input        rst_n,
  input        start_i,
  input        soft_reset_i,
  input        clear_done_i,
  input        clear_error_i,
  input        fatal_error_i,
  input        mode_sel_i,
  input        causal_en_i,
  input        prefill_en_i,
  input        decode_en_i,
  input        load_q_done_i,
  input        load_kv_done_i,
  input        qk_done_i,
  input        softmax_done_i,
  input        pv_done_i,
  input        wb_done_i,
  input        tile_last_i,
  input        run_last_i,
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
  output reg   wb_en_o
);

  reg [3:0] next_state;
  wire illegal_start_busy;
  wire illegal_mode;

  assign illegal_start_busy = start_i && busy_o;
  assign illegal_mode = start_i && prefill_en_i && decode_en_i;

  always @(*) begin
    next_state = state_o;
    case (state_o)
      `ATTN_STATE_IDLE: begin
        if (start_i && !illegal_mode) next_state = `ATTN_STATE_LOAD_Q;
      end
      `ATTN_STATE_LOAD_Q: begin
        if (load_q_done_i) next_state = `ATTN_STATE_LOAD_KV;
      end
      `ATTN_STATE_LOAD_KV: begin
        if (load_kv_done_i) next_state = `ATTN_STATE_QK;
      end
      `ATTN_STATE_QK: begin
        if (qk_done_i) next_state = `ATTN_STATE_SOFTMAX;
      end
      `ATTN_STATE_SOFTMAX: begin
        if (softmax_done_i) next_state = `ATTN_STATE_PV;
      end
      `ATTN_STATE_PV: begin
        if (pv_done_i) begin
          if (tile_last_i) next_state = `ATTN_STATE_WRITEBACK;
          else next_state = `ATTN_STATE_LOAD_KV;
        end
      end
      `ATTN_STATE_WRITEBACK: begin
        if (wb_done_i) begin
          if (run_last_i) next_state = `ATTN_STATE_DONE;
          else next_state = `ATTN_STATE_LOAD_Q;
        end
      end
      `ATTN_STATE_DONE: begin
        if (clear_done_i) next_state = `ATTN_STATE_IDLE;
        else if (start_i && !illegal_mode) next_state = `ATTN_STATE_LOAD_Q;
      end
      `ATTN_STATE_ERROR: begin
        if (clear_error_i) next_state = `ATTN_STATE_IDLE;
      end
      default: next_state = `ATTN_STATE_ERROR;
    endcase

    if (fatal_error_i || illegal_start_busy || illegal_mode) begin
      next_state = `ATTN_STATE_ERROR;
    end

    if (soft_reset_i) begin
      next_state = `ATTN_STATE_IDLE;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_o <= `ATTN_STATE_IDLE;
      done_o <= 1'b0;
      error_o <= 1'b0;
      error_code_o <= `ATTN_ERR_NONE;
    end else begin
      state_o <= next_state;

      if (soft_reset_i) begin
        done_o <= 1'b0;
        error_o <= 1'b0;
        error_code_o <= `ATTN_ERR_NONE;
      end else begin
        if (state_o == `ATTN_STATE_WRITEBACK && wb_done_i && run_last_i) begin
          done_o <= 1'b1;
        end
        if (clear_done_i || (start_i && state_o == `ATTN_STATE_DONE)) begin
          done_o <= 1'b0;
        end

        if (fatal_error_i) begin
          error_o <= 1'b1;
          error_code_o <= `ATTN_ERR_FATAL;
        end else if (illegal_start_busy || illegal_mode) begin
          error_o <= 1'b1;
          error_code_o <= `ATTN_ERR_BAD_CFG;
        end else if (clear_error_i) begin
          error_o <= 1'b0;
          error_code_o <= `ATTN_ERR_NONE;
        end
      end
    end
  end

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
