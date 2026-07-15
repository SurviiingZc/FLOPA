`timescale 1ns/1ps
`include "attention_defines.vh"

module accel_regfile #(
  parameter ADDR_W = `ATTN_AXI_ADDR_W
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
  reg write_bad_addr_q;
  reg read_bad_addr_q;

  axi4_slave_if #(.ADDR_W(ADDR_W)) u_axi_lite_if (
    .clk(clk),
    .rst_n(rst_n),
    .wr_block_i(s_axi_bvalid),
    .rd_block_i(s_axi_rvalid),
    .s_axi_awaddr(s_axi_awaddr),
    .s_axi_awvalid(s_axi_awvalid),
    .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata),
    .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid),
    .s_axi_wready(s_axi_wready),
    .s_axi_araddr(s_axi_araddr),
    .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready),
    .wr_fire_o(wr_fire_w),
    .rd_fire_o(rd_fire_w),
    .wr_addr_o(wr_addr_w),
    .wr_data_o(wr_data_w),
    .wr_strb_o(wr_strb_w),
    .rd_addr_o(rd_addr_w)
  );

  function is_known_addr;
    input [ADDR_W-1:0] addr;
    begin
      case (addr[11:0])
        `ATTN_REG_CONTROL,
        `ATTN_REG_STATUS,
        `ATTN_REG_ERROR_CODE,
        `ATTN_REG_VERSION,
        `ATTN_REG_Q_BASE_LO,
        `ATTN_REG_Q_BASE_HI,
        `ATTN_REG_K_BASE_LO,
        `ATTN_REG_K_BASE_HI,
        `ATTN_REG_V_BASE_LO,
        `ATTN_REG_V_BASE_HI,
        `ATTN_REG_O_BASE_LO,
        `ATTN_REG_O_BASE_HI,
        `ATTN_REG_Q_STRIDE,
        `ATTN_REG_K_STRIDE,
        `ATTN_REG_V_STRIDE,
        `ATTN_REG_O_STRIDE,
        `ATTN_REG_SEQ_Q,
        `ATTN_REG_SEQ_KV,
        `ATTN_REG_NUM_Q_HEADS,
        `ATTN_REG_NUM_KV_HEADS,
        `ATTN_REG_HEAD_DIM,
        `ATTN_REG_TILE_Q,
        `ATTN_REG_TILE_K,
        `ATTN_REG_MODE,
        `ATTN_REG_SCORE_SCALE,
        `ATTN_REG_VALUE_SCALE,
        `ATTN_REG_OUT_SCALE,
        `ATTN_REG_MASK_CFG,
        `ATTN_REG_PERF_CTRL,
        `ATTN_REG_PERF_CYCLES_LO,
        `ATTN_REG_PERF_CYCLES_HI,
        `ATTN_REG_PERF_STALL_LO,
        `ATTN_REG_PERF_STALL_HI,
        `ATTN_REG_PERF_MAC_LO,
        `ATTN_REG_PERF_MAC_HI,
        `ATTN_REG_PERF_TILES: is_known_addr = 1'b1;
        default: is_known_addr = 1'b0;
      endcase
    end
  endfunction

  function [31:0] read_reg_value;
    input [ADDR_W-1:0] addr;
    begin
      case (addr[11:0])
        `ATTN_REG_CONTROL:        read_reg_value = {24'd0, cfg_decode_en_o, cfg_prefill_en_o, cfg_causal_en_o, cfg_mode_sel_o, 4'd0};
        `ATTN_REG_STATUS:         read_reg_value = {25'd0, writeback_active_i, compute_active_i, load_active_i, idle_i, (error_i | (sticky_error_q != `ATTN_ERR_NONE)), done_i, busy_i};
        `ATTN_REG_ERROR_CODE:     read_reg_value = {28'd0, sticky_error_q};
        `ATTN_REG_VERSION:        read_reg_value = 32'h0001_0000;
        `ATTN_REG_Q_BASE_LO:      read_reg_value = cfg_q_base_o[31:0];
        `ATTN_REG_Q_BASE_HI:      read_reg_value = cfg_q_base_o[63:32];
        `ATTN_REG_K_BASE_LO:      read_reg_value = cfg_k_base_o[31:0];
        `ATTN_REG_K_BASE_HI:      read_reg_value = cfg_k_base_o[63:32];
        `ATTN_REG_V_BASE_LO:      read_reg_value = cfg_v_base_o[31:0];
        `ATTN_REG_V_BASE_HI:      read_reg_value = cfg_v_base_o[63:32];
        `ATTN_REG_O_BASE_LO:      read_reg_value = cfg_o_base_o[31:0];
        `ATTN_REG_O_BASE_HI:      read_reg_value = cfg_o_base_o[63:32];
        `ATTN_REG_Q_STRIDE:       read_reg_value = cfg_q_stride_o;
        `ATTN_REG_K_STRIDE:       read_reg_value = cfg_k_stride_o;
        `ATTN_REG_V_STRIDE:       read_reg_value = cfg_v_stride_o;
        `ATTN_REG_O_STRIDE:       read_reg_value = cfg_o_stride_o;
        `ATTN_REG_SEQ_Q:          read_reg_value = {16'd0, cfg_seq_q_o};
        `ATTN_REG_SEQ_KV:         read_reg_value = {16'd0, cfg_seq_kv_o};
        `ATTN_REG_NUM_Q_HEADS:    read_reg_value = {24'd0, cfg_num_q_heads_o};
        `ATTN_REG_NUM_KV_HEADS:   read_reg_value = {24'd0, cfg_num_kv_heads_o};
        `ATTN_REG_HEAD_DIM:       read_reg_value = {24'd0, cfg_head_dim_o};
        `ATTN_REG_TILE_Q:         read_reg_value = {24'd0, cfg_tile_q_o};
        `ATTN_REG_TILE_K:         read_reg_value = {24'd0, cfg_tile_k_o};
        `ATTN_REG_MODE:           read_reg_value = {28'd0, cfg_decode_en_o, cfg_prefill_en_o, cfg_causal_en_o, cfg_mode_sel_o};
        `ATTN_REG_SCORE_SCALE:    read_reg_value = cfg_score_scale_o;
        `ATTN_REG_VALUE_SCALE:    read_reg_value = cfg_value_scale_o;
        `ATTN_REG_OUT_SCALE:      read_reg_value = cfg_out_scale_o;
        `ATTN_REG_MASK_CFG:       read_reg_value = cfg_mask_cfg_o;
        `ATTN_REG_PERF_CTRL:      read_reg_value = cfg_perf_ctrl_o;
        `ATTN_REG_PERF_CYCLES_LO: read_reg_value = perf_cycles_i[31:0];
        `ATTN_REG_PERF_CYCLES_HI: read_reg_value = perf_cycles_i[63:32];
        `ATTN_REG_PERF_STALL_LO:  read_reg_value = perf_stall_i[31:0];
        `ATTN_REG_PERF_STALL_HI:  read_reg_value = perf_stall_i[63:32];
        `ATTN_REG_PERF_MAC_LO:    read_reg_value = perf_mac_i[31:0];
        `ATTN_REG_PERF_MAC_HI:    read_reg_value = perf_mac_i[63:32];
        `ATTN_REG_PERF_TILES:     read_reg_value = perf_tiles_i;
        default:                  read_reg_value = 32'd0;
      endcase
    end
  endfunction

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
      cfg_mode_sel_o <= `ATTN_MODESEL_MHA;
      cfg_causal_en_o <= 1'b0;
      cfg_prefill_en_o <= 1'b1;
      cfg_decode_en_o <= 1'b0;
      cfg_q_base_o <= 64'd0;
      cfg_k_base_o <= 64'd0;
      cfg_v_base_o <= 64'd0;
      cfg_o_base_o <= 64'd0;
      cfg_q_stride_o <= 32'd0;
      cfg_k_stride_o <= 32'd0;
      cfg_v_stride_o <= 32'd0;
      cfg_o_stride_o <= 32'd0;
      cfg_seq_q_o <= 16'd0;
      cfg_seq_kv_o <= 16'd0;
      cfg_num_q_heads_o <= `ATTN_DEFAULT_NUM_HEADS;
      cfg_num_kv_heads_o <= `ATTN_DEFAULT_NUM_HEADS;
      cfg_head_dim_o <= `ATTN_DEFAULT_HEAD_DIM;
      cfg_tile_q_o <= `ATTN_DEFAULT_TILE_Q;
      cfg_tile_k_o <= `ATTN_DEFAULT_TILE_K;
      cfg_score_scale_o <= 32'd0;
      cfg_value_scale_o <= 32'd0;
      cfg_out_scale_o <= 32'd0;
      cfg_mask_cfg_o <= 32'd0;
      cfg_perf_ctrl_o <= 32'd0;
      sticky_error_q <= `ATTN_ERR_NONE;
      write_bad_addr_q <= 1'b0;
      read_bad_addr_q <= 1'b0;
    end else begin
      cfg_start_pulse_o <= 1'b0;
      cfg_soft_reset_pulse_o <= 1'b0;
      cfg_clear_done_pulse_o <= 1'b0;
      cfg_clear_error_pulse_o <= 1'b0;
      write_bad_addr_q <= 1'b0;
      read_bad_addr_q <= 1'b0;

      if (error_i && sticky_error_q == `ATTN_ERR_NONE) begin
        sticky_error_q <= (error_code_i == `ATTN_ERR_NONE) ? `ATTN_ERR_FATAL : error_code_i;
      end

      if (wr_fire_w) begin
        if (!is_known_addr(wr_addr_w)) begin
          s_axi_bresp <= 2'b10;
          sticky_error_q <= `ATTN_ERR_BUS;
          write_bad_addr_q <= 1'b1;
        end else begin
          s_axi_bresp <= 2'b00;
          case (wr_addr_w[11:0])
            `ATTN_REG_CONTROL: begin
              cfg_start_pulse_o <= wr_data_w[`ATTN_CTRL_START_BIT];
              cfg_soft_reset_pulse_o <= wr_data_w[`ATTN_CTRL_SOFT_RESET_BIT];
              cfg_clear_done_pulse_o <= wr_data_w[`ATTN_CTRL_CLEAR_DONE_BIT];
              cfg_clear_error_pulse_o <= wr_data_w[`ATTN_CTRL_CLEAR_ERROR_BIT];
              cfg_mode_sel_o <= wr_data_w[`ATTN_CTRL_MODE_SEL_BIT];
              cfg_causal_en_o <= wr_data_w[`ATTN_CTRL_CAUSAL_EN_BIT];
              cfg_prefill_en_o <= wr_data_w[`ATTN_CTRL_PREFILL_EN_BIT];
              cfg_decode_en_o <= wr_data_w[`ATTN_CTRL_DECODE_EN_BIT];
              if (wr_data_w[`ATTN_CTRL_CLEAR_ERROR_BIT] || wr_data_w[`ATTN_CTRL_SOFT_RESET_BIT]) begin
                sticky_error_q <= `ATTN_ERR_NONE;
              end
            end
            `ATTN_REG_Q_BASE_LO:    cfg_q_base_o[31:0] <= wr_data_w;
            `ATTN_REG_Q_BASE_HI:    cfg_q_base_o[63:32] <= wr_data_w;
            `ATTN_REG_K_BASE_LO:    cfg_k_base_o[31:0] <= wr_data_w;
            `ATTN_REG_K_BASE_HI:    cfg_k_base_o[63:32] <= wr_data_w;
            `ATTN_REG_V_BASE_LO:    cfg_v_base_o[31:0] <= wr_data_w;
            `ATTN_REG_V_BASE_HI:    cfg_v_base_o[63:32] <= wr_data_w;
            `ATTN_REG_O_BASE_LO:    cfg_o_base_o[31:0] <= wr_data_w;
            `ATTN_REG_O_BASE_HI:    cfg_o_base_o[63:32] <= wr_data_w;
            `ATTN_REG_Q_STRIDE:     cfg_q_stride_o <= wr_data_w;
            `ATTN_REG_K_STRIDE:     cfg_k_stride_o <= wr_data_w;
            `ATTN_REG_V_STRIDE:     cfg_v_stride_o <= wr_data_w;
            `ATTN_REG_O_STRIDE:     cfg_o_stride_o <= wr_data_w;
            `ATTN_REG_SEQ_Q:        cfg_seq_q_o <= wr_data_w[15:0];
            `ATTN_REG_SEQ_KV:       cfg_seq_kv_o <= wr_data_w[15:0];
            `ATTN_REG_NUM_Q_HEADS:  cfg_num_q_heads_o <= wr_data_w[7:0];
            `ATTN_REG_NUM_KV_HEADS: cfg_num_kv_heads_o <= wr_data_w[7:0];
            `ATTN_REG_HEAD_DIM:     cfg_head_dim_o <= wr_data_w[7:0];
            `ATTN_REG_TILE_Q:       cfg_tile_q_o <= wr_data_w[7:0];
            `ATTN_REG_TILE_K:       cfg_tile_k_o <= wr_data_w[7:0];
            `ATTN_REG_MODE: begin
              cfg_mode_sel_o <= wr_data_w[0];
              cfg_causal_en_o <= wr_data_w[1];
              cfg_prefill_en_o <= wr_data_w[2];
              cfg_decode_en_o <= wr_data_w[3];
            end
            `ATTN_REG_SCORE_SCALE:  cfg_score_scale_o <= wr_data_w;
            `ATTN_REG_VALUE_SCALE:  cfg_value_scale_o <= wr_data_w;
            `ATTN_REG_OUT_SCALE:    cfg_out_scale_o <= wr_data_w;
            `ATTN_REG_MASK_CFG:     cfg_mask_cfg_o <= wr_data_w;
            `ATTN_REG_PERF_CTRL:    cfg_perf_ctrl_o <= wr_data_w;
            default: begin
            end
          endcase
        end
        s_axi_bvalid <= 1'b1;
      end else if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end

      if (rd_fire_w) begin
        s_axi_rdata <= read_reg_value(rd_addr_w);
        if (!is_known_addr(rd_addr_w)) begin
          s_axi_rresp <= 2'b10;
          sticky_error_q <= `ATTN_ERR_BUS;
          read_bad_addr_q <= 1'b1;
        end else begin
          s_axi_rresp <= 2'b00;
        end
        s_axi_rvalid <= 1'b1;
      end else if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
      end
    end
  end

endmodule
