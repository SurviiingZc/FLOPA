`timescale 1ns/1ps
`include "attention_defines.vh"

module attention_accel_top (
  input                   clk,
  input                   rst_n,

  input  [31:0]           s_axi_awaddr,
  input                   s_axi_awvalid,
  output                  s_axi_awready,
  input  [31:0]           s_axi_wdata,
  input  [3:0]            s_axi_wstrb,
  input                   s_axi_wvalid,
  output                  s_axi_wready,
  output [1:0]            s_axi_bresp,
  output                  s_axi_bvalid,
  input                   s_axi_bready,
  input  [31:0]           s_axi_araddr,
  input                   s_axi_arvalid,
  output                  s_axi_arready,
  output [31:0]           s_axi_rdata,
  output [1:0]            s_axi_rresp,
  output                  s_axi_rvalid,
  input                   s_axi_rready,

  input  [1:0]            tile_load_kind_i,
  input                   tile_load_bank_i,
  input  [9:0]            tile_load_addr_i,
  input                   tile_load_half_i,
  input  [127:0]          tile_load_data_i,
  input                   tile_load_valid_i,
  output                  tile_load_ready_o,
  input  [1:0]            tile_commit_kind_i,
  input                   tile_commit_bank_i,
  input                   tile_commit_valid_i,

  output [31:0]           m_axi_awaddr,
  output [7:0]            m_axi_awlen,
  output [2:0]            m_axi_awsize,
  output [1:0]            m_axi_awburst,
  output                  m_axi_awvalid,
  input                   m_axi_awready,
  output [127:0]          m_axi_wdata,
  output [15:0]           m_axi_wstrb,
  output                  m_axi_wlast,
  output                  m_axi_wvalid,
  input                   m_axi_wready,
  input  [1:0]            m_axi_bresp,
  input                   m_axi_bvalid,
  output                  m_axi_bready,

  output                  irq_o,
  output [3:0]            debug_state_o
);

  wire cfg_start_w;
  wire cfg_soft_reset_w;
  wire cfg_clear_done_w;
  wire cfg_clear_error_w;
  wire cfg_mode_sel_w;
  wire cfg_causal_en_w;
  wire cfg_prefill_en_w;
  wire cfg_decode_en_w;
  wire [63:0] cfg_q_base_w;
  wire [63:0] cfg_k_base_w;
  wire [63:0] cfg_v_base_w;
  wire [63:0] cfg_o_base_w;
  wire [31:0] cfg_q_stride_w;
  wire [31:0] cfg_k_stride_w;
  wire [31:0] cfg_v_stride_w;
  wire [31:0] cfg_o_stride_w;
  wire [15:0] cfg_seq_q_w;
  wire [15:0] cfg_seq_kv_w;
  wire [7:0] cfg_num_q_heads_w;
  wire [7:0] cfg_num_kv_heads_w;
  wire [7:0] cfg_head_dim_w;
  wire [7:0] cfg_tile_q_w;
  wire [7:0] cfg_tile_k_w;
  wire [31:0] cfg_score_scale_w;
  wire [31:0] cfg_value_scale_w;
  wire [31:0] cfg_out_scale_w;
  wire [31:0] cfg_mask_cfg_w;
  wire [31:0] cfg_perf_ctrl_w;

  wire scheduler_busy_w;
  wire scheduler_done_w;
  wire scheduler_error_w;
  wire [3:0] scheduler_error_code_w;
  wire scheduler_idle_w;
  wire load_active_w;
  wire compute_active_w;
  wire writeback_active_w;
  wire load_q_en_w;
  wire load_kv_en_w;
  wire qk_en_w;
  wire softmax_en_w;
  wire pv_en_w;
  wire wb_en_w;
  wire [7:0] head_index_w;
  wire [10:0] q_tile_index_w;
  wire [10:0] kv_tile_index_w;
  wire [15:0] q_tile_base_w;
  wire [15:0] kv_tile_base_w;
  wire tile_last_w;
  wire run_last_w;

  wire [63:0] perf_cycles_w;
  wire [63:0] perf_stall_w;
  wire [63:0] perf_mac_w;
  wire [31:0] perf_tiles_w;

  wire q_active_valid_w;
  wire kv_active_valid_w;
  wire q_next_valid_w;
  wire kv_next_valid_w;
  wire q_active_bank_w;
  wire kv_active_bank_w;
  wire cache_protocol_error_w;
  wire q_cache_rd_en_w;
  wire [9:0] q_cache_rd_addr_w;
  wire [255:0] q_cache_rd_data_w;
  wire q_cache_rd_valid_w;
  wire k_cache_rd_en_w;
  wire [9:0] k_cache_rd_addr_w;
  wire [255:0] k_cache_rd_data_w;
  wire k_cache_rd_valid_w;
  wire v_cache_rd_en_w;
  wire [9:0] v_cache_rd_addr_w;
  wire [255:0] v_cache_rd_data_w;
  wire v_cache_rd_valid_w;
  wire q_consume_w;
  wire q_switch_w;
  wire kv_consume_w;
  wire kv_switch_w;

  wire qk_request_w;
  wire pv_request_w;
  wire qk_go_w;
  wire pv_go_w;
  wire [1:0] array_phase_w;
  wire array_controller_error_w;
  wire qk_array_clear_w;
  wire qk_array_valid_w;
  wire qk_array_last_w;
  wire [511:0] qk_array_rows_w;
  wire [511:0] qk_array_cols_w;
  wire qk_done_w;
  wire qk_error_w;
  wire [32*32*32-1:0] score_tile_w;
  wire pv_array_load_w;
  wire [32*32*32-1:0] pv_array_load_matrix_w;
  wire pv_array_valid_w;
  wire pv_array_last_w;
  wire [511:0] pv_array_rows_w;
  wire [511:0] pv_array_cols_w;
  wire pv_engine_done_w;
  wire pv_engine_error_w;
  wire array_valid_w;
  wire array_last_w;
  wire [32*32*32-1:0] array_matrix_w;

  wire softmax_start_w;
  wire softmax_clear_rows_w;
  wire [32*32*16-1:0] beta_tile_w;
  wire [511:0] alpha_rows_w;
  wire [511:0] m_rows_w;
  wire [1023:0] l_rows_w;
  wire softmax_done_w;
  wire softmax_error_w;

  wire pv_old_rd_en_w;
  wire [4:0] pv_old_rd_row_w;
  wire pv_old_rd_half_w;
  wire [1023:0] acc_rd_data_w;
  wire acc_rd_valid_w;
  wire pv_row_valid_w;
  wire [4:0] pv_row_index_w;
  wire pv_row_half_w;
  wire [1023:0] pv_row_data_w;

  reg [3:0] pv_flow_state_q;
  reg pv_half_q;
  reg pv_complete_q;
  reg [4:0] norm_row_q;
  reg norm_half_q;
  wire norm_acc_rd_en_w;
  wire norm_valid_w;
  wire [255:0] norm_row_data_w;
  wire [31:0] norm_l_w;

  wire output_stream_start_w;
  wire [15:0] output_stream_bytes_w;
  wire [127:0] output_stream_data_w;
  wire [15:0] output_stream_strb_w;
  wire output_stream_valid_w;
  wire output_stream_ready_w;
  wire output_stream_last_w;
  wire output_stream_done_w;
  wire axi_write_start_w;
  wire axi_write_busy_w;
  wire axi_write_done_w;
  wire axi_write_error_w;
  reg [31:0] writeback_addr_w;
  reg [15:0] writeback_beats_w;
  reg [15:0] valid_q_rows_w;
  reg [63:0] address_offset_w;

  reg qk_en_d_q;
  reg softmax_en_d_q;
  reg pv_en_d_q;
  reg wb_en_d_q;
  reg load_q_en_d_q;
  wire fatal_error_w;
  wire [3:0] debug_state_reg_w;
  wire axi_data_ready_w;

  localparam PV_FLOW_IDLE = 4'd0;
  localparam PV_FLOW_REQ0 = 4'd1;
  localparam PV_FLOW_WAIT0 = 4'd2;
  localparam PV_FLOW_REQ1 = 4'd3;
  localparam PV_FLOW_WAIT1 = 4'd4;
  localparam PV_FLOW_NORM_READ = 4'd5;
  localparam PV_FLOW_NORM_WAIT = 4'd6;
  localparam PV_FLOW_COMPLETE = 4'd7;

  assign debug_state_o = debug_state_reg_w;
  assign irq_o = scheduler_done_w | scheduler_error_w;
  assign fatal_error_w = cache_protocol_error_w | array_controller_error_w | qk_error_w |
                         pv_engine_error_w | softmax_error_w | axi_write_error_w;

  accel_regfile u_regfile (
    .clk(clk), .rst_n(rst_n),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
    .cfg_start_pulse_o(cfg_start_w), .cfg_soft_reset_pulse_o(cfg_soft_reset_w),
    .cfg_clear_done_pulse_o(cfg_clear_done_w), .cfg_clear_error_pulse_o(cfg_clear_error_w),
    .cfg_mode_sel_o(cfg_mode_sel_w), .cfg_causal_en_o(cfg_causal_en_w),
    .cfg_prefill_en_o(cfg_prefill_en_w), .cfg_decode_en_o(cfg_decode_en_w),
    .cfg_q_base_o(cfg_q_base_w), .cfg_k_base_o(cfg_k_base_w), .cfg_v_base_o(cfg_v_base_w), .cfg_o_base_o(cfg_o_base_w),
    .cfg_q_stride_o(cfg_q_stride_w), .cfg_k_stride_o(cfg_k_stride_w), .cfg_v_stride_o(cfg_v_stride_w), .cfg_o_stride_o(cfg_o_stride_w),
    .cfg_seq_q_o(cfg_seq_q_w), .cfg_seq_kv_o(cfg_seq_kv_w), .cfg_num_q_heads_o(cfg_num_q_heads_w),
    .cfg_num_kv_heads_o(cfg_num_kv_heads_w), .cfg_head_dim_o(cfg_head_dim_w),
    .cfg_tile_q_o(cfg_tile_q_w), .cfg_tile_k_o(cfg_tile_k_w),
    .cfg_score_scale_o(cfg_score_scale_w), .cfg_value_scale_o(cfg_value_scale_w), .cfg_out_scale_o(cfg_out_scale_w),
    .cfg_mask_cfg_o(cfg_mask_cfg_w), .cfg_perf_ctrl_o(cfg_perf_ctrl_w),
    .busy_i(scheduler_busy_w), .done_i(scheduler_done_w), .error_i(scheduler_error_w | fatal_error_w),
    .error_code_i(scheduler_error_w ? scheduler_error_code_w : `ATTN_ERR_FATAL),
    .idle_i(scheduler_idle_w), .load_active_i(load_active_w), .compute_active_i(compute_active_w),
    .writeback_active_i(writeback_active_w), .perf_cycles_i(perf_cycles_w), .perf_stall_i(perf_stall_w),
    .perf_mac_i(perf_mac_w), .perf_tiles_i(perf_tiles_w)
  );

  accel_scheduler u_scheduler (
    .clk(clk), .rst_n(rst_n), .start_i(cfg_start_w), .soft_reset_i(cfg_soft_reset_w),
    .clear_done_i(cfg_clear_done_w), .clear_error_i(cfg_clear_error_w), .fatal_error_i(fatal_error_w),
    .prefill_en_i(cfg_prefill_en_w), .decode_en_i(cfg_decode_en_w),
    .seq_q_i(cfg_seq_q_w), .seq_kv_i(cfg_seq_kv_w), .num_q_heads_i(cfg_num_q_heads_w),
    .tile_q_i(cfg_tile_q_w), .tile_k_i(cfg_tile_k_w),
    .load_q_done_i(q_active_valid_w), .load_kv_done_i(kv_active_valid_w),
    .qk_done_i(qk_done_w), .softmax_done_i(softmax_done_w), .pv_done_i(pv_complete_q), .wb_done_i(axi_write_done_w),
    .state_o(debug_state_reg_w), .busy_o(scheduler_busy_w), .done_o(scheduler_done_w),
    .error_o(scheduler_error_w), .error_code_o(scheduler_error_code_w), .idle_o(scheduler_idle_w),
    .load_active_o(load_active_w), .compute_active_o(compute_active_w), .writeback_active_o(writeback_active_w),
    .load_q_en_o(load_q_en_w), .load_kv_en_o(load_kv_en_w), .qk_en_o(qk_en_w),
    .softmax_en_o(softmax_en_w), .pv_en_o(pv_en_w), .wb_en_o(wb_en_w),
    .head_index_o(head_index_w), .q_tile_index_o(q_tile_index_w), .kv_tile_index_o(kv_tile_index_w),
    .q_tile_base_o(q_tile_base_w), .kv_tile_base_o(kv_tile_base_w), .tile_last_o(tile_last_w), .run_last_o(run_last_w)
  );

  assign q_consume_w = axi_write_done_w;
  assign q_switch_w = load_q_en_w && !q_active_valid_w && q_next_valid_w;
  assign kv_consume_w = pv_complete_q;
  assign kv_switch_w = load_kv_en_w && !kv_active_valid_w && kv_next_valid_w;

  qkv_tile_cache u_tile_cache (
    .clk(clk), .rst_n(rst_n), .clear_i(cfg_soft_reset_w),
    .load_kind_i(tile_load_kind_i), .load_bank_i(tile_load_bank_i), .load_addr_i(tile_load_addr_i),
    .load_half_i(tile_load_half_i), .load_data_i(tile_load_data_i), .load_valid_i(tile_load_valid_i),
    .load_ready_o(tile_load_ready_o), .commit_kind_i(tile_commit_kind_i),
    .commit_bank_i(tile_commit_bank_i), .commit_valid_i(tile_commit_valid_i),
    .q_consume_i(q_consume_w), .q_switch_i(q_switch_w), .kv_consume_i(kv_consume_w), .kv_switch_i(kv_switch_w),
    .q_active_valid_o(q_active_valid_w), .kv_active_valid_o(kv_active_valid_w),
    .q_next_valid_o(q_next_valid_w), .kv_next_valid_o(kv_next_valid_w),
    .q_active_bank_o(q_active_bank_w), .kv_active_bank_o(kv_active_bank_w),
    .q_rd_en_i(q_cache_rd_en_w), .q_rd_addr_i(q_cache_rd_addr_w), .q_rd_data_o(q_cache_rd_data_w), .q_rd_valid_o(q_cache_rd_valid_w),
    .k_rd_en_i(k_cache_rd_en_w), .k_rd_addr_i(k_cache_rd_addr_w), .k_rd_data_o(k_cache_rd_data_w), .k_rd_valid_o(k_cache_rd_valid_w),
    .v_rd_en_i(v_cache_rd_en_w), .v_rd_addr_i(v_cache_rd_addr_w), .v_rd_data_o(v_cache_rd_data_w), .v_rd_valid_o(v_cache_rd_valid_w),
    .protocol_error_o(cache_protocol_error_w)
  );

  assign qk_request_w = qk_en_w && !qk_en_d_q;
  assign pv_request_w = (pv_flow_state_q == PV_FLOW_REQ0 || pv_flow_state_q == PV_FLOW_REQ1);

  os_fsa_controller u_array_controller (
    .clk(clk), .rst_n(rst_n), .clear_i(cfg_soft_reset_w),
    .qk_start_i(qk_request_w), .pv_start_i(pv_request_w), .qk_done_i(qk_done_w), .pv_done_i(pv_engine_done_w),
    .qk_error_i(qk_error_w), .pv_error_i(pv_engine_error_w), .phase_o(array_phase_w),
    .qk_go_o(qk_go_w), .pv_go_o(pv_go_w), .busy_o(), .error_o(array_controller_error_w)
  );

  qk_engine u_qk_engine (
    .clk(clk), .rst_n(rst_n), .clear_i(cfg_soft_reset_w), .start_i(qk_go_w), .head_dim_i(cfg_head_dim_w),
    .q_rd_en_o(q_cache_rd_en_w), .q_rd_addr_o(q_cache_rd_addr_w), .q_rd_data_i(q_cache_rd_data_w), .q_rd_valid_i(q_cache_rd_valid_w),
    .k_rd_en_o(k_cache_rd_en_w), .k_rd_addr_o(k_cache_rd_addr_w), .k_rd_data_i(k_cache_rd_data_w), .k_rd_valid_i(k_cache_rd_valid_w),
    .array_clear_o(qk_array_clear_w), .array_valid_o(qk_array_valid_w), .array_last_o(qk_array_last_w),
    .array_rows_o(qk_array_rows_w), .array_cols_o(qk_array_cols_w),
    .array_last_i(array_last_w), .array_matrix_i(array_matrix_w),
    .score_tile_o(score_tile_w), .done_o(qk_done_w), .busy_o(), .error_o(qk_error_w)
  );

  pv_engine u_pv_engine (
    .clk(clk), .rst_n(rst_n), .clear_i(cfg_soft_reset_w), .start_i(pv_go_w),
    .feature_half_i(pv_half_q), .first_kv_tile_i(kv_tile_index_w == 0),
    .beta_tile_i(beta_tile_w), .alpha_rows_i(alpha_rows_w),
    .old_acc_rd_en_o(pv_old_rd_en_w), .old_acc_rd_row_o(pv_old_rd_row_w), .old_acc_rd_half_o(pv_old_rd_half_w),
    .old_acc_rd_data_i(acc_rd_data_w), .old_acc_rd_valid_i(acc_rd_valid_w),
    .v_rd_en_o(v_cache_rd_en_w), .v_rd_addr_o(v_cache_rd_addr_w), .v_rd_data_i(v_cache_rd_data_w), .v_rd_valid_i(v_cache_rd_valid_w),
    .array_load_o(pv_array_load_w), .array_load_matrix_o(pv_array_load_matrix_w),
    .array_valid_o(pv_array_valid_w), .array_last_o(pv_array_last_w),
    .array_rows_o(pv_array_rows_w), .array_cols_o(pv_array_cols_w),
    .array_last_i(array_last_w), .array_matrix_i(array_matrix_w),
    .row_valid_o(pv_row_valid_w), .row_ready_i(1'b1), .row_index_o(pv_row_index_w),
    .row_half_o(pv_row_half_w), .row_data_o(pv_row_data_w),
    .done_o(pv_engine_done_w), .busy_o(), .error_o(pv_engine_error_w)
  );

  os_fsa_array u_array (
    .clk(clk), .rst_n(rst_n),
    .valid_i(array_phase_w == `ATTN_ARRAY_PHASE_QK ? qk_array_valid_w : pv_array_valid_w),
    .last_i(array_phase_w == `ATTN_ARRAY_PHASE_QK ? qk_array_last_w : pv_array_last_w),
    .mode_i(`ATTN_PE_MAC_INT8),
    .clear_acc_i(array_phase_w == `ATTN_ARRAY_PHASE_QK && qk_array_clear_w),
    .load_acc_i(array_phase_w == `ATTN_ARRAY_PHASE_PV && pv_array_load_w),
    .load_matrix_i(pv_array_load_matrix_w),
    .row_data_i(array_phase_w == `ATTN_ARRAY_PHASE_QK ? qk_array_rows_w : pv_array_rows_w),
    .col_data_i(array_phase_w == `ATTN_ARRAY_PHASE_QK ? qk_array_cols_w : pv_array_cols_w),
    .scale_mant_i(16'sd0), .scale_shift_i(6'd0),
    .valid_o(array_valid_w), .last_o(array_last_w), .matrix_o(array_matrix_w)
  );

  assign softmax_start_w = softmax_en_w && !softmax_en_d_q;
  assign softmax_clear_rows_w = load_q_en_w && !load_q_en_d_q;
  softmax_engine u_softmax (
    .clk(clk), .rst_n(rst_n), .clear_i(cfg_soft_reset_w), .clear_rows_i(softmax_clear_rows_w),
    .start_i(softmax_start_w), .score_tile_i(score_tile_w), .score_scale_i(cfg_score_scale_w),
    .q_base_i(q_tile_base_w), .k_base_i(kv_tile_base_w), .seq_q_i(cfg_seq_q_w), .seq_kv_i(cfg_seq_kv_w),
    .causal_en_i(cfg_causal_en_w), .beta_tile_o(beta_tile_w), .alpha_rows_o(alpha_rows_w),
    .m_rows_o(m_rows_w), .l_rows_o(l_rows_w), .done_o(softmax_done_w), .busy_o(), .error_o(softmax_error_w)
  );

  assign norm_acc_rd_en_w = (pv_flow_state_q == PV_FLOW_NORM_READ);
  assign norm_l_w = l_rows_w[norm_row_q*32 +: 32];

  online_normalizer u_normalizer (
    .clk(clk), .rst_n(rst_n), .valid_i(acc_rd_valid_w && pv_flow_state_q == PV_FLOW_NORM_WAIT),
    .acc_row_i(acc_rd_data_w), .l_i(norm_l_w), .out_scale_i(cfg_out_scale_w),
    .valid_o(norm_valid_w), .out_row_o(norm_row_data_w)
  );

  output_buffer u_output_buffer (
    .clk(clk), .rst_n(rst_n), .clear_tile_i(softmax_clear_rows_w),
    .acc_wr_valid_i(pv_row_valid_w), .acc_wr_row_i(pv_row_index_w), .acc_wr_half_i(pv_row_half_w), .acc_wr_data_i(pv_row_data_w),
    .acc_rd_en_i(pv_old_rd_en_w | norm_acc_rd_en_w),
    .acc_rd_row_i(pv_old_rd_en_w ? pv_old_rd_row_w : norm_row_q),
    .acc_rd_half_i(pv_old_rd_en_w ? pv_old_rd_half_w : norm_half_q),
    .acc_rd_data_o(acc_rd_data_w), .acc_rd_valid_o(acc_rd_valid_w),
    .out_wr_valid_i(norm_valid_w), .out_wr_row_i(norm_row_q), .out_wr_half_i(norm_half_q), .out_wr_data_i(norm_row_data_w),
    .stream_start_i(output_stream_start_w), .stream_bytes_i(output_stream_bytes_w),
    .stream_data_o(output_stream_data_w), .stream_strb_o(output_stream_strb_w), .stream_valid_o(output_stream_valid_w),
    .stream_ready_i(output_stream_ready_w), .stream_last_o(output_stream_last_w),
    .stream_busy_o(), .stream_done_o(output_stream_done_w)
  );

  always @(*) begin
    if ({1'b0, cfg_seq_q_w} > {1'b0, q_tile_base_w} + 17'd32) valid_q_rows_w = 16'd32;
    else valid_q_rows_w = cfg_seq_q_w - q_tile_base_w;
    writeback_beats_w = valid_q_rows_w << 2;
    address_offset_w = (({56'd0, head_index_w} * {48'd0, cfg_seq_q_w}) +
                        {48'd0, q_tile_base_w}) * {32'd0, cfg_o_stride_w};
    writeback_addr_w = cfg_o_base_w[31:0] + address_offset_w[31:0];
  end

  assign axi_write_start_w = wb_en_w && !wb_en_d_q;
  assign output_stream_start_w = axi_write_start_w;
  assign output_stream_bytes_w = valid_q_rows_w << 6;
  assign output_stream_ready_w = output_stream_valid_w && axi_data_ready_w;

  axi4_master_write u_axi_write (
    .clk(clk), .rst_n(rst_n), .start_i(axi_write_start_w), .base_addr_i(writeback_addr_w),
    .beat_count_i(writeback_beats_w), .burst_len_i(8'd16),
    .data_i(output_stream_data_w), .data_valid_i(output_stream_valid_w), .data_ready_o(axi_data_ready_w),
    .busy_o(axi_write_busy_w), .done_o(axi_write_done_w), .error_o(axi_write_error_w),
    .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
    .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
    .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
    .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
    .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready)
  );

  perf_counter u_perf (
    .clk(clk), .rst_n(rst_n), .clear_i(cfg_soft_reset_w | cfg_perf_ctrl_w[0]),
    .cycle_en_i(scheduler_busy_w),
    .stall_i((load_active_w && !(q_active_valid_w && kv_active_valid_w)) ||
             (writeback_active_w && (!m_axi_awready || !m_axi_wready))),
    .mac_valid_i(array_valid_w && (array_phase_w == `ATTN_ARRAY_PHASE_QK || array_phase_w == `ATTN_ARRAY_PHASE_PV)),
    .tile_done_i(pv_complete_q), .cycle_count_o(perf_cycles_w), .stall_count_o(perf_stall_w),
    .mac_count_o(perf_mac_w), .tile_count_o(perf_tiles_w)
  );

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      qk_en_d_q <= 1'b0;
      softmax_en_d_q <= 1'b0;
      pv_en_d_q <= 1'b0;
      wb_en_d_q <= 1'b0;
      load_q_en_d_q <= 1'b0;
      pv_flow_state_q <= PV_FLOW_IDLE;
      pv_half_q <= 1'b0;
      pv_complete_q <= 1'b0;
      norm_row_q <= 5'd0;
      norm_half_q <= 1'b0;
    end else if (cfg_soft_reset_w) begin
      qk_en_d_q <= 1'b0;
      softmax_en_d_q <= 1'b0;
      pv_en_d_q <= 1'b0;
      wb_en_d_q <= 1'b0;
      load_q_en_d_q <= 1'b0;
      pv_flow_state_q <= PV_FLOW_IDLE;
      pv_half_q <= 1'b0;
      pv_complete_q <= 1'b0;
      norm_row_q <= 5'd0;
      norm_half_q <= 1'b0;
    end else begin
      qk_en_d_q <= qk_en_w;
      softmax_en_d_q <= softmax_en_w;
      pv_en_d_q <= pv_en_w;
      wb_en_d_q <= wb_en_w;
      load_q_en_d_q <= load_q_en_w;
      pv_complete_q <= 1'b0;
      case (pv_flow_state_q)
        PV_FLOW_IDLE: begin
          if (pv_en_w && !pv_en_d_q) begin
            pv_half_q <= 1'b0;
            pv_flow_state_q <= PV_FLOW_REQ0;
          end
        end
        PV_FLOW_REQ0: if (pv_go_w) pv_flow_state_q <= PV_FLOW_WAIT0;
        PV_FLOW_WAIT0: begin
          if (pv_engine_done_w) begin
            pv_half_q <= 1'b1;
            pv_flow_state_q <= PV_FLOW_REQ1;
          end
        end
        PV_FLOW_REQ1: if (pv_go_w) pv_flow_state_q <= PV_FLOW_WAIT1;
        PV_FLOW_WAIT1: begin
          if (pv_engine_done_w) begin
            if (tile_last_w) begin
              norm_row_q <= 5'd0;
              norm_half_q <= 1'b0;
              pv_flow_state_q <= PV_FLOW_NORM_READ;
            end else begin
              pv_flow_state_q <= PV_FLOW_COMPLETE;
            end
          end
        end
        PV_FLOW_NORM_READ: pv_flow_state_q <= PV_FLOW_NORM_WAIT;
        PV_FLOW_NORM_WAIT: begin
          if (norm_valid_w) begin
            if (norm_half_q) begin
              norm_half_q <= 1'b0;
              if (norm_row_q == 31) pv_flow_state_q <= PV_FLOW_COMPLETE;
              else begin norm_row_q <= norm_row_q + 1'b1; pv_flow_state_q <= PV_FLOW_NORM_READ; end
            end else begin
              norm_half_q <= 1'b1;
              pv_flow_state_q <= PV_FLOW_NORM_READ;
            end
          end
        end
        PV_FLOW_COMPLETE: begin
          pv_complete_q <= 1'b1;
          pv_flow_state_q <= PV_FLOW_IDLE;
        end
        default: pv_flow_state_q <= PV_FLOW_IDLE;
      endcase
    end
  end

endmodule
