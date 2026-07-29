`timescale 1ns/1ps

module axi_lite_splitter (
    input               aclk,
    input               aresetn,

    input      [11:0]   s_axi_awaddr,
    input               s_axi_awvalid,
    output              s_axi_awready,
    input      [31:0]   s_axi_wdata,
    input      [3:0]    s_axi_wstrb,
    input               s_axi_wvalid,
    output              s_axi_wready,
    output     [1:0]    s_axi_bresp,
    output              s_axi_bvalid,
    input               s_axi_bready,
    input      [11:0]   s_axi_araddr,
    input               s_axi_arvalid,
    output              s_axi_arready,
    output     [31:0]   s_axi_rdata,
    output     [1:0]    s_axi_rresp,
    output              s_axi_rvalid,
    input               s_axi_rready,

    output     [11:0]   m0_axi_awaddr,
    output              m0_axi_awvalid,
    input               m0_axi_awready,
    output     [31:0]   m0_axi_wdata,
    output     [3:0]    m0_axi_wstrb,
    output              m0_axi_wvalid,
    input               m0_axi_wready,
    input      [1:0]    m0_axi_bresp,
    input               m0_axi_bvalid,
    output              m0_axi_bready,
    output     [11:0]   m0_axi_araddr,
    output              m0_axi_arvalid,
    input               m0_axi_arready,
    input      [31:0]   m0_axi_rdata,
    input      [1:0]    m0_axi_rresp,
    input               m0_axi_rvalid,
    output              m0_axi_rready,

    output     [11:0]   m1_axi_awaddr,
    output              m1_axi_awvalid,
    input               m1_axi_awready,
    output     [31:0]   m1_axi_wdata,
    output     [3:0]    m1_axi_wstrb,
    output              m1_axi_wvalid,
    input               m1_axi_wready,
    input      [1:0]    m1_axi_bresp,
    input               m1_axi_bvalid,
    output              m1_axi_bready,
    output     [11:0]   m1_axi_araddr,
    output              m1_axi_arvalid,
    input               m1_axi_arready,
    input      [31:0]   m1_axi_rdata,
    input      [1:0]    m1_axi_rresp,
    input               m1_axi_rvalid,
    output              m1_axi_rready
);

    reg [11:0] awaddr_q;
    reg aw_select_q;
    reg aw_valid_q;
    reg aw_sent_q;
    reg [31:0] wdata_q;
    reg [3:0] wstrb_q;
    reg w_valid_q;
    reg w_sent_q;
    reg [1:0] bresp_q;
    reg bvalid_q;

    reg [11:0] araddr_q;
    reg ar_select_q;
    reg ar_valid_q;
    reg ar_sent_q;
    reg [31:0] rdata_q;
    reg [1:0] rresp_q;
    reg rvalid_q;

    wire selected_awready_w;
    wire selected_wready_w;
    wire selected_bvalid_w;
    wire [1:0] selected_bresp_w;
    wire selected_arready_w;
    wire selected_rvalid_w;
    wire [31:0] selected_rdata_w;
    wire [1:0] selected_rresp_w;

    assign s_axi_awready = !aw_valid_q && !bvalid_q;
    assign s_axi_wready = !w_valid_q && !bvalid_q;
    assign s_axi_bresp = bresp_q;
    assign s_axi_bvalid = bvalid_q;
    assign s_axi_arready = !ar_valid_q && !rvalid_q;
    assign s_axi_rdata = rdata_q;
    assign s_axi_rresp = rresp_q;
    assign s_axi_rvalid = rvalid_q;

    assign m0_axi_awaddr = {4'd0, awaddr_q[7:0]};
    assign m0_axi_awvalid = aw_valid_q && !aw_sent_q && !aw_select_q;
    assign m0_axi_wdata = wdata_q;
    assign m0_axi_wstrb = wstrb_q;
    assign m0_axi_wvalid = aw_valid_q && w_valid_q && !w_sent_q && !aw_select_q;
    assign m0_axi_bready = !bvalid_q && !aw_select_q;
    assign m0_axi_araddr = {4'd0, araddr_q[7:0]};
    assign m0_axi_arvalid = ar_valid_q && !ar_sent_q && !ar_select_q;
    assign m0_axi_rready = !rvalid_q && !ar_select_q;

    assign m1_axi_awaddr = {4'd0, awaddr_q[7:0]};
    assign m1_axi_awvalid = aw_valid_q && !aw_sent_q && aw_select_q;
    assign m1_axi_wdata = wdata_q;
    assign m1_axi_wstrb = wstrb_q;
    assign m1_axi_wvalid = aw_valid_q && w_valid_q && !w_sent_q && aw_select_q;
    assign m1_axi_bready = !bvalid_q && aw_select_q;
    assign m1_axi_araddr = {4'd0, araddr_q[7:0]};
    assign m1_axi_arvalid = ar_valid_q && !ar_sent_q && ar_select_q;
    assign m1_axi_rready = !rvalid_q && ar_select_q;

    assign selected_awready_w = aw_select_q ? m1_axi_awready : m0_axi_awready;
    assign selected_wready_w = aw_select_q ? m1_axi_wready : m0_axi_wready;
    assign selected_bvalid_w = aw_select_q ? m1_axi_bvalid : m0_axi_bvalid;
    assign selected_bresp_w = aw_select_q ? m1_axi_bresp : m0_axi_bresp;
    assign selected_arready_w = ar_select_q ? m1_axi_arready : m0_axi_arready;
    assign selected_rvalid_w = ar_select_q ? m1_axi_rvalid : m0_axi_rvalid;
    assign selected_rdata_w = ar_select_q ? m1_axi_rdata : m0_axi_rdata;
    assign selected_rresp_w = ar_select_q ? m1_axi_rresp : m0_axi_rresp;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            awaddr_q <= 12'd0;
            aw_select_q <= 1'b0;
            aw_valid_q <= 1'b0;
            aw_sent_q <= 1'b0;
            wdata_q <= 32'd0;
            wstrb_q <= 4'd0;
            w_valid_q <= 1'b0;
            w_sent_q <= 1'b0;
            bresp_q <= 2'b00;
            bvalid_q <= 1'b0;
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin
                awaddr_q <= s_axi_awaddr;
                aw_select_q <= s_axi_awaddr[8];
                aw_valid_q <= 1'b1;
                aw_sent_q <= 1'b0;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                wdata_q <= s_axi_wdata;
                wstrb_q <= s_axi_wstrb;
                w_valid_q <= 1'b1;
                w_sent_q <= 1'b0;
            end
            if (aw_valid_q && !aw_sent_q && selected_awready_w)
                aw_sent_q <= 1'b1;
            if (aw_valid_q && w_valid_q && !w_sent_q && selected_wready_w)
                w_sent_q <= 1'b1;
            if (!bvalid_q && aw_sent_q && w_sent_q && selected_bvalid_w) begin
                bresp_q <= selected_bresp_w;
                bvalid_q <= 1'b1;
                aw_valid_q <= 1'b0;
                aw_sent_q <= 1'b0;
                w_valid_q <= 1'b0;
                w_sent_q <= 1'b0;
            end else if (bvalid_q && s_axi_bready) begin
                bvalid_q <= 1'b0;
            end
        end
    end

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            araddr_q <= 12'd0;
            ar_select_q <= 1'b0;
            ar_valid_q <= 1'b0;
            ar_sent_q <= 1'b0;
            rdata_q <= 32'd0;
            rresp_q <= 2'b00;
            rvalid_q <= 1'b0;
        end else begin
            if (s_axi_arvalid && s_axi_arready) begin
                araddr_q <= s_axi_araddr;
                ar_select_q <= s_axi_araddr[8];
                ar_valid_q <= 1'b1;
                ar_sent_q <= 1'b0;
            end
            if (ar_valid_q && !ar_sent_q && selected_arready_w)
                ar_sent_q <= 1'b1;
            if (!rvalid_q && ar_sent_q && selected_rvalid_w) begin
                rdata_q <= selected_rdata_w;
                rresp_q <= selected_rresp_w;
                rvalid_q <= 1'b1;
                ar_valid_q <= 1'b0;
                ar_sent_q <= 1'b0;
            end else if (rvalid_q && s_axi_rready) begin
                rvalid_q <= 1'b0;
            end
        end
    end

endmodule
