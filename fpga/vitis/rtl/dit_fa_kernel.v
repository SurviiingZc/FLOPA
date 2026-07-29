`timescale 1ns/1ps

module dit_fa_kernel (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ap_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ap_clk, ASSOCIATED_RESET ap_rst_n" *)
    input               ap_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 ap_rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ap_rst_n, POLARITY ACTIVE_LOW" *)
    input               ap_rst_n,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control AWADDR" *)
    input      [11:0]   s_axi_control_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control AWVALID" *)
    input               s_axi_control_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control AWREADY" *)
    output              s_axi_control_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control WDATA" *)
    input      [31:0]   s_axi_control_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control WSTRB" *)
    input      [3:0]    s_axi_control_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control WVALID" *)
    input               s_axi_control_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control WREADY" *)
    output              s_axi_control_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control BRESP" *)
    output     [1:0]    s_axi_control_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control BVALID" *)
    output              s_axi_control_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control BREADY" *)
    input               s_axi_control_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control ARADDR" *)
    input      [11:0]   s_axi_control_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control ARVALID" *)
    input               s_axi_control_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control ARREADY" *)
    output              s_axi_control_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control RDATA" *)
    output     [31:0]   s_axi_control_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control RRESP" *)
    output     [1:0]    s_axi_control_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control RVALID" *)
    output              s_axi_control_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control RREADY" *)
    input               s_axi_control_rready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tile TDATA" *)
    input      [127:0]  s_axis_tile_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tile TKEEP" *)
    input      [15:0]   s_axis_tile_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tile TSTRB" *)
    input      [15:0]   s_axis_tile_tstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tile TUSER" *)
    input      [3:0]    s_axis_tile_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tile TLAST" *)
    input               s_axis_tile_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tile TVALID" *)
    input               s_axis_tile_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tile TREADY" *)
    output              s_axis_tile_tready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem AWADDR" *)
    output     [63:0]   m_axi_gmem_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem AWLEN" *)
    output     [7:0]    m_axi_gmem_awlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem AWSIZE" *)
    output     [2:0]    m_axi_gmem_awsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem AWBURST" *)
    output     [1:0]    m_axi_gmem_awburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem AWLOCK" *)
    output              m_axi_gmem_awlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem AWCACHE" *)
    output     [3:0]    m_axi_gmem_awcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem AWPROT" *)
    output     [2:0]    m_axi_gmem_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem AWQOS" *)
    output     [3:0]    m_axi_gmem_awqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem AWVALID" *)
    output              m_axi_gmem_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem AWREADY" *)
    input               m_axi_gmem_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem WDATA" *)
    output     [127:0]  m_axi_gmem_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem WSTRB" *)
    output     [15:0]   m_axi_gmem_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem WLAST" *)
    output              m_axi_gmem_wlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem WVALID" *)
    output              m_axi_gmem_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem WREADY" *)
    input               m_axi_gmem_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem BRESP" *)
    input      [1:0]    m_axi_gmem_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem BVALID" *)
    input               m_axi_gmem_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem BREADY" *)
    output              m_axi_gmem_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem ARADDR" *)
    output     [63:0]   m_axi_gmem_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem ARLEN" *)
    output     [7:0]    m_axi_gmem_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem ARSIZE" *)
    output     [2:0]    m_axi_gmem_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem ARBURST" *)
    output     [1:0]    m_axi_gmem_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem ARLOCK" *)
    output              m_axi_gmem_arlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem ARCACHE" *)
    output     [3:0]    m_axi_gmem_arcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem ARPROT" *)
    output     [2:0]    m_axi_gmem_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem ARQOS" *)
    output     [3:0]    m_axi_gmem_arqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem ARVALID" *)
    output              m_axi_gmem_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem ARREADY" *)
    input               m_axi_gmem_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem RDATA" *)
    input      [127:0]  m_axi_gmem_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem RRESP" *)
    input      [1:0]    m_axi_gmem_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem RLAST" *)
    input               m_axi_gmem_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem RVALID" *)
    input               m_axi_gmem_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_gmem RREADY" *)
    output              m_axi_gmem_rready
);

    wire [11:0] attention_awaddr_w;
    wire attention_awvalid_w;
    wire attention_awready_w;
    wire [31:0] attention_wdata_w;
    wire [3:0] attention_wstrb_w;
    wire attention_wvalid_w;
    wire attention_wready_w;
    wire [1:0] attention_bresp_w;
    wire attention_bvalid_w;
    wire attention_bready_w;
    wire [11:0] attention_araddr_w;
    wire attention_arvalid_w;
    wire attention_arready_w;
    wire [31:0] attention_rdata_w;
    wire [1:0] attention_rresp_w;
    wire attention_rvalid_w;
    wire attention_rready_w;

    wire [11:0] loader_awaddr_w;
    wire loader_awvalid_w;
    wire loader_awready_w;
    wire [31:0] loader_wdata_w;
    wire [3:0] loader_wstrb_w;
    wire loader_wvalid_w;
    wire loader_wready_w;
    wire [1:0] loader_bresp_w;
    wire loader_bvalid_w;
    wire loader_bready_w;
    wire [11:0] loader_araddr_w;
    wire loader_arvalid_w;
    wire loader_arready_w;
    wire [31:0] loader_rdata_w;
    wire [1:0] loader_rresp_w;
    wire loader_rvalid_w;
    wire loader_rready_w;
    wire [31:0] output_awaddr_w;
    wire attention_irq_w;
    wire loader_irq_w;

    assign m_axi_gmem_awaddr = {32'd0, output_awaddr_w};
    assign m_axi_gmem_awlock = 1'b0;
    assign m_axi_gmem_awcache = 4'b0011;
    assign m_axi_gmem_awprot = 3'b000;
    assign m_axi_gmem_awqos = 4'b0000;
    assign m_axi_gmem_araddr = 64'd0;
    assign m_axi_gmem_arlen = 8'd0;
    assign m_axi_gmem_arsize = 3'd4;
    assign m_axi_gmem_arburst = 2'b01;
    assign m_axi_gmem_arlock = 1'b0;
    assign m_axi_gmem_arcache = 4'b0011;
    assign m_axi_gmem_arprot = 3'b000;
    assign m_axi_gmem_arqos = 4'b0000;
    assign m_axi_gmem_arvalid = 1'b0;
    assign m_axi_gmem_rready = 1'b1;

    axi_lite_splitter u_control_splitter (
        .aclk(ap_clk),
        .aresetn(ap_rst_n),
        .s_axi_awaddr(s_axi_control_awaddr),
        .s_axi_awvalid(s_axi_control_awvalid),
        .s_axi_awready(s_axi_control_awready),
        .s_axi_wdata(s_axi_control_wdata),
        .s_axi_wstrb(s_axi_control_wstrb),
        .s_axi_wvalid(s_axi_control_wvalid),
        .s_axi_wready(s_axi_control_wready),
        .s_axi_bresp(s_axi_control_bresp),
        .s_axi_bvalid(s_axi_control_bvalid),
        .s_axi_bready(s_axi_control_bready),
        .s_axi_araddr(s_axi_control_araddr),
        .s_axi_arvalid(s_axi_control_arvalid),
        .s_axi_arready(s_axi_control_arready),
        .s_axi_rdata(s_axi_control_rdata),
        .s_axi_rresp(s_axi_control_rresp),
        .s_axi_rvalid(s_axi_control_rvalid),
        .s_axi_rready(s_axi_control_rready),
        .m0_axi_awaddr(attention_awaddr_w),
        .m0_axi_awvalid(attention_awvalid_w),
        .m0_axi_awready(attention_awready_w),
        .m0_axi_wdata(attention_wdata_w),
        .m0_axi_wstrb(attention_wstrb_w),
        .m0_axi_wvalid(attention_wvalid_w),
        .m0_axi_wready(attention_wready_w),
        .m0_axi_bresp(attention_bresp_w),
        .m0_axi_bvalid(attention_bvalid_w),
        .m0_axi_bready(attention_bready_w),
        .m0_axi_araddr(attention_araddr_w),
        .m0_axi_arvalid(attention_arvalid_w),
        .m0_axi_arready(attention_arready_w),
        .m0_axi_rdata(attention_rdata_w),
        .m0_axi_rresp(attention_rresp_w),
        .m0_axi_rvalid(attention_rvalid_w),
        .m0_axi_rready(attention_rready_w),
        .m1_axi_awaddr(loader_awaddr_w),
        .m1_axi_awvalid(loader_awvalid_w),
        .m1_axi_awready(loader_awready_w),
        .m1_axi_wdata(loader_wdata_w),
        .m1_axi_wstrb(loader_wstrb_w),
        .m1_axi_wvalid(loader_wvalid_w),
        .m1_axi_wready(loader_wready_w),
        .m1_axi_bresp(loader_bresp_w),
        .m1_axi_bvalid(loader_bvalid_w),
        .m1_axi_bready(loader_bready_w),
        .m1_axi_araddr(loader_araddr_w),
        .m1_axi_arvalid(loader_arvalid_w),
        .m1_axi_arready(loader_arready_w),
        .m1_axi_rdata(loader_rdata_w),
        .m1_axi_rresp(loader_rresp_w),
        .m1_axi_rvalid(loader_rvalid_w),
        .m1_axi_rready(loader_rready_w)
    );

    attention_fpga_top u_attention (
        .aclk(ap_clk),
        .aresetn(ap_rst_n),
        .s_axi_control_awaddr(attention_awaddr_w),
        .s_axi_control_awvalid(attention_awvalid_w),
        .s_axi_control_awready(attention_awready_w),
        .s_axi_control_wdata(attention_wdata_w),
        .s_axi_control_wstrb(attention_wstrb_w),
        .s_axi_control_wvalid(attention_wvalid_w),
        .s_axi_control_wready(attention_wready_w),
        .s_axi_control_bresp(attention_bresp_w),
        .s_axi_control_bvalid(attention_bvalid_w),
        .s_axi_control_bready(attention_bready_w),
        .s_axi_control_araddr(attention_araddr_w),
        .s_axi_control_arvalid(attention_arvalid_w),
        .s_axi_control_arready(attention_arready_w),
        .s_axi_control_rdata(attention_rdata_w),
        .s_axi_control_rresp(attention_rresp_w),
        .s_axi_control_rvalid(attention_rvalid_w),
        .s_axi_control_rready(attention_rready_w),
        .s_axi_loader_awaddr(loader_awaddr_w),
        .s_axi_loader_awvalid(loader_awvalid_w),
        .s_axi_loader_awready(loader_awready_w),
        .s_axi_loader_wdata(loader_wdata_w),
        .s_axi_loader_wstrb(loader_wstrb_w),
        .s_axi_loader_wvalid(loader_wvalid_w),
        .s_axi_loader_wready(loader_wready_w),
        .s_axi_loader_bresp(loader_bresp_w),
        .s_axi_loader_bvalid(loader_bvalid_w),
        .s_axi_loader_bready(loader_bready_w),
        .s_axi_loader_araddr(loader_araddr_w),
        .s_axi_loader_arvalid(loader_arvalid_w),
        .s_axi_loader_arready(loader_arready_w),
        .s_axi_loader_rdata(loader_rdata_w),
        .s_axi_loader_rresp(loader_rresp_w),
        .s_axi_loader_rvalid(loader_rvalid_w),
        .s_axi_loader_rready(loader_rready_w),
        .s_axis_tile_tdata(s_axis_tile_tdata),
        .s_axis_tile_tkeep(s_axis_tile_tkeep & s_axis_tile_tstrb),
        .s_axis_tile_tuser(s_axis_tile_tuser),
        .s_axis_tile_tlast(s_axis_tile_tlast),
        .s_axis_tile_tvalid(s_axis_tile_tvalid),
        .s_axis_tile_tready(s_axis_tile_tready),
        .m_axi_output_awaddr(output_awaddr_w),
        .m_axi_output_awlen(m_axi_gmem_awlen),
        .m_axi_output_awsize(m_axi_gmem_awsize),
        .m_axi_output_awburst(m_axi_gmem_awburst),
        .m_axi_output_awvalid(m_axi_gmem_awvalid),
        .m_axi_output_awready(m_axi_gmem_awready),
        .m_axi_output_wdata(m_axi_gmem_wdata),
        .m_axi_output_wstrb(m_axi_gmem_wstrb),
        .m_axi_output_wlast(m_axi_gmem_wlast),
        .m_axi_output_wvalid(m_axi_gmem_wvalid),
        .m_axi_output_wready(m_axi_gmem_wready),
        .m_axi_output_bresp(m_axi_gmem_bresp),
        .m_axi_output_bvalid(m_axi_gmem_bvalid),
        .m_axi_output_bready(m_axi_gmem_bready),
        .attention_irq_o(attention_irq_w),
        .loader_irq_o(loader_irq_w)
    );

endmodule
