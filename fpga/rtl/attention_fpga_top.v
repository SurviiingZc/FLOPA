`timescale 1ns/1ps
`include "attention_defines.vh"

module attention_fpga_top (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK, ASSOCIATED_RESET aresetn" *)
    input                       aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
    input                       aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL AWADDR" *)
    input      [11:0]           s_axi_control_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL AWVALID" *)
    input                       s_axi_control_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL AWREADY" *)
    output                      s_axi_control_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL WDATA" *)
    input      [31:0]           s_axi_control_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL WSTRB" *)
    input      [3:0]            s_axi_control_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL WVALID" *)
    input                       s_axi_control_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL WREADY" *)
    output                      s_axi_control_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL BRESP" *)
    output     [1:0]            s_axi_control_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL BVALID" *)
    output                      s_axi_control_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL BREADY" *)
    input                       s_axi_control_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL ARADDR" *)
    input      [11:0]           s_axi_control_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL ARVALID" *)
    input                       s_axi_control_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL ARREADY" *)
    output                      s_axi_control_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL RDATA" *)
    output     [31:0]           s_axi_control_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL RRESP" *)
    output     [1:0]            s_axi_control_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL RVALID" *)
    output                      s_axi_control_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL RREADY" *)
    input                       s_axi_control_rready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_LOADER AWADDR" *)
    input      [11:0]           s_axi_loader_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_LOADER AWVALID" *)
    input                       s_axi_loader_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_LOADER AWREADY" *)
    output                      s_axi_loader_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_LOADER WDATA" *)
    input      [31:0]           s_axi_loader_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_LOADER WSTRB" *)
    input      [3:0]            s_axi_loader_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_LOADER WVALID" *)
    input                       s_axi_loader_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_LOADER WREADY" *)
    output                      s_axi_loader_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_LOADER BRESP" *)
    output     [1:0]            s_axi_loader_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_LOADER BVALID" *)
    output                      s_axi_loader_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_LOADER BREADY" *)
    input                       s_axi_loader_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_LOADER ARADDR" *)
    input      [11:0]           s_axi_loader_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_LOADER ARVALID" *)
    input                       s_axi_loader_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_LOADER ARREADY" *)
    output                      s_axi_loader_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_LOADER RDATA" *)
    output     [31:0]           s_axi_loader_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_LOADER RRESP" *)
    output     [1:0]            s_axi_loader_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_LOADER RVALID" *)
    output                      s_axi_loader_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_LOADER RREADY" *)
    input                       s_axi_loader_rready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TILE TDATA" *)
    input      [127:0]          s_axis_tile_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TILE TKEEP" *)
    input      [15:0]           s_axis_tile_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TILE TLAST" *)
    input                       s_axis_tile_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TILE TVALID" *)
    input                       s_axis_tile_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_TILE TREADY" *)
    output                      s_axis_tile_tready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_OUTPUT AWADDR" *)
    output     [31:0]           m_axi_output_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_OUTPUT AWLEN" *)
    output     [7:0]            m_axi_output_awlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_OUTPUT AWSIZE" *)
    output     [2:0]            m_axi_output_awsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_OUTPUT AWBURST" *)
    output     [1:0]            m_axi_output_awburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_OUTPUT AWVALID" *)
    output                      m_axi_output_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_OUTPUT AWREADY" *)
    input                       m_axi_output_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_OUTPUT WDATA" *)
    output     [127:0]          m_axi_output_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_OUTPUT WSTRB" *)
    output     [15:0]           m_axi_output_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_OUTPUT WLAST" *)
    output                      m_axi_output_wlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_OUTPUT WVALID" *)
    output                      m_axi_output_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_OUTPUT WREADY" *)
    input                       m_axi_output_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_OUTPUT BRESP" *)
    input      [1:0]            m_axi_output_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_OUTPUT BVALID" *)
    input                       m_axi_output_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_OUTPUT BREADY" *)
    output                      m_axi_output_bready,

    output                      attention_irq_o,
    output                      loader_irq_o
);

    wire [1:0] tile_load_kind_w;
    wire tile_load_bank_w;
    wire [`ATTN_CACHE_ADDR_W-1:0] tile_load_addr_w;
    wire tile_load_half_w;
    wire [127:0] tile_load_data_w;
    wire tile_load_valid_w;
    wire tile_load_ready_w;
    wire [1:0] tile_commit_kind_w;
    wire tile_commit_bank_w;
    wire tile_commit_valid_w;
    wire [3:0] debug_state_w;

    axis_tile_loader #(
        .CACHE_ADDR_W(`ATTN_CACHE_ADDR_W),
        .DEFAULT_BEATS(128)
    ) u_tile_loader (
        .clk(aclk),
        .rst_n(aresetn),
        .s_axi_awaddr({20'd0, s_axi_loader_awaddr}),
        .s_axi_awvalid(s_axi_loader_awvalid),
        .s_axi_awready(s_axi_loader_awready),
        .s_axi_wdata(s_axi_loader_wdata),
        .s_axi_wstrb(s_axi_loader_wstrb),
        .s_axi_wvalid(s_axi_loader_wvalid),
        .s_axi_wready(s_axi_loader_wready),
        .s_axi_bresp(s_axi_loader_bresp),
        .s_axi_bvalid(s_axi_loader_bvalid),
        .s_axi_bready(s_axi_loader_bready),
        .s_axi_araddr({20'd0, s_axi_loader_araddr}),
        .s_axi_arvalid(s_axi_loader_arvalid),
        .s_axi_arready(s_axi_loader_arready),
        .s_axi_rdata(s_axi_loader_rdata),
        .s_axi_rresp(s_axi_loader_rresp),
        .s_axi_rvalid(s_axi_loader_rvalid),
        .s_axi_rready(s_axi_loader_rready),
        .s_axis_tdata(s_axis_tile_tdata),
        .s_axis_tkeep(s_axis_tile_tkeep),
        .s_axis_tlast(s_axis_tile_tlast),
        .s_axis_tvalid(s_axis_tile_tvalid),
        .s_axis_tready(s_axis_tile_tready),
        .tile_load_kind_o(tile_load_kind_w),
        .tile_load_bank_o(tile_load_bank_w),
        .tile_load_addr_o(tile_load_addr_w),
        .tile_load_half_o(tile_load_half_w),
        .tile_load_data_o(tile_load_data_w),
        .tile_load_valid_o(tile_load_valid_w),
        .tile_load_ready_i(tile_load_ready_w),
        .tile_commit_kind_o(tile_commit_kind_w),
        .tile_commit_bank_o(tile_commit_bank_w),
        .tile_commit_valid_o(tile_commit_valid_w),
        .irq_o(loader_irq_o)
    );

    attention_accel_top u_attention (
        .clk(aclk),
        .rst_n(aresetn),
        .s_axi_awaddr({20'd0, s_axi_control_awaddr}),
        .s_axi_awvalid(s_axi_control_awvalid),
        .s_axi_awready(s_axi_control_awready),
        .s_axi_wdata(s_axi_control_wdata),
        .s_axi_wstrb(s_axi_control_wstrb),
        .s_axi_wvalid(s_axi_control_wvalid),
        .s_axi_wready(s_axi_control_wready),
        .s_axi_bresp(s_axi_control_bresp),
        .s_axi_bvalid(s_axi_control_bvalid),
        .s_axi_bready(s_axi_control_bready),
        .s_axi_araddr({20'd0, s_axi_control_araddr}),
        .s_axi_arvalid(s_axi_control_arvalid),
        .s_axi_arready(s_axi_control_arready),
        .s_axi_rdata(s_axi_control_rdata),
        .s_axi_rresp(s_axi_control_rresp),
        .s_axi_rvalid(s_axi_control_rvalid),
        .s_axi_rready(s_axi_control_rready),
        .tile_load_kind_i(tile_load_kind_w),
        .tile_load_bank_i(tile_load_bank_w),
        .tile_load_addr_i(tile_load_addr_w),
        .tile_load_half_i(tile_load_half_w),
        .tile_load_data_i(tile_load_data_w),
        .tile_load_valid_i(tile_load_valid_w),
        .tile_load_ready_o(tile_load_ready_w),
        .tile_commit_kind_i(tile_commit_kind_w),
        .tile_commit_bank_i(tile_commit_bank_w),
        .tile_commit_valid_i(tile_commit_valid_w),
        .m_axi_awaddr(m_axi_output_awaddr),
        .m_axi_awlen(m_axi_output_awlen),
        .m_axi_awsize(m_axi_output_awsize),
        .m_axi_awburst(m_axi_output_awburst),
        .m_axi_awvalid(m_axi_output_awvalid),
        .m_axi_awready(m_axi_output_awready),
        .m_axi_wdata(m_axi_output_wdata),
        .m_axi_wstrb(m_axi_output_wstrb),
        .m_axi_wlast(m_axi_output_wlast),
        .m_axi_wvalid(m_axi_output_wvalid),
        .m_axi_wready(m_axi_output_wready),
        .m_axi_bresp(m_axi_output_bresp),
        .m_axi_bvalid(m_axi_output_bvalid),
        .m_axi_bready(m_axi_output_bready),
        .irq_o(attention_irq_o),
        .debug_state_o(debug_state_w)
    );

endmodule
