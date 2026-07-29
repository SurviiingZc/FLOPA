`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "attention_defines.vh"

module tb_accel_regfile;
  `TB_FSDB_DUMP("tb_accel_regfile.fsdb", tb_accel_regfile)
  reg clk;
  reg rst_n;
  reg [31:0] awaddr;
  reg awvalid;
  wire awready;
  reg [31:0] wdata;
  reg [3:0] wstrb;
  reg wvalid;
  wire wready;
  wire [1:0] bresp;
  wire bvalid;
  reg bready;
  reg [31:0] araddr;
  reg arvalid;
  wire arready;
  wire [31:0] rdata;
  wire [1:0] rresp;
  wire rvalid;
  reg rready;

  reg busy_i;
  reg done_i;
  reg error_i;
  reg [3:0] error_code_i;
  reg idle_i;
  reg load_active_i;
  reg compute_active_i;
  reg writeback_active_i;
  reg [63:0] perf_cycles_i;
  reg [63:0] perf_stall_i;
  reg [63:0] perf_mac_i;
  reg [31:0] perf_tiles_i;

  wire start_seen;
  wire soft_reset_seen;
  wire clear_done_seen;
  wire clear_error_seen;
  reg start_seen_q;
  reg soft_reset_seen_q;
  reg clear_done_seen_q;
  reg clear_error_seen_q;

  wire cfg_mode_sel_o;
  wire cfg_causal_en_o;
  wire cfg_prefill_en_o;
  wire cfg_decode_en_o;
  wire [63:0] cfg_o_base_o;
  wire [31:0] cfg_o_stride_o;
  wire [15:0] cfg_seq_q_o;
  wire [15:0] cfg_seq_kv_o;
  wire [7:0] cfg_num_q_heads_o;
  wire [7:0] cfg_num_kv_heads_o;
  wire [7:0] cfg_head_dim_o;
  wire [7:0] cfg_tile_q_o;
  wire [7:0] cfg_tile_k_o;
  wire [31:0] cfg_score_scale_o;
  wire [31:0] cfg_out_scale_o;
  wire [31:0] cfg_perf_ctrl_o;

  accel_regfile dut (
    .clk(clk), .rst_n(rst_n),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .cfg_start_pulse_o(start_seen), .cfg_soft_reset_pulse_o(soft_reset_seen),
    .cfg_clear_done_pulse_o(clear_done_seen), .cfg_clear_error_pulse_o(clear_error_seen),
    .cfg_mode_sel_o(cfg_mode_sel_o), .cfg_causal_en_o(cfg_causal_en_o),
    .cfg_prefill_en_o(cfg_prefill_en_o), .cfg_decode_en_o(cfg_decode_en_o),
    .cfg_o_base_o(cfg_o_base_o), .cfg_o_stride_o(cfg_o_stride_o),
    .cfg_seq_q_o(cfg_seq_q_o), .cfg_seq_kv_o(cfg_seq_kv_o), .cfg_num_q_heads_o(cfg_num_q_heads_o),
    .cfg_num_kv_heads_o(cfg_num_kv_heads_o), .cfg_head_dim_o(cfg_head_dim_o), .cfg_tile_q_o(cfg_tile_q_o), .cfg_tile_k_o(cfg_tile_k_o),
    .cfg_score_scale_o(cfg_score_scale_o), .cfg_out_scale_o(cfg_out_scale_o),
    .cfg_perf_ctrl_o(cfg_perf_ctrl_o),
    .busy_i(busy_i), .done_i(done_i), .error_i(error_i), .error_code_i(error_code_i),
    .idle_i(idle_i), .load_active_i(load_active_i), .compute_active_i(compute_active_i), .writeback_active_i(writeback_active_i),
    .perf_cycles_i(perf_cycles_i), .perf_stall_i(perf_stall_i), .perf_mac_i(perf_mac_i), .perf_tiles_i(perf_tiles_i)
  );

  always #5 clk = ~clk;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      start_seen_q <= 1'b0;
      soft_reset_seen_q <= 1'b0;
      clear_done_seen_q <= 1'b0;
      clear_error_seen_q <= 1'b0;
    end else begin
      if (start_seen) start_seen_q <= 1'b1;
      if (soft_reset_seen) soft_reset_seen_q <= 1'b1;
      if (clear_done_seen) clear_done_seen_q <= 1'b1;
      if (clear_error_seen) clear_error_seen_q <= 1'b1;
    end
  end

  task automatic axil_write;
    input [31:0] addr;
    input [31:0] data;
    begin
      @(negedge clk);
      awaddr = addr;
      wdata = data;
      wstrb = 4'hf;
      awvalid = 1'b1;
      wvalid = 1'b1;
      wait (awready && wready);
      @(posedge clk);
      #1;
      awvalid = 1'b0;
      wvalid = 1'b0;
      wait (bvalid);
      #1;
      if (bresp !== 2'b00) $fatal(1, "write response error addr=%h data=%h bresp=%b", addr, data, bresp);
    end
  endtask

  task automatic axil_read;
    input [31:0] addr;
    output [31:0] data;
    begin
      @(negedge clk);
      araddr = addr;
      arvalid = 1'b1;
      wait (arready);
      @(posedge clk);
      #1;
      arvalid = 1'b0;
      wait (rvalid);
      #1;
      data = rdata;
      if (rresp !== 2'b00) $fatal(1, "read response error addr=%h rresp=%b", addr, rresp);
    end
  endtask

  reg [31:0] rd_data;

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    awaddr = 32'd0;
    awvalid = 1'b0;
    wdata = 32'd0;
    wstrb = 4'd0;
    wvalid = 1'b0;
    bready = 1'b1;
    araddr = 32'd0;
    arvalid = 1'b0;
    rready = 1'b1;
    busy_i = 1'b0;
    done_i = 1'b0;
    error_i = 1'b0;
    error_code_i = `ATTN_ERR_NONE;
    idle_i = 1'b1;
    load_active_i = 1'b0;
    compute_active_i = 1'b0;
    writeback_active_i = 1'b0;
    perf_cycles_i = 64'd0;
    perf_stall_i = 64'd0;
    perf_mac_i = 64'd0;
    perf_tiles_i = 32'd0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    axil_read(`ATTN_REG_VERSION, rd_data);
    if (rd_data != 32'h0002_0000) $fatal(1, "version mismatch: %h", rd_data);

    axil_write(`ATTN_REG_Q_BASE_LO, 32'h1111_2220);
    axil_write(`ATTN_REG_Q_BASE_HI, 32'h3333_4444);
    axil_write(`ATTN_REG_K_BASE_LO, 32'h5555_6660);
    axil_write(`ATTN_REG_K_BASE_HI, 32'h7777_8888);
    axil_write(`ATTN_REG_SEQ_Q, 32'd576);
    axil_write(`ATTN_REG_SEQ_KV, 32'd576);
    axil_write(`ATTN_REG_NUM_Q_HEADS, 32'd9);
    axil_write(`ATTN_REG_NUM_KV_HEADS, 32'd9);
    axil_write(`ATTN_REG_HEAD_DIM, 32'd64);
    axil_write(`ATTN_REG_TILE_Q, 32'd32);
    axil_write(`ATTN_REG_TILE_K, 32'd32);
    axil_write(`ATTN_REG_SCORE_SCALE, 32'h0000_1234);
    axil_write(`ATTN_REG_VALUE_SCALE, 32'h0000_5678);
    axil_write(`ATTN_REG_OUT_SCALE, 32'h0000_9abc);
    axil_write(`ATTN_REG_MASK_CFG, 32'h0000_0001);
    axil_write(`ATTN_REG_MODE, 32'h0000_000b);

    axil_read(`ATTN_REG_Q_BASE_LO, rd_data); if (rd_data != 32'd0) $fatal(1, "reserved Q_BASE_LO must read zero");
    axil_read(`ATTN_REG_Q_BASE_HI, rd_data); if (rd_data != 32'd0) $fatal(1, "reserved Q_BASE_HI must read zero");
    axil_read(`ATTN_REG_VALUE_SCALE, rd_data); if (rd_data != 32'd0) $fatal(1, "reserved VALUE_SCALE must read zero");
    axil_read(`ATTN_REG_MASK_CFG, rd_data); if (rd_data != 32'd0) $fatal(1, "reserved MASK_CFG must read zero");
    axil_read(`ATTN_REG_SEQ_Q, rd_data); if (rd_data != 32'd576) $fatal(1, "SEQ_Q mismatch");
    axil_read(`ATTN_REG_MODE, rd_data); if (rd_data[3:0] != 4'b1011) $fatal(1, "MODE mismatch: %h", rd_data);

    axil_write(`ATTN_REG_CONTROL, 32'h0000_004f);
    @(posedge clk);
    #1;
    if (!start_seen_q) $fatal(1, "start pulse missing");
    if (!soft_reset_seen_q) $fatal(1, "soft reset pulse missing");
    if (!clear_done_seen_q) $fatal(1, "clear done pulse missing");
    if (!clear_error_seen_q) $fatal(1, "clear error pulse missing");

    busy_i = 1'b1;
    idle_i = 1'b0;
    load_active_i = 1'b1;
    compute_active_i = 1'b0;
    writeback_active_i = 1'b0;
    done_i = 1'b0;
    error_i = 1'b1;
    error_code_i = `ATTN_ERR_BAD_CFG;
    perf_cycles_i = 64'd123;
    perf_stall_i = 64'd7;
    perf_mac_i = 64'd456;
    perf_tiles_i = 32'd3;

    axil_read(`ATTN_REG_STATUS, rd_data);
    if (!rd_data[0]) $fatal(1, "STATUS busy missing");
    if (!rd_data[4]) $fatal(1, "STATUS load_active missing");
    if (!rd_data[2]) $fatal(1, "STATUS error missing");
    axil_read(`ATTN_REG_ERROR_CODE, rd_data);
    if (rd_data[3:0] != `ATTN_ERR_BAD_CFG) $fatal(1, "ERROR_CODE mismatch: %h", rd_data);
    axil_read(`ATTN_REG_PERF_CYCLES_LO, rd_data); if (rd_data != 32'd123) $fatal(1, "perf cycles lo mismatch");
    axil_read(`ATTN_REG_PERF_STALL_LO, rd_data); if (rd_data != 32'd7) $fatal(1, "perf stall lo mismatch");
    axil_read(`ATTN_REG_PERF_MAC_LO, rd_data); if (rd_data != 32'd456) $fatal(1, "perf mac lo mismatch");
    axil_read(`ATTN_REG_PERF_TILES, rd_data); if (rd_data != 32'd3) $fatal(1, "perf tiles mismatch");

    error_i = 1'b0;
    error_code_i = `ATTN_ERR_NONE;
    axil_write(`ATTN_REG_CONTROL, 32'h0000_0008);
    axil_read(`ATTN_REG_ERROR_CODE, rd_data);
    if (rd_data != 32'd0) $fatal(1, "clear error did not clear sticky code");

    $display("[PASS] tb_accel_regfile");
    $finish;
  end
endmodule
