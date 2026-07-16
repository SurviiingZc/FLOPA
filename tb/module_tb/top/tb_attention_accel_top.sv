`timescale 1ns/1ps
`include "attention_defines.vh"

module tb_attention_accel_top;
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
  reg [1:0] tile_load_kind_i;
  reg tile_load_bank_i;
  reg [9:0] tile_load_addr_i;
  reg tile_load_half_i;
  reg [127:0] tile_load_data_i;
  reg tile_load_valid_i;
  wire tile_load_ready_o;
  reg [1:0] tile_commit_kind_i;
  reg tile_commit_bank_i;
  reg tile_commit_valid_i;
  wire [31:0] m_axi_awaddr;
  wire [7:0] m_axi_awlen;
  wire [2:0] m_axi_awsize;
  wire [1:0] m_axi_awburst;
  wire m_axi_awvalid;
  reg m_axi_awready;
  wire [127:0] m_axi_wdata;
  wire [15:0] m_axi_wstrb;
  wire m_axi_wlast;
  wire m_axi_wvalid;
  reg m_axi_wready;
  reg [1:0] m_axi_bresp;
  reg m_axi_bvalid;
  wire m_axi_bready;
  wire irq_o;
  wire [3:0] debug_state_o;
  integer write_beat_count;
  integer write_burst_count;
  integer byte_idx;
  integer addr_idx;
  integer timeout_count;

  attention_accel_top dut (
    .clk(clk), .rst_n(rst_n),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .tile_load_kind_i(tile_load_kind_i), .tile_load_bank_i(tile_load_bank_i),
    .tile_load_addr_i(tile_load_addr_i), .tile_load_half_i(tile_load_half_i),
    .tile_load_data_i(tile_load_data_i), .tile_load_valid_i(tile_load_valid_i),
    .tile_load_ready_o(tile_load_ready_o), .tile_commit_kind_i(tile_commit_kind_i),
    .tile_commit_bank_i(tile_commit_bank_i), .tile_commit_valid_i(tile_commit_valid_i),
    .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
    .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
    .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
    .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready), .m_axi_bresp(m_axi_bresp),
    .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready), .irq_o(irq_o), .debug_state_o(debug_state_o)
  );

  always #5 clk = ~clk;

  task axil_write;
    input [31:0] addr;
    input [31:0] data;
    begin
      @(negedge clk);
      awaddr = addr; wdata = data; wstrb = 4'hf; awvalid = 1'b1; wvalid = 1'b1;
      wait (awready && wready);
      @(posedge clk); #1; awvalid = 1'b0; wvalid = 1'b0;
      wait (bvalid); #1;
      if (bresp !== 2'b00) $fatal(1, "AXI-Lite write failed addr=%h resp=%b", addr, bresp);
    end
  endtask

  task load_cache_word;
    input [1:0] kind;
    input bank;
    input [9:0] addr;
    input [7:0] value;
    begin
      @(negedge clk);
      tile_load_kind_i = kind; tile_load_bank_i = bank; tile_load_addr_i = addr;
      tile_load_half_i = 1'b0; tile_load_data_i = {16{value}}; tile_load_valid_i = 1'b1;
      @(negedge clk);
      tile_load_half_i = 1'b1; tile_load_data_i = {16{value}};
      @(negedge clk);
      tile_load_valid_i = 1'b0;
    end
  endtask

  task commit_cache;
    input [1:0] kind;
    input bank;
    begin
      @(negedge clk);
      tile_commit_kind_i = kind; tile_commit_bank_i = bank; tile_commit_valid_i = 1'b1;
      @(negedge clk);
      tile_commit_valid_i = 1'b0;
    end
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_axi_bvalid <= 1'b0;
      m_axi_bresp <= 2'b00;
    end else begin
      if (m_axi_bvalid && m_axi_bready) m_axi_bvalid <= 1'b0;
      else if (m_axi_wvalid && m_axi_wready && m_axi_wlast) begin
        m_axi_bvalid <= 1'b1;
        m_axi_bresp <= 2'b00;
      end
    end
  end

  always @(posedge clk) begin
    if (rst_n && m_axi_awvalid && m_axi_awready) begin
      if (m_axi_awaddr !== write_burst_count*256 || m_axi_awlen !== 8'd15 || m_axi_awsize !== 3'd4 || m_axi_awburst !== 2'b01)
        $fatal(1, "unexpected AW transaction addr=%h len=%0d", m_axi_awaddr, m_axi_awlen);
      write_burst_count = write_burst_count + 1;
    end
    if (rst_n && m_axi_wvalid && m_axi_wready) begin
      if (m_axi_wstrb !== 16'hffff) $fatal(1, "unexpected WSTRB");
      for (byte_idx = 0; byte_idx < 16; byte_idx = byte_idx + 1)
        if (m_axi_wdata[byte_idx*8 +: 8] !== 8'd1)
          $fatal(1, "output mismatch beat=%0d byte=%0d value=%0d", write_beat_count, byte_idx,
                 m_axi_wdata[byte_idx*8 +: 8]);
      write_beat_count = write_beat_count + 1;
    end
  end

  initial begin
    clk = 0; rst_n = 0;
    awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 1;
    araddr = 0; arvalid = 0; rready = 1;
    tile_load_kind_i = 0; tile_load_bank_i = 0; tile_load_addr_i = 0;
    tile_load_half_i = 0; tile_load_data_i = 0; tile_load_valid_i = 0;
    tile_commit_kind_i = 0; tile_commit_bank_i = 0; tile_commit_valid_i = 0;
    m_axi_awready = 1; m_axi_wready = 1; m_axi_bresp = 0; m_axi_bvalid = 0;
    write_beat_count = 0; write_burst_count = 0;
    repeat (5) @(posedge clk); rst_n = 1;

    for (addr_idx = 0; addr_idx < 64; addr_idx = addr_idx + 1) begin
      load_cache_word(`ATTN_CACHE_Q, 1'b0, addr_idx[9:0], 8'd0);
      load_cache_word(`ATTN_CACHE_K, 1'b0, addr_idx[9:0], 8'd0);
    end
    for (addr_idx = 0; addr_idx < 64; addr_idx = addr_idx + 1)
      load_cache_word(`ATTN_CACHE_V, 1'b0, addr_idx[9:0], 8'd1);
    for (addr_idx = 0; addr_idx < 64; addr_idx = addr_idx + 1) begin
      load_cache_word(`ATTN_CACHE_K, 1'b1, addr_idx[9:0], 8'd0);
      load_cache_word(`ATTN_CACHE_V, 1'b1, addr_idx[9:0], 8'd1);
    end
    commit_cache(`ATTN_CACHE_Q, 1'b0);
    commit_cache(`ATTN_CACHE_K, 1'b0);
    commit_cache(`ATTN_CACHE_V, 1'b0);
    commit_cache(`ATTN_CACHE_K, 1'b1);
    commit_cache(`ATTN_CACHE_V, 1'b1);

    axil_write(`ATTN_REG_SEQ_Q, 32'd32);
    axil_write(`ATTN_REG_SEQ_KV, 32'd64);
    axil_write(`ATTN_REG_NUM_Q_HEADS, 32'd1);
    axil_write(`ATTN_REG_NUM_KV_HEADS, 32'd1);
    axil_write(`ATTN_REG_HEAD_DIM, 32'd64);
    axil_write(`ATTN_REG_TILE_Q, 32'd32);
    axil_write(`ATTN_REG_TILE_K, 32'd32);
    axil_write(`ATTN_REG_O_STRIDE, 32'd64);
    axil_write(`ATTN_REG_SCORE_SCALE, 32'h0000_0001);
    axil_write(`ATTN_REG_OUT_SCALE, 32'h000f_0001);
    axil_write(`ATTN_REG_CONTROL, 32'h0000_0041);

    timeout_count = 0;
    while (!irq_o && timeout_count < 20000) begin
      @(posedge clk);
      timeout_count = timeout_count + 1;
    end
    if (timeout_count >= 20000) $fatal(1, "top-level timeout state=%0d", debug_state_o);
    if (debug_state_o == `ATTN_STATE_ERROR) $fatal(1, "top-level entered ERROR");
    if (write_beat_count != 128) $fatal(1, "write beat count mismatch: %0d", write_beat_count);
    if (write_burst_count != 8) $fatal(1, "write burst count mismatch: %0d", write_burst_count);
    $display("[PASS] tb_attention_accel_top cycles=%0d", timeout_count);
    $finish;
  end
endmodule
