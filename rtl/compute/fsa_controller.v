`timescale 1ns/1ps
`include "attention_defines.vh"

module os_fsa_controller (
  input            clk,
  input            rst_n,
  input            clear_i,
  input            qk_start_i,
  input            pv_start_i,
  input            qk_done_i,
  input            pv_done_i,
  input            qk_error_i,
  input            pv_error_i,
  output reg [1:0] phase_o,
  output reg       qk_go_o,
  output reg       pv_go_o,
  output reg       busy_o,
  output reg       error_o
);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      phase_o <= `ATTN_ARRAY_PHASE_IDLE;
      qk_go_o <= 1'b0;
      pv_go_o <= 1'b0;
      busy_o <= 1'b0;
      error_o <= 1'b0;
    end else if (clear_i) begin
      phase_o <= `ATTN_ARRAY_PHASE_IDLE;
      qk_go_o <= 1'b0;
      pv_go_o <= 1'b0;
      busy_o <= 1'b0;
      error_o <= 1'b0;
    end else begin
      qk_go_o <= 1'b0;
      pv_go_o <= 1'b0;
      case (phase_o)
        `ATTN_ARRAY_PHASE_IDLE: begin
          busy_o <= 1'b0;
          if (qk_start_i && pv_start_i) begin
            error_o <= 1'b1;
          end else if (qk_start_i) begin
            phase_o <= `ATTN_ARRAY_PHASE_QK;
            qk_go_o <= 1'b1;
            busy_o <= 1'b1;
          end else if (pv_start_i) begin
            phase_o <= `ATTN_ARRAY_PHASE_PV;
            pv_go_o <= 1'b1;
            busy_o <= 1'b1;
          end
        end
        `ATTN_ARRAY_PHASE_QK: begin
          if (qk_error_i) begin
            error_o <= 1'b1;
            phase_o <= `ATTN_ARRAY_PHASE_IDLE;
            busy_o <= 1'b0;
          end else if (qk_done_i) begin
            phase_o <= `ATTN_ARRAY_PHASE_IDLE;
            busy_o <= 1'b0;
          end
        end
        `ATTN_ARRAY_PHASE_PV: begin
          if (pv_error_i) begin
            error_o <= 1'b1;
            phase_o <= `ATTN_ARRAY_PHASE_IDLE;
            busy_o <= 1'b0;
          end else if (pv_done_i) begin
            phase_o <= `ATTN_ARRAY_PHASE_IDLE;
            busy_o <= 1'b0;
          end
        end
        default: begin
          error_o <= 1'b1;
          phase_o <= `ATTN_ARRAY_PHASE_IDLE;
          busy_o <= 1'b0;
        end
      endcase
    end
  end

endmodule
