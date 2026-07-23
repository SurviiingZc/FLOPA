`timescale 1ns/1ps

`include "attention_defines.vh"

module tb_top;
  import uvm_pkg::*;
  import attention_uvm_pkg::*;

  logic clk;
  logic rst_n;

  fa_axil_if axil_if(.clk(clk), .rst_n(rst_n));
  fa_tile_loader_if #(.ADDR_W(`ATTN_CACHE_ADDR_W)) tile_if(.clk(clk), .rst_n(rst_n));
  fa_axi_write_if write_if(.clk(clk), .rst_n(rst_n));
  fa_status_if status_if(.clk(clk), .rst_n(rst_n));

  attention_accel_top dut (
    .clk(clk),
    .rst_n(rst_n),
    .s_axi_awaddr(axil_if.awaddr),
    .s_axi_awvalid(axil_if.awvalid),
    .s_axi_awready(axil_if.awready),
    .s_axi_wdata(axil_if.wdata),
    .s_axi_wstrb(axil_if.wstrb),
    .s_axi_wvalid(axil_if.wvalid),
    .s_axi_wready(axil_if.wready),
    .s_axi_bresp(axil_if.bresp),
    .s_axi_bvalid(axil_if.bvalid),
    .s_axi_bready(axil_if.bready),
    .s_axi_araddr(axil_if.araddr),
    .s_axi_arvalid(axil_if.arvalid),
    .s_axi_arready(axil_if.arready),
    .s_axi_rdata(axil_if.rdata),
    .s_axi_rresp(axil_if.rresp),
    .s_axi_rvalid(axil_if.rvalid),
    .s_axi_rready(axil_if.rready),
    .tile_load_kind_i(tile_if.load_kind),
    .tile_load_bank_i(tile_if.load_bank),
    .tile_load_addr_i(tile_if.load_addr),
    .tile_load_half_i(tile_if.load_half),
    .tile_load_data_i(tile_if.load_data),
    .tile_load_valid_i(tile_if.load_valid),
    .tile_load_ready_o(tile_if.load_ready),
    .tile_commit_kind_i(tile_if.commit_kind),
    .tile_commit_bank_i(tile_if.commit_bank),
    .tile_commit_valid_i(tile_if.commit_valid),
    .m_axi_awaddr(write_if.awaddr),
    .m_axi_awlen(write_if.awlen),
    .m_axi_awsize(write_if.awsize),
    .m_axi_awburst(write_if.awburst),
    .m_axi_awvalid(write_if.awvalid),
    .m_axi_awready(write_if.awready),
    .m_axi_wdata(write_if.wdata),
    .m_axi_wstrb(write_if.wstrb),
    .m_axi_wlast(write_if.wlast),
    .m_axi_wvalid(write_if.wvalid),
    .m_axi_wready(write_if.wready),
    .m_axi_bresp(write_if.bresp),
    .m_axi_bvalid(write_if.bvalid),
    .m_axi_bready(write_if.bready),
    .irq_o(status_if.irq),
    .debug_state_o(status_if.debug_state)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  end

  initial begin
    uvm_config_db#(virtual fa_axil_if)::set(null, "uvm_test_top.env.axil_agent.*", "vif", axil_if);
    uvm_config_db#(virtual fa_tile_loader_if)::set(null, "uvm_test_top.env.tile_agent.*", "vif", tile_if);
    uvm_config_db#(virtual fa_axi_write_if)::set(null, "uvm_test_top.env.write_agent.*", "vif", write_if);
    uvm_config_db#(virtual fa_status_if)::set(null, "uvm_test_top.env.phase_cov", "vif", status_if);
    run_test();
  end
endmodule
