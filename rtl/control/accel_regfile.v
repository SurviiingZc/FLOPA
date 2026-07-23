`timescale 1ns/1ps
`include "attention_defines.vh"

// AXI4-Lite programming model. Software writes shadow registers; a valid START
// atomically snapshots them into cfg_* outputs so a running job is immutable.
module accel_regfile #(
  parameter ADDR_W = `ATTN_AXI_ADDR_W,
  parameter HEAD_DIM = `ATTN_HEAD_DIM
)(
  input                  clk,
  input                  rst_n,
  input  [ADDR_W-1:0]    s_axi_awaddr,
  input                  s_axi_awvalid,
  output                 s_axi_awready,
  input  [31:0]          s_axi_wdata,
  input  [3:0]           s_axi_wstrb,
  input                  s_axi_wvalid,
  output                 s_axi_wready,
  output reg [1:0]       s_axi_bresp,
  output reg             s_axi_bvalid,
  input                  s_axi_bready,
  input  [ADDR_W-1:0]    s_axi_araddr,
  input                  s_axi_arvalid,
  output                 s_axi_arready,
  output reg [31:0]      s_axi_rdata,
  output reg [1:0]       s_axi_rresp,
  output reg             s_axi_rvalid,
  input                  s_axi_rready,
  output reg             cfg_start_pulse_o,
  output reg             cfg_soft_reset_pulse_o,
  output reg             cfg_clear_done_pulse_o,
  output reg             cfg_clear_error_pulse_o,
  output reg             cfg_mode_sel_o,
  output reg             cfg_causal_en_o,
  output reg             cfg_prefill_en_o,
  output reg             cfg_decode_en_o,
  output reg [63:0]      cfg_q_base_o,
  output reg [63:0]      cfg_k_base_o,
  output reg [63:0]      cfg_v_base_o,
  output reg [63:0]      cfg_o_base_o,
  output reg [31:0]      cfg_q_stride_o,
  output reg [31:0]      cfg_k_stride_o,
  output reg [31:0]      cfg_v_stride_o,
  output reg [31:0]      cfg_o_stride_o,
  output reg [15:0]      cfg_seq_q_o,
  output reg [15:0]      cfg_seq_kv_o,
  output reg [7:0]       cfg_num_q_heads_o,
  output reg [7:0]       cfg_num_kv_heads_o,
  output reg [7:0]       cfg_head_dim_o,
  output reg [7:0]       cfg_tile_q_o,
  output reg [7:0]       cfg_tile_k_o,
  output reg [31:0]      cfg_score_scale_o,
  output reg [31:0]      cfg_value_scale_o,
  output reg [31:0]      cfg_out_scale_o,
  output reg [31:0]      cfg_mask_cfg_o,
  output reg [31:0]      cfg_perf_ctrl_o,
  input                  busy_i,
  input                  done_i,
  input                  error_i,
  input  [3:0]           error_code_i,
  input                  idle_i,
  input                  load_active_i,
  input                  compute_active_i,
  input                  writeback_active_i,
  input  [63:0]          perf_cycles_i,
  input  [63:0]          perf_stall_i,
  input  [63:0]          perf_mac_i,
  input  [31:0]          perf_tiles_i
);

  wire wr_fire_w;
  wire rd_fire_w;
  wire [ADDR_W-1:0] wr_addr_w;
  wire [31:0] wr_data_w;
  wire [3:0] wr_strb_w;
  wire [ADDR_W-1:0] rd_addr_w;
  reg [3:0] sticky_error_q;

  reg prog_mode_sel_q;
  reg prog_causal_en_q;
  reg prog_prefill_en_q;
  reg prog_decode_en_q;
  reg [63:0] prog_q_base_q;
  reg [63:0] prog_k_base_q;
  reg [63:0] prog_v_base_q;
  reg [63:0] prog_o_base_q;
  reg [31:0] prog_q_stride_q;
  reg [31:0] prog_k_stride_q;
  reg [31:0] prog_v_stride_q;
  reg [31:0] prog_o_stride_q;
  reg [15:0] prog_seq_q_q;
  reg [15:0] prog_seq_kv_q;
  reg [7:0] prog_num_q_heads_q;
  reg [7:0] prog_num_kv_heads_q;
  reg [7:0] prog_head_dim_q;
  reg [7:0] prog_tile_q_q;
  reg [7:0] prog_tile_k_q;
  reg [31:0] prog_score_scale_q;
  reg [31:0] prog_value_scale_q;
  reg [31:0] prog_out_scale_q;
  reg [31:0] prog_mask_cfg_q;
  reg [31:0] prog_perf_ctrl_q;
  localparam [7:0] HEAD_DIM_CFG = HEAD_DIM;

  wire control_write_w;
  wire requested_start_w;
  wire start_mode_sel_w;
  wire start_causal_en_w;
  wire start_prefill_en_w;
  wire start_decode_en_w;
  wire start_cfg_valid_w;
  wire start_alignment_valid_w;

  // START accepts fixed-tile MHA prefill or single-token MHA decode. Decode
  // retains the physical 32-row tile but requires seq_q=1; row masking happens
  // inside the fused array after this configuration snapshot is taken.
  assign control_write_w = wr_fire_w && wr_addr_w[11:0] == `ATTN_REG_CONTROL && wr_strb_w[0];
  assign requested_start_w = control_write_w && wr_data_w[`ATTN_CTRL_START_BIT];
  assign start_mode_sel_w = control_write_w ? wr_data_w[`ATTN_CTRL_MODE_SEL_BIT] : prog_mode_sel_q;
  assign start_causal_en_w = control_write_w ? wr_data_w[`ATTN_CTRL_CAUSAL_EN_BIT] : prog_causal_en_q;
  assign start_prefill_en_w = control_write_w ? wr_data_w[`ATTN_CTRL_PREFILL_EN_BIT] : prog_prefill_en_q;
  assign start_decode_en_w = control_write_w ? wr_data_w[`ATTN_CTRL_DECODE_EN_BIT] : prog_decode_en_q;
  assign start_alignment_valid_w = (prog_q_base_q[3:0] == 0) && (prog_k_base_q[3:0] == 0) &&
                                   (prog_v_base_q[3:0] == 0) && (prog_o_base_q[3:0] == 0);
  assign start_cfg_valid_w = prog_seq_q_q != 0 && prog_seq_kv_q != 0 &&
      prog_num_q_heads_q != 0 && prog_num_kv_heads_q != 0 &&
      prog_head_dim_q == HEAD_DIM_CFG && prog_tile_q_q == `ATTN_TILE_Q &&
      prog_tile_k_q == `ATTN_TILE_K && !start_mode_sel_w &&
      prog_num_q_heads_q == prog_num_kv_heads_q && start_alignment_valid_w &&
      ((start_prefill_en_w && !start_decode_en_w) ||
       (!start_prefill_en_w && start_decode_en_w && prog_seq_q_q == 16'd1));

  axi4_slave_if #(.ADDR_W(ADDR_W)) u_axi_lite_if (
    .clk(clk), .rst_n(rst_n), .wr_block_i(s_axi_bvalid), .rd_block_i(s_axi_rvalid),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .wr_fire_o(wr_fire_w), .rd_fire_o(rd_fire_w), .wr_addr_o(wr_addr_w),
    .wr_data_o(wr_data_w), .wr_strb_o(wr_strb_w), .rd_addr_o(rd_addr_w)
  );

  // Byte-enable helpers preserve untouched bytes for partial AXI4-Lite writes.
  function [31:0] merge_wstrb;
    input [31:0] old_value;
    input [31:0] new_value;
    input [3:0] byte_enable;
    integer byte_idx;
    begin
      merge_wstrb = old_value;
      for (byte_idx = 0; byte_idx < 4; byte_idx = byte_idx + 1)
        if (byte_enable[byte_idx]) merge_wstrb[byte_idx*8 +: 8] = new_value[byte_idx*8 +: 8];
    end
  endfunction

  function [15:0] merge_wstrb16;
    input [15:0] old_value;
    input [31:0] new_value;
    input [3:0] byte_enable;
    begin
      merge_wstrb16 = old_value;
      if (byte_enable[0]) merge_wstrb16[7:0] = new_value[7:0];
      if (byte_enable[1]) merge_wstrb16[15:8] = new_value[15:8];
    end
  endfunction

  function [7:0] merge_wstrb8;
    input [7:0] old_value;
    input [31:0] new_value;
    input [3:0] byte_enable;
    begin
      merge_wstrb8 = old_value;
      if (byte_enable[0]) merge_wstrb8 = new_value[7:0];
    end
  endfunction

  // Address classifiers centralize DECERR behavior for the read/write channels.
  function is_known_addr;
    input [ADDR_W-1:0] addr;
    begin
      case (addr[11:0])
        `ATTN_REG_CONTROL, `ATTN_REG_STATUS, `ATTN_REG_ERROR_CODE, `ATTN_REG_VERSION,
        `ATTN_REG_Q_BASE_LO, `ATTN_REG_Q_BASE_HI, `ATTN_REG_K_BASE_LO, `ATTN_REG_K_BASE_HI,
        `ATTN_REG_V_BASE_LO, `ATTN_REG_V_BASE_HI, `ATTN_REG_O_BASE_LO, `ATTN_REG_O_BASE_HI,
        `ATTN_REG_Q_STRIDE, `ATTN_REG_K_STRIDE, `ATTN_REG_V_STRIDE, `ATTN_REG_O_STRIDE,
        `ATTN_REG_SEQ_Q, `ATTN_REG_SEQ_KV, `ATTN_REG_NUM_Q_HEADS, `ATTN_REG_NUM_KV_HEADS,
        `ATTN_REG_HEAD_DIM, `ATTN_REG_TILE_Q, `ATTN_REG_TILE_K, `ATTN_REG_MODE,
        `ATTN_REG_SCORE_SCALE, `ATTN_REG_VALUE_SCALE, `ATTN_REG_OUT_SCALE, `ATTN_REG_MASK_CFG,
        `ATTN_REG_PERF_CTRL, `ATTN_REG_PERF_CYCLES_LO, `ATTN_REG_PERF_CYCLES_HI,
        `ATTN_REG_PERF_STALL_LO, `ATTN_REG_PERF_STALL_HI, `ATTN_REG_PERF_MAC_LO,
        `ATTN_REG_PERF_MAC_HI, `ATTN_REG_PERF_TILES: is_known_addr = 1'b1;
        default: is_known_addr = 1'b0;
      endcase
    end
  endfunction

  function is_writable_addr;
    input [ADDR_W-1:0] addr;
    begin
      case (addr[11:0])
        `ATTN_REG_CONTROL, `ATTN_REG_Q_BASE_LO, `ATTN_REG_Q_BASE_HI, `ATTN_REG_K_BASE_LO,
        `ATTN_REG_K_BASE_HI, `ATTN_REG_V_BASE_LO, `ATTN_REG_V_BASE_HI, `ATTN_REG_O_BASE_LO,
        `ATTN_REG_O_BASE_HI, `ATTN_REG_Q_STRIDE, `ATTN_REG_K_STRIDE, `ATTN_REG_V_STRIDE,
        `ATTN_REG_O_STRIDE, `ATTN_REG_SEQ_Q, `ATTN_REG_SEQ_KV, `ATTN_REG_NUM_Q_HEADS,
        `ATTN_REG_NUM_KV_HEADS, `ATTN_REG_HEAD_DIM, `ATTN_REG_TILE_Q, `ATTN_REG_TILE_K,
        `ATTN_REG_MODE, `ATTN_REG_SCORE_SCALE, `ATTN_REG_VALUE_SCALE, `ATTN_REG_OUT_SCALE,
        `ATTN_REG_MASK_CFG, `ATTN_REG_PERF_CTRL: is_writable_addr = 1'b1;
        default: is_writable_addr = 1'b0;
      endcase
    end
  endfunction

  // Combinational read mux includes live status/performance counters.
  function [31:0] read_reg_value;
    input [ADDR_W-1:0] addr;
    begin
      case (addr[11:0])
        `ATTN_REG_CONTROL: read_reg_value = {24'd0, prog_decode_en_q, prog_prefill_en_q, prog_causal_en_q, prog_mode_sel_q, 4'd0};
        `ATTN_REG_STATUS: read_reg_value = {25'd0, writeback_active_i, compute_active_i, load_active_i, idle_i,
                                            (error_i | (sticky_error_q != `ATTN_ERR_NONE)), done_i, busy_i};
        `ATTN_REG_ERROR_CODE: read_reg_value = {28'd0, sticky_error_q};
        `ATTN_REG_VERSION: read_reg_value = 32'h0002_0000;
        `ATTN_REG_Q_BASE_LO: read_reg_value = prog_q_base_q[31:0];
        `ATTN_REG_Q_BASE_HI: read_reg_value = prog_q_base_q[63:32];
        `ATTN_REG_K_BASE_LO: read_reg_value = prog_k_base_q[31:0];
        `ATTN_REG_K_BASE_HI: read_reg_value = prog_k_base_q[63:32];
        `ATTN_REG_V_BASE_LO: read_reg_value = prog_v_base_q[31:0];
        `ATTN_REG_V_BASE_HI: read_reg_value = prog_v_base_q[63:32];
        `ATTN_REG_O_BASE_LO: read_reg_value = prog_o_base_q[31:0];
        `ATTN_REG_O_BASE_HI: read_reg_value = prog_o_base_q[63:32];
        `ATTN_REG_Q_STRIDE: read_reg_value = prog_q_stride_q;
        `ATTN_REG_K_STRIDE: read_reg_value = prog_k_stride_q;
        `ATTN_REG_V_STRIDE: read_reg_value = prog_v_stride_q;
        `ATTN_REG_O_STRIDE: read_reg_value = prog_o_stride_q;
        `ATTN_REG_SEQ_Q: read_reg_value = {16'd0, prog_seq_q_q};
        `ATTN_REG_SEQ_KV: read_reg_value = {16'd0, prog_seq_kv_q};
        `ATTN_REG_NUM_Q_HEADS: read_reg_value = {24'd0, prog_num_q_heads_q};
        `ATTN_REG_NUM_KV_HEADS: read_reg_value = {24'd0, prog_num_kv_heads_q};
        `ATTN_REG_HEAD_DIM: read_reg_value = {24'd0, prog_head_dim_q};
        `ATTN_REG_TILE_Q: read_reg_value = {24'd0, prog_tile_q_q};
        `ATTN_REG_TILE_K: read_reg_value = {24'd0, prog_tile_k_q};
        `ATTN_REG_MODE: read_reg_value = {28'd0, prog_decode_en_q, prog_prefill_en_q, prog_causal_en_q, prog_mode_sel_q};
        `ATTN_REG_SCORE_SCALE: read_reg_value = prog_score_scale_q;
        `ATTN_REG_VALUE_SCALE: read_reg_value = prog_value_scale_q;
        `ATTN_REG_OUT_SCALE: read_reg_value = prog_out_scale_q;
        `ATTN_REG_MASK_CFG: read_reg_value = prog_mask_cfg_q;
        `ATTN_REG_PERF_CTRL: read_reg_value = prog_perf_ctrl_q;
        `ATTN_REG_PERF_CYCLES_LO: read_reg_value = perf_cycles_i[31:0];
        `ATTN_REG_PERF_CYCLES_HI: read_reg_value = perf_cycles_i[63:32];
        `ATTN_REG_PERF_STALL_LO: read_reg_value = perf_stall_i[31:0];
        `ATTN_REG_PERF_STALL_HI: read_reg_value = perf_stall_i[63:32];
        `ATTN_REG_PERF_MAC_LO: read_reg_value = perf_mac_i[31:0];
        `ATTN_REG_PERF_MAC_HI: read_reg_value = perf_mac_i[63:32];
        `ATTN_REG_PERF_TILES: read_reg_value = perf_tiles_i;
        default: read_reg_value = 32'd0;
      endcase
    end
  endfunction

  // Serialize AXI responses, update shadow registers, and create one-cycle command
  // pulses. Only CONTROL/PERF writes are accepted while a job is busy.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_axi_bresp <= 2'b00;
      s_axi_bvalid <= 1'b0;
      s_axi_rdata <= 32'd0;
      s_axi_rresp <= 2'b00;
      s_axi_rvalid <= 1'b0;
      cfg_start_pulse_o <= 1'b0;
      cfg_soft_reset_pulse_o <= 1'b0;
      cfg_clear_done_pulse_o <= 1'b0;
      cfg_clear_error_pulse_o <= 1'b0;
      prog_mode_sel_q <= `ATTN_MODESEL_MHA;
      prog_causal_en_q <= 1'b0;
      prog_prefill_en_q <= 1'b1;
      prog_decode_en_q <= 1'b0;
      prog_q_base_q <= 64'd0; prog_k_base_q <= 64'd0; prog_v_base_q <= 64'd0; prog_o_base_q <= 64'd0;
      prog_q_stride_q <= 32'd0; prog_k_stride_q <= 32'd0; prog_v_stride_q <= 32'd0; prog_o_stride_q <= 32'd0;
      prog_seq_q_q <= 16'd0; prog_seq_kv_q <= 16'd0;
      prog_num_q_heads_q <= `ATTN_DEFAULT_NUM_HEADS; prog_num_kv_heads_q <= `ATTN_DEFAULT_NUM_HEADS;
      prog_head_dim_q <= `ATTN_DEFAULT_HEAD_DIM; prog_tile_q_q <= `ATTN_DEFAULT_TILE_Q; prog_tile_k_q <= `ATTN_DEFAULT_TILE_K;
      prog_score_scale_q <= 32'd0; prog_value_scale_q <= 32'd0; prog_out_scale_q <= 32'd0;
      prog_mask_cfg_q <= 32'd0; prog_perf_ctrl_q <= 32'd0;
      cfg_mode_sel_o <= `ATTN_MODESEL_MHA; cfg_causal_en_o <= 1'b0; cfg_prefill_en_o <= 1'b1; cfg_decode_en_o <= 1'b0;
      cfg_q_base_o <= 64'd0; cfg_k_base_o <= 64'd0; cfg_v_base_o <= 64'd0; cfg_o_base_o <= 64'd0;
      cfg_q_stride_o <= 32'd0; cfg_k_stride_o <= 32'd0; cfg_v_stride_o <= 32'd0; cfg_o_stride_o <= 32'd0;
      cfg_seq_q_o <= 16'd0; cfg_seq_kv_o <= 16'd0;
      cfg_num_q_heads_o <= `ATTN_DEFAULT_NUM_HEADS; cfg_num_kv_heads_o <= `ATTN_DEFAULT_NUM_HEADS;
      cfg_head_dim_o <= `ATTN_DEFAULT_HEAD_DIM; cfg_tile_q_o <= `ATTN_DEFAULT_TILE_Q; cfg_tile_k_o <= `ATTN_DEFAULT_TILE_K;
      cfg_score_scale_o <= 32'd0; cfg_value_scale_o <= 32'd0; cfg_out_scale_o <= 32'd0;
      cfg_mask_cfg_o <= 32'd0; cfg_perf_ctrl_o <= 32'd0;
      sticky_error_q <= `ATTN_ERR_NONE;
    end else begin
      cfg_start_pulse_o <= 1'b0;
      cfg_soft_reset_pulse_o <= 1'b0;
      cfg_clear_done_pulse_o <= 1'b0;
      cfg_clear_error_pulse_o <= 1'b0;
      if (error_i && sticky_error_q == `ATTN_ERR_NONE)
        sticky_error_q <= (error_code_i == `ATTN_ERR_NONE) ? `ATTN_ERR_FATAL : error_code_i;

      if (wr_fire_w) begin
        s_axi_bresp <= 2'b00;
        if (!is_known_addr(wr_addr_w) || !is_writable_addr(wr_addr_w)) begin
          s_axi_bresp <= 2'b10;
          sticky_error_q <= `ATTN_ERR_BUS;
        end else if (busy_i && wr_addr_w[11:0] != `ATTN_REG_CONTROL && wr_addr_w[11:0] != `ATTN_REG_PERF_CTRL) begin
          s_axi_bresp <= 2'b10;
          sticky_error_q <= `ATTN_ERR_BAD_CFG;
        end else begin
          case (wr_addr_w[11:0])
            `ATTN_REG_CONTROL: begin
              if (wr_strb_w[0]) begin
                prog_mode_sel_q <= wr_data_w[`ATTN_CTRL_MODE_SEL_BIT];
                prog_causal_en_q <= wr_data_w[`ATTN_CTRL_CAUSAL_EN_BIT];
                prog_prefill_en_q <= wr_data_w[`ATTN_CTRL_PREFILL_EN_BIT];
                prog_decode_en_q <= wr_data_w[`ATTN_CTRL_DECODE_EN_BIT];
                cfg_soft_reset_pulse_o <= wr_data_w[`ATTN_CTRL_SOFT_RESET_BIT];
                cfg_clear_done_pulse_o <= wr_data_w[`ATTN_CTRL_CLEAR_DONE_BIT];
                cfg_clear_error_pulse_o <= wr_data_w[`ATTN_CTRL_CLEAR_ERROR_BIT];
                if (wr_data_w[`ATTN_CTRL_CLEAR_ERROR_BIT] || wr_data_w[`ATTN_CTRL_SOFT_RESET_BIT])
                  sticky_error_q <= `ATTN_ERR_NONE;
                // A successful START copies every shadow field in one cycle.
                if (wr_data_w[`ATTN_CTRL_START_BIT]) begin
                  if (busy_i || !start_cfg_valid_w) begin
                    s_axi_bresp <= 2'b10;
                    sticky_error_q <= start_alignment_valid_w ? `ATTN_ERR_BAD_CFG : `ATTN_ERR_ALIGNMENT;
                  end else begin
                    cfg_start_pulse_o <= 1'b1;
                    cfg_mode_sel_o <= start_mode_sel_w;
                    cfg_causal_en_o <= start_causal_en_w;
                    cfg_prefill_en_o <= start_prefill_en_w;
                    cfg_decode_en_o <= start_decode_en_w;
                    cfg_q_base_o <= prog_q_base_q; cfg_k_base_o <= prog_k_base_q;
                    cfg_v_base_o <= prog_v_base_q; cfg_o_base_o <= prog_o_base_q;
                    cfg_q_stride_o <= prog_q_stride_q; cfg_k_stride_o <= prog_k_stride_q;
                    cfg_v_stride_o <= prog_v_stride_q; cfg_o_stride_o <= prog_o_stride_q;
                    cfg_seq_q_o <= prog_seq_q_q; cfg_seq_kv_o <= prog_seq_kv_q;
                    cfg_num_q_heads_o <= prog_num_q_heads_q; cfg_num_kv_heads_o <= prog_num_kv_heads_q;
                    cfg_head_dim_o <= prog_head_dim_q; cfg_tile_q_o <= prog_tile_q_q; cfg_tile_k_o <= prog_tile_k_q;
                    cfg_score_scale_o <= prog_score_scale_q; cfg_value_scale_o <= prog_value_scale_q;
                    cfg_out_scale_o <= prog_out_scale_q; cfg_mask_cfg_o <= prog_mask_cfg_q;
                    cfg_perf_ctrl_o <= prog_perf_ctrl_q;
                  end
                end
              end
            end
            `ATTN_REG_Q_BASE_LO: prog_q_base_q[31:0] <= merge_wstrb(prog_q_base_q[31:0], wr_data_w, wr_strb_w);
            `ATTN_REG_Q_BASE_HI: prog_q_base_q[63:32] <= merge_wstrb(prog_q_base_q[63:32], wr_data_w, wr_strb_w);
            `ATTN_REG_K_BASE_LO: prog_k_base_q[31:0] <= merge_wstrb(prog_k_base_q[31:0], wr_data_w, wr_strb_w);
            `ATTN_REG_K_BASE_HI: prog_k_base_q[63:32] <= merge_wstrb(prog_k_base_q[63:32], wr_data_w, wr_strb_w);
            `ATTN_REG_V_BASE_LO: prog_v_base_q[31:0] <= merge_wstrb(prog_v_base_q[31:0], wr_data_w, wr_strb_w);
            `ATTN_REG_V_BASE_HI: prog_v_base_q[63:32] <= merge_wstrb(prog_v_base_q[63:32], wr_data_w, wr_strb_w);
            `ATTN_REG_O_BASE_LO: prog_o_base_q[31:0] <= merge_wstrb(prog_o_base_q[31:0], wr_data_w, wr_strb_w);
            `ATTN_REG_O_BASE_HI: prog_o_base_q[63:32] <= merge_wstrb(prog_o_base_q[63:32], wr_data_w, wr_strb_w);
            `ATTN_REG_Q_STRIDE: prog_q_stride_q <= merge_wstrb(prog_q_stride_q, wr_data_w, wr_strb_w);
            `ATTN_REG_K_STRIDE: prog_k_stride_q <= merge_wstrb(prog_k_stride_q, wr_data_w, wr_strb_w);
            `ATTN_REG_V_STRIDE: prog_v_stride_q <= merge_wstrb(prog_v_stride_q, wr_data_w, wr_strb_w);
            `ATTN_REG_O_STRIDE: prog_o_stride_q <= merge_wstrb(prog_o_stride_q, wr_data_w, wr_strb_w);
            `ATTN_REG_SEQ_Q: prog_seq_q_q <= merge_wstrb16(prog_seq_q_q, wr_data_w, wr_strb_w);
            `ATTN_REG_SEQ_KV: prog_seq_kv_q <= merge_wstrb16(prog_seq_kv_q, wr_data_w, wr_strb_w);
            `ATTN_REG_NUM_Q_HEADS: prog_num_q_heads_q <= merge_wstrb8(prog_num_q_heads_q, wr_data_w, wr_strb_w);
            `ATTN_REG_NUM_KV_HEADS: prog_num_kv_heads_q <= merge_wstrb8(prog_num_kv_heads_q, wr_data_w, wr_strb_w);
            `ATTN_REG_HEAD_DIM: prog_head_dim_q <= merge_wstrb8(prog_head_dim_q, wr_data_w, wr_strb_w);
            `ATTN_REG_TILE_Q: prog_tile_q_q <= merge_wstrb8(prog_tile_q_q, wr_data_w, wr_strb_w);
            `ATTN_REG_TILE_K: prog_tile_k_q <= merge_wstrb8(prog_tile_k_q, wr_data_w, wr_strb_w);
            `ATTN_REG_MODE: begin
              if (wr_strb_w[0]) begin
                prog_mode_sel_q <= wr_data_w[0]; prog_causal_en_q <= wr_data_w[1];
                prog_prefill_en_q <= wr_data_w[2]; prog_decode_en_q <= wr_data_w[3];
              end
            end
            `ATTN_REG_SCORE_SCALE: prog_score_scale_q <= merge_wstrb(prog_score_scale_q, wr_data_w, wr_strb_w);
            `ATTN_REG_VALUE_SCALE: prog_value_scale_q <= merge_wstrb(prog_value_scale_q, wr_data_w, wr_strb_w);
            `ATTN_REG_OUT_SCALE: prog_out_scale_q <= merge_wstrb(prog_out_scale_q, wr_data_w, wr_strb_w);
            `ATTN_REG_MASK_CFG: prog_mask_cfg_q <= merge_wstrb(prog_mask_cfg_q, wr_data_w, wr_strb_w);
            `ATTN_REG_PERF_CTRL: begin
              prog_perf_ctrl_q <= merge_wstrb(prog_perf_ctrl_q, wr_data_w, wr_strb_w);
              cfg_perf_ctrl_o <= merge_wstrb(prog_perf_ctrl_q, wr_data_w, wr_strb_w);
            end
            default: begin end
          endcase
        end
        s_axi_bvalid <= 1'b1;
      end else if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end

      if (rd_fire_w) begin
        s_axi_rdata <= read_reg_value(rd_addr_w);
        s_axi_rresp <= is_known_addr(rd_addr_w) ? 2'b00 : 2'b10;
        if (!is_known_addr(rd_addr_w)) sticky_error_q <= `ATTN_ERR_BUS;
        s_axi_rvalid <= 1'b1;
      end else if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
      end
    end
  end

endmodule
