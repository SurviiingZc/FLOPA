`timescale 1ns/1ps
`include "attention_defines.vh"

// FlashAttention accelerator integration: AXI control/writeback, ping-pong QKV
// cache, fused QK/online-softmax/WS-PV array, persistent O, and final normalization.
module attention_accel_top #(
  parameter integer ARRAY_ROWS = `ATTN_ARRAY_ROWS,
  parameter integer ARRAY_COLS = `ATTN_ARRAY_COLS,
  parameter integer ARRAY_DATA_W = `ATTN_ARRAY_DATA_W,
  parameter integer ACC_W = `ATTN_ACC_W,
  parameter integer BETA_W = `ATTN_BETA_W,
  parameter integer LSE_W = `ATTN_LSE_W,
  parameter integer OUT_W = `ATTN_OUT_W,
  parameter integer HEAD_DIM = `ATTN_HEAD_DIM,
  parameter integer CACHE_WORD_W = `ATTN_CACHE_WORD_W,
  parameter integer CACHE_ADDR_W = (HEAD_DIM < 2) ? 1 : $clog2(HEAD_DIM),
  parameter integer STRIPE_ROWS = `ATTN_ARRAY_STRIPE_ROWS
)(
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
  input  [CACHE_ADDR_W-1:0] tile_load_addr_i,
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

  localparam integer ARRAY_ROW_W = ARRAY_ROWS * ARRAY_DATA_W;
  localparam integer ARRAY_COL_W = ARRAY_COLS * ARRAY_DATA_W;
  localparam integer CACHE_LANES = CACHE_WORD_W / `ATTN_DATA_W;
  localparam integer NUM_STRIPES = ARRAY_ROWS / STRIPE_ROWS;
  localparam integer STRIPE_IDX_W = (NUM_STRIPES < 2) ? 1 : $clog2(NUM_STRIPES);
  localparam integer FEATURE_IDX_W = (HEAD_DIM < 2) ? 1 : $clog2(HEAD_DIM);
  localparam integer NORM_TAG_W = STRIPE_IDX_W + FEATURE_IDX_W;
  localparam integer OUTPUT_GROUP_SIZE = 32;
  localparam [4:0] OUTPUT_GROUP_LAST = OUTPUT_GROUP_SIZE - 1;
  localparam [FEATURE_IDX_W-1:0] FEATURE_LAST = HEAD_DIM - 1;
  localparam [STRIPE_IDX_W-1:0] STRIPE_LAST = NUM_STRIPES - 1;
  localparam [16:0] ARRAY_ROWS_17 = ARRAY_ROWS;
  localparam [15:0] ARRAY_ROWS_16 = ARRAY_ROWS;

`ifndef SYNTHESIS
  // The physical array consumes exactly one 256-bit cache word per issue cycle.
  initial begin
    if (ARRAY_ROWS != CACHE_LANES || ARRAY_COLS != CACHE_LANES)
      $fatal(1, "physical array dimensions must equal CACHE_LANES");
    if (ARRAY_ROWS % STRIPE_ROWS != 0)
      $fatal(1, "ARRAY_ROWS must be divisible by STRIPE_ROWS");
  end
`endif

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
  wire [CACHE_ADDR_W-1:0] q_cache_rd_addr_w;
  wire [CACHE_WORD_W-1:0] q_cache_rd_data_w;
  wire q_cache_rd_valid_w;
  wire k_cache_rd_en_w;
  wire [CACHE_ADDR_W-1:0] k_cache_rd_addr_w;
  wire [CACHE_WORD_W-1:0] k_cache_rd_data_w;
  wire k_cache_rd_valid_w;
  wire v_cache_rd_en_w;
  wire [CACHE_ADDR_W-1:0] v_cache_rd_addr_w;
  wire [CACHE_WORD_W-1:0] v_cache_rd_data_w;
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
  wire [ARRAY_ROW_W-1:0] qk_array_rows_w;
  wire [ARRAY_COL_W-1:0] qk_array_cols_w;
  wire qk_done_w;
  wire qk_error_w;
  wire fused_qk_last_w;
  wire pv_array_start_w;
  wire pv_array_ready_w;
  wire pv_array_seed_zero_w;
  wire pv_array_valid_w;
  wire pv_array_last_w;
  wire [FEATURE_IDX_W-1:0] pv_array_feature_w;
  wire [ARRAY_COL_W-1:0] pv_array_cols_w;
  wire pv_engine_done_w;
  wire pv_engine_error_w;
  wire fused_array_pv_done_w;
  wire fused_array_error_w;

  wire softmax_start_w;
  wire softmax_clear_rows_w;
  wire softmax_pv_ready_w;
  wire softmax_done_w;
  wire softmax_error_w;

  reg [3:0] pv_flow_state_q;
  reg pv_complete_q;
  reg l_update_done_q;
  reg [STRIPE_IDX_W-1:0] norm_stripe_q;
  reg [FEATURE_IDX_W-1:0] norm_feature_q;
  wire norm_rd_en_w;
  wire norm_rd_valid_w;
  wire [STRIPE_ROWS*ACC_W-1:0] norm_acc_rows_w;
  wire [STRIPE_ROWS*LSE_W-1:0] norm_l_rows_w;
  wire [STRIPE_IDX_W-1:0] norm_rd_stripe_w;
  wire [FEATURE_IDX_W-1:0] norm_rd_feature_w;
  wire norm_valid_w;
  wire [STRIPE_ROWS*OUT_W-1:0] norm_rows_data_w;
  wire [NORM_TAG_W-1:0] norm_tag_w;
  wire norm_output_ready_w;
  wire norm_group_done_w;

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
  reg [31:0] writeback_addr_q;
  reg [31:0] head_base_addr_q;
  reg [63:0] head_stride_bytes_q;
  reg [15:0] writeback_beats_w;
  reg [15:0] valid_q_rows_w;
  reg [31:0] writeback_bytes_w;
  reg [31:0] writeback_beats_full_w;

  reg qk_en_d_q;
  reg softmax_en_d_q;
  reg pv_en_d_q;
  reg wb_en_d_q;
  reg load_q_en_d_q;
  wire fatal_error_w;
  wire [3:0] debug_state_reg_w;
  wire axi_data_ready_w;

  // PV completion is separated from final normalization: non-final KV tiles keep
  // (m,l,O) on chip and return immediately to LOAD_KV; only the last tile scans O.
  localparam PV_FLOW_IDLE = 4'd0;
  localparam PV_FLOW_REQ = 4'd1;
  localparam PV_FLOW_WAIT = 4'd2;
  localparam PV_FLOW_NORM_ISSUE = 4'd3;
  localparam PV_FLOW_NORM_DRAIN = 4'd4;
  localparam PV_FLOW_COMPLETE = 4'd5;
  localparam PV_FLOW_WAIT_L = 4'd6;

  assign debug_state_o = debug_state_reg_w;
  assign irq_o = scheduler_done_w | scheduler_error_w;
  assign fatal_error_w = cache_protocol_error_w | array_controller_error_w | qk_error_w |
                         pv_engine_error_w | softmax_error_w | axi_write_error_w;

  // Control plane: software-visible shadow registers feed the job scheduler.
  accel_regfile #(.HEAD_DIM(HEAD_DIM)) u_regfile (
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
    .qk_done_i(qk_done_w), .softmax_pv_ready_i(softmax_pv_ready_w),
    .pv_done_i(pv_complete_q), .wb_done_i(axi_write_done_w),
    .state_o(debug_state_reg_w), .busy_o(scheduler_busy_w), .done_o(scheduler_done_w),
    .error_o(scheduler_error_w), .error_code_o(scheduler_error_code_w), .idle_o(scheduler_idle_w),
    .load_active_o(load_active_w), .compute_active_o(compute_active_w), .writeback_active_o(writeback_active_w),
    .load_q_en_o(load_q_en_w), .load_kv_en_o(load_kv_en_w), .qk_en_o(qk_en_w),
    .softmax_en_o(softmax_en_w), .pv_en_o(pv_en_w), .wb_en_o(wb_en_w),
    .head_index_o(head_index_w), .q_tile_index_o(q_tile_index_w), .kv_tile_index_o(kv_tile_index_w),
    .q_tile_base_o(q_tile_base_w), .kv_tile_base_o(kv_tile_base_w), .tile_last_o(tile_last_w), .run_last_o(run_last_w)
  );

  // Q persists across all KV tiles for a Q tile; K/V are consumed after each PV.
  assign q_consume_w = axi_write_done_w;
  assign q_switch_w = load_q_en_w && !q_active_valid_w && q_next_valid_w;
  assign kv_consume_w = pv_complete_q;
  assign kv_switch_w = load_kv_en_w && !kv_active_valid_w && kv_next_valid_w;

  // Data plane loader writes the inactive ping-pong banks while compute reads active.
  qkv_tile_cache #(.ADDR_W(CACHE_ADDR_W)) u_tile_cache (
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

  // Convert scheduler levels into one-cycle starts for the shared-array controller.
  assign qk_request_w = qk_en_w && !qk_en_d_q;
  assign pv_request_w = (pv_flow_state_q == PV_FLOW_REQ);

  fsa_controller u_array_controller (
    .clk(clk), .rst_n(rst_n), .clear_i(cfg_soft_reset_w),
    .qk_start_i(qk_request_w), .pv_start_i(pv_request_w), .qk_done_i(qk_done_w), .pv_done_i(pv_engine_done_w),
    .qk_error_i(qk_error_w), .pv_error_i(pv_engine_error_w), .phase_o(array_phase_w),
    .qk_go_o(qk_go_w), .pv_go_o(pv_go_w), .busy_o(), .error_o(array_controller_error_w)
  );

  // QK streams HEAD_DIM feature slices; PV later reuses the same vertical network.
  fsa_qk_engine #(
    .CACHE_ADDR_W(CACHE_ADDR_W), .CACHE_WORD_W(CACHE_WORD_W),
    .ARRAY_ROWS(ARRAY_ROWS), .ARRAY_COLS(ARRAY_COLS),
    .ARRAY_DATA_W(ARRAY_DATA_W), .HEAD_DIM(HEAD_DIM)
  ) u_qk_engine (
    .clk(clk), .rst_n(rst_n), .clear_i(cfg_soft_reset_w), .start_i(qk_go_w), .head_dim_i(cfg_head_dim_w),
    .q_rd_en_o(q_cache_rd_en_w), .q_rd_addr_o(q_cache_rd_addr_w), .q_rd_data_i(q_cache_rd_data_w), .q_rd_valid_i(q_cache_rd_valid_w),
    .k_rd_en_o(k_cache_rd_en_w), .k_rd_addr_o(k_cache_rd_addr_w), .k_rd_data_i(k_cache_rd_data_w), .k_rd_valid_i(k_cache_rd_valid_w),
    .array_clear_o(qk_array_clear_w), .array_valid_o(qk_array_valid_w), .array_last_o(qk_array_last_w),
    .array_rows_o(qk_array_rows_w), .array_cols_o(qk_array_cols_w),
    .array_last_i(fused_qk_last_w),
    .done_o(qk_done_w), .busy_o(), .error_o(qk_error_w)
  );

  // PV emits V[:,d] and d together. first_kv_tile selects zero instead of O_old.
  fsa_pv_engine #(
    .CACHE_ADDR_W(CACHE_ADDR_W), .CACHE_WORD_W(CACHE_WORD_W),
    .ARRAY_COLS(ARRAY_COLS), .ARRAY_DATA_W(ARRAY_DATA_W),
    .HEAD_DIM(HEAD_DIM)
  ) u_pv_engine (
    .clk(clk), .rst_n(rst_n), .clear_i(cfg_soft_reset_w), .start_i(pv_go_w),
    .first_kv_tile_i(kv_tile_index_w == 0),
    .v_rd_en_o(v_cache_rd_en_w), .v_rd_addr_o(v_cache_rd_addr_w), .v_rd_data_i(v_cache_rd_data_w), .v_rd_valid_i(v_cache_rd_valid_w),
    .array_start_o(pv_array_start_w), .array_ready_i(pv_array_ready_w),
    .array_seed_zero_o(pv_array_seed_zero_w),
    .array_valid_o(pv_array_valid_w),
    .array_last_o(pv_array_last_w),
    .array_feature_o(pv_array_feature_w),
    .array_cols_o(pv_array_cols_w), .array_done_i(fused_array_pv_done_w),
    .done_o(pv_engine_done_w), .busy_o(), .error_o(pv_engine_error_w)
  );

  assign softmax_start_w = softmax_en_w && !softmax_en_d_q;
  assign softmax_clear_rows_w = load_q_en_w && !load_q_en_d_q;
  // The fused array owns all PE-local score/P state, row state, and persistent O.
  fsa_fused_array #(
    .ROWS(ARRAY_ROWS), .STRIPE_ROWS(STRIPE_ROWS),
    .COLS(ARRAY_COLS), .DATA_W(ARRAY_DATA_W),
    .SCORE_W(ACC_W), .PROB_W(BETA_W), .ACC_W(ACC_W), .LSE_W(LSE_W),
    .HEAD_DIM(HEAD_DIM), .FEATURE_IDX_W(FEATURE_IDX_W)
  ) u_fused_array (
    .clk(clk), .rst_n(rst_n), .clear_i(cfg_soft_reset_w),
    .clear_rows_i(softmax_clear_rows_w),
    .qk_clear_i(qk_array_clear_w), .qk_valid_i(qk_array_valid_w),
    .qk_last_i(qk_array_last_w), .qk_rows_i(qk_array_rows_w),
    .qk_cols_i(qk_array_cols_w), .qk_last_o(fused_qk_last_w),
    .softmax_start_i(softmax_start_w), .score_scale_i(cfg_score_scale_w),
    .q_base_i(q_tile_base_w), .k_base_i(kv_tile_base_w),
    .seq_q_i(cfg_seq_q_w), .seq_kv_i(cfg_seq_kv_w),
    .causal_en_i(cfg_causal_en_w),
    .row_state_rd_en_i(1'b0),
    .row_state_rd_row_i({((ARRAY_ROWS < 2) ? 1 : $clog2(ARRAY_ROWS)){1'b0}}),
    .row_state_rd_valid_o(), .row_state_alpha_o(), .row_state_l_o(),
    .softmax_pv_ready_o(softmax_pv_ready_w),
    .softmax_done_o(softmax_done_w),
    .softmax_busy_o(),
    .pv_start_i(pv_array_start_w), .pv_ready_o(pv_array_ready_w),
    .pv_seed_zero_i(pv_array_seed_zero_w),
    .pv_valid_i(pv_array_valid_w),
    .pv_last_i(pv_array_last_w), .pv_feature_i(pv_array_feature_w),
    .pv_cols_i(pv_array_cols_w), .pv_done_o(fused_array_pv_done_w),
    .norm_rd_en_i(norm_rd_en_w), .norm_rd_stripe_i(norm_stripe_q),
    .norm_rd_feature_i(norm_feature_q), .norm_rd_valid_o(norm_rd_valid_w),
    .norm_rd_acc_o(norm_acc_rows_w), .norm_rd_l_o(norm_l_rows_w),
    .norm_rd_stripe_o(norm_rd_stripe_w),
    .norm_rd_feature_o(norm_rd_feature_w),
    .error_o(fused_array_error_w)
  );

  assign softmax_error_w = fused_array_error_w;

  // After the final KV tile, scan one eight-row stripe and one feature per cycle.
  assign norm_rd_en_w = (pv_flow_state_q == PV_FLOW_NORM_ISSUE) &&
                        norm_output_ready_w;

  online_normalizer #(
    .LANES(STRIPE_ROWS), .ACC_W(ACC_W), .LSE_W(LSE_W),
    .OUT_W(OUT_W), .TAG_W(NORM_TAG_W)
  ) u_normalizer (
    .clk(clk), .rst_n(rst_n),
    .valid_i(norm_rd_valid_w), .acc_rows_i(norm_acc_rows_w),
    .l_rows_i(norm_l_rows_w), .out_scale_i(cfg_out_scale_w),
    .tag_i({norm_rd_stripe_w, norm_rd_feature_w}),
    .valid_o(norm_valid_w), .out_rows_o(norm_rows_data_w), .tag_o(norm_tag_w)
  );

  output_buffer #(
    .ROWS(ARRAY_ROWS), .NORM_LANES(STRIPE_ROWS), .HEAD_DIM(HEAD_DIM),
    .OUT_W(OUT_W), .GROUP_SIZE(OUTPUT_GROUP_SIZE)
  ) u_output_buffer (
    .clk(clk), .rst_n(rst_n), .clear_tile_i(softmax_clear_rows_w),
    .norm_valid_i(norm_valid_w),
    .norm_stripe_i(norm_tag_w[NORM_TAG_W-1 -: STRIPE_IDX_W]),
    .norm_feature_i(norm_tag_w[FEATURE_IDX_W-1:0]),
    .norm_data_i(norm_rows_data_w), .norm_ready_o(norm_output_ready_w),
    .norm_group_done_o(norm_group_done_w),
    .stream_start_i(output_stream_start_w), .stream_bytes_i(output_stream_bytes_w),
    .stream_data_o(output_stream_data_w), .stream_strb_o(output_stream_strb_w), .stream_valid_o(output_stream_valid_w),
    .stream_ready_i(output_stream_ready_w), .stream_last_o(output_stream_last_w),
    .stream_busy_o(), .stream_done_o(output_stream_done_w)
  );

  // Tail Q tiles write only valid rows; convert the byte count to 128-bit AXI beats.
  always @(*) begin
    if ({1'b0, cfg_seq_q_w} > {1'b0, q_tile_base_w} + ARRAY_ROWS_17)
      valid_q_rows_w = ARRAY_ROWS_16;
    else valid_q_rows_w = cfg_seq_q_w - q_tile_base_w;
    writeback_bytes_w = valid_q_rows_w * HEAD_DIM * (OUT_W/8);
    writeback_beats_full_w = (writeback_bytes_w + 15) >> 4;
    writeback_beats_w = writeback_beats_full_w[15:0];
  end

  assign axi_write_start_w = wb_en_w && !wb_en_d_q;
  assign output_stream_start_w = axi_write_start_w;
  assign output_stream_bytes_w = writeback_bytes_w[15:0];
  assign output_stream_ready_w = output_stream_valid_w && axi_data_ready_w;

  axi4_master_write u_axi_write (
    .clk(clk), .rst_n(rst_n), .start_i(axi_write_start_w), .base_addr_i(writeback_addr_q),
    .beat_count_i(writeback_beats_w), .burst_len_i(8'd16),
    .data_i(output_stream_data_w), .data_valid_i(output_stream_valid_w), .data_ready_o(axi_data_ready_w),
    .busy_o(axi_write_busy_w), .done_o(axi_write_done_w), .error_o(axi_write_error_w),
    .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
    .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
    .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
    .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
    .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready)
  );

  // Architectural counters measure end-to-end scheduler time, including stalls.
  perf_counter u_perf (
    .clk(clk), .rst_n(rst_n), .clear_i(cfg_soft_reset_w | cfg_perf_ctrl_w[0]),
    .cycle_en_i(scheduler_busy_w),
    .stall_i((load_active_w && !(q_active_valid_w && kv_active_valid_w)) ||
             (writeback_active_w && (!m_axi_awready || !m_axi_wready))),
    .mac_valid_i(qk_array_valid_w || pv_array_valid_w),
    .tile_done_i(pv_complete_q), .cycle_count_o(perf_cycles_w), .stall_count_o(perf_stall_w),
    .mac_count_o(perf_mac_w), .tile_count_o(perf_tiles_w)
  );

  // Coordinate PV with the serialized l update and final normalization. WS-PV may
  // finish before l, but a KV tile is not released until both states are complete.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      qk_en_d_q <= 1'b0;
      softmax_en_d_q <= 1'b0;
      pv_en_d_q <= 1'b0;
      wb_en_d_q <= 1'b0;
      load_q_en_d_q <= 1'b0;
      pv_flow_state_q <= PV_FLOW_IDLE;
      pv_complete_q <= 1'b0;
      l_update_done_q <= 1'b0;
      norm_stripe_q <= {STRIPE_IDX_W{1'b0}};
      norm_feature_q <= {FEATURE_IDX_W{1'b0}};
      writeback_addr_q <= 32'd0;
      head_base_addr_q <= 32'd0;
      head_stride_bytes_q <= 64'd0;
    end else if (cfg_soft_reset_w) begin
      qk_en_d_q <= 1'b0;
      softmax_en_d_q <= 1'b0;
      pv_en_d_q <= 1'b0;
      wb_en_d_q <= 1'b0;
      load_q_en_d_q <= 1'b0;
      pv_flow_state_q <= PV_FLOW_IDLE;
      pv_complete_q <= 1'b0;
      l_update_done_q <= 1'b0;
      norm_stripe_q <= {STRIPE_IDX_W{1'b0}};
      norm_feature_q <= {FEATURE_IDX_W{1'b0}};
      writeback_addr_q <= cfg_o_base_w[31:0];
      head_base_addr_q <= cfg_o_base_w[31:0];
      head_stride_bytes_q <= {48'd0, cfg_seq_q_w} * cfg_o_stride_w;
    end else begin
      qk_en_d_q <= qk_en_w;
      softmax_en_d_q <= softmax_en_w;
      pv_en_d_q <= pv_en_w;
      wb_en_d_q <= wb_en_w;
      load_q_en_d_q <= load_q_en_w;
      pv_complete_q <= 1'b0;
      // Maintain writeback addresses incrementally to avoid runtime address
      // multipliers on every Q-tile transition.
      if (cfg_start_w) begin
        writeback_addr_q <= cfg_o_base_w[31:0];
        head_base_addr_q <= cfg_o_base_w[31:0];
        head_stride_bytes_q <= {48'd0, cfg_seq_q_w} * cfg_o_stride_w;
      end else if (axi_write_done_w) begin
        if ({1'b0, q_tile_base_w} + ARRAY_ROWS_17 >= {1'b0, cfg_seq_q_w}) begin
          head_base_addr_q <= head_base_addr_q + head_stride_bytes_q[31:0];
          writeback_addr_q <= head_base_addr_q + head_stride_bytes_q[31:0];
        end else begin
          writeback_addr_q <= writeback_addr_q + ARRAY_ROWS*cfg_o_stride_w;
        end
      end
      if (softmax_start_w)
        l_update_done_q <= 1'b0;
      else if (softmax_done_w)
        l_update_done_q <= 1'b1;
      // Non-final tiles skip normalization and preserve O-bank contents in place.
      case (pv_flow_state_q)
        PV_FLOW_IDLE: begin
          if (pv_en_w && !pv_en_d_q) begin
            pv_flow_state_q <= PV_FLOW_REQ;
          end
        end
        PV_FLOW_REQ: if (pv_go_w) pv_flow_state_q <= PV_FLOW_WAIT;
        PV_FLOW_WAIT: begin
          if (pv_engine_done_w) begin
            if (!l_update_done_q)
              pv_flow_state_q <= PV_FLOW_WAIT_L;
            else if (tile_last_w) begin
              norm_stripe_q <= {STRIPE_IDX_W{1'b0}};
              norm_feature_q <= {FEATURE_IDX_W{1'b0}};
              pv_flow_state_q <= PV_FLOW_NORM_ISSUE;
            end else
              pv_flow_state_q <= PV_FLOW_COMPLETE;
          end
        end
        PV_FLOW_WAIT_L: begin
          if (l_update_done_q) begin
            if (tile_last_w) begin
              norm_stripe_q <= {STRIPE_IDX_W{1'b0}};
              norm_feature_q <= {FEATURE_IDX_W{1'b0}};
              pv_flow_state_q <= PV_FLOW_NORM_ISSUE;
            end else
              pv_flow_state_q <= PV_FLOW_COMPLETE;
          end
        end
        PV_FLOW_NORM_ISSUE: begin
          if (norm_output_ready_w) begin
            if ((norm_feature_q[4:0] == OUTPUT_GROUP_LAST) ||
                (norm_feature_q == FEATURE_LAST))
              pv_flow_state_q <= PV_FLOW_NORM_DRAIN;
            else
              norm_feature_q <= norm_feature_q + 1'b1;
          end
        end
        PV_FLOW_NORM_DRAIN: begin
          if (norm_group_done_w) begin
            if (norm_feature_q == FEATURE_LAST) begin
              norm_feature_q <= {FEATURE_IDX_W{1'b0}};
              if (norm_stripe_q == STRIPE_LAST)
                pv_flow_state_q <= PV_FLOW_COMPLETE;
              else begin
                norm_stripe_q <= norm_stripe_q + 1'b1;
                pv_flow_state_q <= PV_FLOW_NORM_ISSUE;
              end
            end else begin
              norm_feature_q <= norm_feature_q + 1'b1;
              pv_flow_state_q <= PV_FLOW_NORM_ISSUE;
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
