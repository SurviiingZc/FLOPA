`timescale 1ns/1ps
`include "attention_defines.vh"
`include "fixed_defs.vh"

module softmax_engine (
  input                              clk,
  input                              rst_n,
  input                              clear_i,
  input                              clear_rows_i,
  input                              start_i,
  input      [32*32*32-1:0]          score_tile_i,
  input      [31:0]                  score_scale_i,
  input      [15:0]                  q_base_i,
  input      [15:0]                  k_base_i,
  input      [15:0]                  seq_q_i,
  input      [15:0]                  seq_kv_i,
  input                              causal_en_i,
  output reg [32*32*16-1:0]          beta_tile_o,
  output reg [32*16-1:0]             alpha_rows_o,
  output reg [32*16-1:0]             m_rows_o,
  output reg [32*32-1:0]             l_rows_o,
  output reg                         done_o,
  output reg                         busy_o,
  output reg                         error_o
);

  localparam ST_IDLE = 4'd0;
  localparam ST_SCALE = 4'd1;
  localparam ST_SCALE_WAIT = 4'd2;
  localparam ST_MAX_START = 4'd3;
  localparam ST_MAX_WAIT = 4'd4;
  localparam ST_BCAST_START = 4'd5;
  localparam ST_BCAST_WAIT = 4'd6;
  localparam ST_EXP_START = 4'd7;
  localparam ST_EXP_WAIT = 4'd8;
  localparam ST_SUM_START = 4'd9;
  localparam ST_SUM_WAIT = 4'd10;
  localparam ST_LSE_START = 4'd11;
  localparam ST_LSE_WAIT = 4'd12;
  localparam ST_DONE = 4'd13;

  reg [3:0] state_q;
  reg [4:0] row_q;
  reg [31:0] row_valid_bits_q;
  reg [32*16-1:0] scaled_row_q;
  reg [32*16-1:0] beta_row_q;
  reg signed [15:0] block_max_q;
  reg [31:0] block_sum_q;
  wire [32*16-1:0] masked_row_w;
  wire [31:0] mask_valid_w;
  wire query_row_valid_w;
  wire reduce_valid_w;
  wire signed [31:0] reduce_result_w;
  wire [32*16-1:0] scale_data_w;
  wire [31:0] scale_valid_w;
  wire [32*16-1:0] exp_data_w;
  wire [31:0] exp_valid_w;
  wire lse_valid_w;
  wire signed [15:0] lse_m_new_w;
  wire [31:0] lse_l_new_w;
  wire [15:0] lse_alpha_w;
  wire signed [15:0] m_old_w;
  wire [31:0] l_old_w;
  wire signed [15:0] m_new_for_exp_w;
  wire broadcast_valid_w;
  wire [32*16-1:0] broadcast_m_w;
  reg [32*16-1:0] shifted_row_w;
  reg signed [16:0] shift_diff_w;
  integer lane;

  assign m_old_w = m_rows_o[row_q*16 +: 16];
  assign l_old_w = l_rows_o[row_q*32 +: 32];
  assign m_new_for_exp_w = row_valid_bits_q[row_q] ?
      (($signed(m_old_w) >= $signed(block_max_q)) ? m_old_w : block_max_q) : block_max_q;

  always @(*) begin
    shifted_row_w = {32*16{1'b0}};
    for (lane = 0; lane < 32; lane = lane + 1) begin
      if (mask_valid_w[lane]) begin
        shift_diff_w = {masked_row_w[lane*16+15], masked_row_w[lane*16 +: 16]} -
                       {broadcast_m_w[lane*16+15], broadcast_m_w[lane*16 +: 16]};
        if (shift_diff_w < -17'sd32768)
          shifted_row_w[lane*16 +: 16] = 16'h8000;
        else
          shifted_row_w[lane*16 +: 16] = shift_diff_w[15:0];
      end else begin
        shifted_row_w[lane*16 +: 16] = 16'h8000;
      end
    end
  end

  generate
    genvar scale_lane;
    for (scale_lane = 0; scale_lane < 32; scale_lane = scale_lane + 1) begin : g_scale
      scale_requant_unit #(.IN_W(32), .SCALE_W(16), .OUT_W(16)) u_scale (
        .clk(clk), .rst_n(rst_n), .valid_i(state_q == ST_SCALE),
        .data_i(score_tile_i[(row_q*32+scale_lane)*32 +: 32]),
        .scale_mant_i(score_scale_i[15:0]), .shift_i(score_scale_i[21:16]),
        .zero_point_i(16'sd0), .round_mode_i(`ATTN_ROUND_NEAREST), .sat_mode_i(`ATTN_SAT_INT16),
        .valid_o(scale_valid_w[scale_lane]), .data_o(scale_data_w[scale_lane*16 +: 16])
      );
    end
  endgenerate

  causal_mask u_mask (
    .score_i(scaled_row_q), .query_index_i(q_base_i + row_q), .key_base_i(k_base_i),
    .seq_q_i(seq_q_i), .seq_kv_i(seq_kv_i), .causal_en_i(causal_en_i),
    .score_o(masked_row_w), .lane_valid_o(mask_valid_w), .row_valid_o(query_row_valid_w)
  );

  row_broadcast u_row_state_broadcast (
    .clk(clk), .rst_n(rst_n), .valid_i(state_q == ST_BCAST_START),
    .row_value_i(m_new_for_exp_w), .valid_o(broadcast_valid_w), .lane_values_o(broadcast_m_w)
  );

  row_reduce_unit u_reduce (
    .clk(clk), .rst_n(rst_n),
    .valid_i(state_q == ST_MAX_START || state_q == ST_SUM_START),
    .mode_i(state_q == ST_SUM_START ? `ATTN_REDUCE_SUM : `ATTN_REDUCE_MAX),
    .lane_valid_i(state_q == ST_SUM_START ? 32'hffff_ffff : mask_valid_w),
    .data_i(state_q == ST_SUM_START ? beta_row_q : masked_row_w),
    .valid_o(reduce_valid_w), .result_o(reduce_result_w)
  );

  generate
    genvar exp_lane;
    for (exp_lane = 0; exp_lane < 32; exp_lane = exp_lane + 1) begin : g_exp
      pwl_exp_unit u_exp (
        .clk(clk), .rst_n(rst_n), .valid_i(state_q == ST_EXP_START),
        .x_i(shifted_row_w[exp_lane*16 +: 16]),
        .valid_o(exp_valid_w[exp_lane]), .y_o(exp_data_w[exp_lane*16 +: 16])
      );
    end
  endgenerate

  block_lse_update u_lse (
    .clk(clk), .rst_n(rst_n), .valid_i(state_q == ST_LSE_START),
    .init_i(!row_valid_bits_q[row_q]), .m_old_i(m_old_w), .l_old_i(l_old_w),
    .block_max_i(block_max_q), .block_sum_i(block_sum_q),
    .valid_o(lse_valid_w), .m_new_o(lse_m_new_w), .l_new_o(lse_l_new_w), .alpha_o(lse_alpha_w)
  );

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      row_q <= 5'd0;
      row_valid_bits_q <= 32'd0;
      scaled_row_q <= 512'd0;
      beta_row_q <= 512'd0;
      block_max_q <= `ATTN_SCORE_MIN;
      block_sum_q <= 32'd0;
      beta_tile_o <= {(32*32*16){1'b0}};
      alpha_rows_o <= 512'd0;
      m_rows_o <= 512'd0;
      l_rows_o <= 1024'd0;
      done_o <= 1'b0;
      busy_o <= 1'b0;
      error_o <= 1'b0;
    end else if (clear_i) begin
      state_q <= ST_IDLE;
      row_q <= 5'd0;
      row_valid_bits_q <= 32'd0;
      beta_tile_o <= {(32*32*16){1'b0}};
      alpha_rows_o <= 512'd0;
      m_rows_o <= 512'd0;
      l_rows_o <= 1024'd0;
      done_o <= 1'b0;
      busy_o <= 1'b0;
      error_o <= 1'b0;
    end else begin
      done_o <= 1'b0;
      if (clear_rows_i) begin
        if (busy_o) error_o <= 1'b1;
        row_valid_bits_q <= 32'd0;
        m_rows_o <= 512'd0;
        l_rows_o <= 1024'd0;
        beta_tile_o <= {(32*32*16){1'b0}};
        alpha_rows_o <= 512'd0;
      end
      case (state_q)
        ST_IDLE: begin
          busy_o <= 1'b0;
          if (start_i) begin
            row_q <= 5'd0;
            busy_o <= 1'b1;
            state_q <= ST_SCALE;
          end
        end
        ST_SCALE: state_q <= ST_SCALE_WAIT;
        ST_SCALE_WAIT: begin
          if (&scale_valid_w) begin
            scaled_row_q <= scale_data_w;
            state_q <= ST_MAX_START;
          end
        end
        ST_MAX_START: begin
          if (!query_row_valid_w || mask_valid_w == 0) begin
            beta_tile_o[row_q*32*16 +: 32*16] <= 512'd0;
            alpha_rows_o[row_q*16 +: 16] <= 16'd0;
            if (row_q == 31) state_q <= ST_DONE;
            else begin row_q <= row_q + 1'b1; state_q <= ST_SCALE; end
          end else begin
            state_q <= ST_MAX_WAIT;
          end
        end
        ST_MAX_WAIT: begin
          if (reduce_valid_w) begin
            block_max_q <= reduce_result_w[15:0];
            state_q <= ST_BCAST_START;
          end
        end
        ST_BCAST_START: state_q <= ST_BCAST_WAIT;
        ST_BCAST_WAIT: if (broadcast_valid_w) state_q <= ST_EXP_START;
        ST_EXP_START: state_q <= ST_EXP_WAIT;
        ST_EXP_WAIT: begin
          if (&exp_valid_w) begin
            beta_row_q <= exp_data_w;
            state_q <= ST_SUM_START;
          end
        end
        ST_SUM_START: state_q <= ST_SUM_WAIT;
        ST_SUM_WAIT: begin
          if (reduce_valid_w) begin
            block_sum_q <= reduce_result_w;
            state_q <= ST_LSE_START;
          end
        end
        ST_LSE_START: state_q <= ST_LSE_WAIT;
        ST_LSE_WAIT: begin
          if (lse_valid_w) begin
            beta_tile_o[row_q*32*16 +: 32*16] <= beta_row_q;
            alpha_rows_o[row_q*16 +: 16] <= lse_alpha_w;
            m_rows_o[row_q*16 +: 16] <= lse_m_new_w;
            l_rows_o[row_q*32 +: 32] <= lse_l_new_w;
            row_valid_bits_q[row_q] <= 1'b1;
            if (row_q == 31) state_q <= ST_DONE;
            else begin row_q <= row_q + 1'b1; state_q <= ST_SCALE; end
          end
        end
        ST_DONE: begin
          done_o <= 1'b1;
          busy_o <= 1'b0;
          if (!start_i) state_q <= ST_IDLE;
        end
        default: begin
          error_o <= 1'b1;
          busy_o <= 1'b0;
          state_q <= ST_IDLE;
        end
      endcase
    end
  end

endmodule
