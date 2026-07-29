`timescale 1ns/1ps

module axis_tile_loader #(
    parameter integer CACHE_ADDR_W = 6,
    parameter integer DEFAULT_BEATS = 128
)(
    input                         clk,
    input                         rst_n,

    input      [31:0]             s_axi_awaddr,
    input                         s_axi_awvalid,
    output                        s_axi_awready,
    input      [31:0]             s_axi_wdata,
    input      [3:0]              s_axi_wstrb,
    input                         s_axi_wvalid,
    output                        s_axi_wready,
    output reg [1:0]              s_axi_bresp,
    output reg                    s_axi_bvalid,
    input                         s_axi_bready,
    input      [31:0]             s_axi_araddr,
    input                         s_axi_arvalid,
    output                        s_axi_arready,
    output reg [31:0]             s_axi_rdata,
    output reg [1:0]              s_axi_rresp,
    output reg                    s_axi_rvalid,
    input                         s_axi_rready,

    input      [127:0]            s_axis_tdata,
    input      [15:0]             s_axis_tkeep,
    input      [3:0]              s_axis_tuser,
    input                         s_axis_tlast,
    input                         s_axis_tvalid,
    output                        s_axis_tready,

    output     [1:0]              tile_load_kind_o,
    output                        tile_load_bank_o,
    output     [CACHE_ADDR_W-1:0] tile_load_addr_o,
    output                        tile_load_half_o,
    output     [127:0]            tile_load_data_o,
    output                        tile_load_valid_o,
    input                         tile_load_ready_i,
    output reg [1:0]              tile_commit_kind_o,
    output reg                    tile_commit_bank_o,
    output reg                    tile_commit_valid_o,

    output                        irq_o
);

    localparam [11:0] REG_CONTROL = 12'h000;
    localparam [11:0] REG_STATUS = 12'h004;
    localparam [11:0] REG_DESCRIPTOR = 12'h008;
    localparam [11:0] REG_BEATS = 12'h00c;
    localparam [11:0] REG_PROGRESS = 12'h010;
    localparam [11:0] REG_VERSION = 12'h014;
    localparam [11:0] REG_TILES = 12'h018;
    localparam [15:0] DEFAULT_BEATS_16 = DEFAULT_BEATS[15:0];

    wire wr_fire_w;
    wire rd_fire_w;
    wire [31:0] wr_addr_w;
    wire [31:0] wr_data_w;
    wire [3:0] wr_strb_w;
    wire [31:0] rd_addr_w;
    wire stream_fire_w;
    wire expected_last_w;
    wire metadata_valid_w;
    wire metadata_match_w;
    wire stream_fault_w;
    wire [1:0] stream_kind_w = s_axis_tuser[1:0];
    wire stream_bank_w = s_axis_tuser[2];
    wire stream_job_last_w = s_axis_tuser[3];

    reg [15:0] beat_index_q;
    reg [15:0] tile_count_q;
    reg armed_q;
    reg busy_q;
    reg done_q;
    reg error_q;
    reg in_tile_q;
    reg [1:0] active_kind_q;
    reg active_bank_q;
    reg active_job_last_q;
    reg commit_pending_q;
    reg [1:0] commit_kind_q;
    reg commit_bank_q;
    reg commit_job_last_q;

    assign metadata_valid_w = stream_kind_w != 2'b11;
    assign metadata_match_w = !in_tile_q ||
                              (stream_kind_w == active_kind_q &&
                               stream_bank_w == active_bank_q &&
                               stream_job_last_w == active_job_last_q);
    assign stream_fault_w = !metadata_valid_w || !metadata_match_w ||
                            s_axis_tkeep != 16'hffff ||
                            s_axis_tlast != expected_last_w;
    assign s_axis_tready = armed_q && !error_q && !commit_pending_q &&
                           !tile_commit_valid_o &&
                           (stream_fault_w || tile_load_ready_i);
    assign stream_fire_w = s_axis_tvalid && s_axis_tready;
    assign expected_last_w = beat_index_q == DEFAULT_BEATS_16 - 1'b1;

    assign tile_load_kind_o = stream_kind_w;
    assign tile_load_bank_o = stream_bank_w;
    assign tile_load_addr_o = beat_index_q[CACHE_ADDR_W:1];
    assign tile_load_half_o = beat_index_q[0];
    assign tile_load_data_o = s_axis_tdata;
    assign tile_load_valid_o = stream_fire_w && !stream_fault_w;
    assign irq_o = done_q || error_q;

    function is_known_addr;
        input [11:0] addr;
        begin
            case (addr)
                REG_CONTROL, REG_STATUS, REG_DESCRIPTOR, REG_BEATS,
                REG_PROGRESS, REG_VERSION, REG_TILES: is_known_addr = 1'b1;
                default: is_known_addr = 1'b0;
            endcase
        end
    endfunction

    function [31:0] read_reg_value;
        input [11:0] addr;
        begin
            case (addr)
                REG_CONTROL: read_reg_value = 32'd0;
                REG_STATUS: read_reg_value =
                    {27'd0, armed_q, !busy_q, error_q, done_q, busy_q};
                REG_DESCRIPTOR: read_reg_value =
                    {28'd0, active_job_last_q, active_bank_q, active_kind_q};
                REG_BEATS: read_reg_value = {16'd0, DEFAULT_BEATS_16};
                REG_PROGRESS: read_reg_value = {16'd0, beat_index_q};
                REG_VERSION: read_reg_value = 32'h0002_0000;
                REG_TILES: read_reg_value = {16'd0, tile_count_q};
                default: read_reg_value = 32'd0;
            endcase
        end
    endfunction

    axi4_slave_if #(.ADDR_W(32)) u_axi_lite_if (
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_bresp <= 2'b00;
            s_axi_bvalid <= 1'b0;
            s_axi_rdata <= 32'd0;
            s_axi_rresp <= 2'b00;
            s_axi_rvalid <= 1'b0;
            beat_index_q <= 16'd0;
            tile_count_q <= 16'd0;
            armed_q <= 1'b0;
            busy_q <= 1'b0;
            done_q <= 1'b0;
            error_q <= 1'b0;
            in_tile_q <= 1'b0;
            active_kind_q <= 2'd0;
            active_bank_q <= 1'b0;
            active_job_last_q <= 1'b0;
            commit_pending_q <= 1'b0;
            commit_kind_q <= 2'd0;
            commit_bank_q <= 1'b0;
            commit_job_last_q <= 1'b0;
            tile_commit_kind_o <= 2'd0;
            tile_commit_bank_o <= 1'b0;
            tile_commit_valid_o <= 1'b0;
        end else begin
            tile_commit_valid_o <= 1'b0;

            if (commit_pending_q) begin
                tile_commit_kind_o <= commit_kind_q;
                tile_commit_bank_o <= commit_bank_q;
                tile_commit_valid_o <= 1'b1;
                commit_pending_q <= 1'b0;
            end

            if (tile_commit_valid_o) begin
                tile_count_q <= tile_count_q + 1'b1;
                if (commit_job_last_q) begin
                    armed_q <= 1'b0;
                    busy_q <= 1'b0;
                    done_q <= 1'b1;
                end
            end

            if (stream_fire_w) begin
                if (stream_fault_w) begin
                    armed_q <= 1'b0;
                    busy_q <= 1'b0;
                    error_q <= 1'b1;
                    in_tile_q <= 1'b0;
                end else begin
                    if (!in_tile_q) begin
                        active_kind_q <= stream_kind_w;
                        active_bank_q <= stream_bank_w;
                        active_job_last_q <= stream_job_last_w;
                    end
                    if (expected_last_w) begin
                        beat_index_q <= 16'd0;
                        in_tile_q <= 1'b0;
                        commit_pending_q <= 1'b1;
                        commit_kind_q <= stream_kind_w;
                        commit_bank_q <= stream_bank_w;
                        commit_job_last_q <= stream_job_last_w;
                    end else begin
                        beat_index_q <= beat_index_q + 1'b1;
                        in_tile_q <= 1'b1;
                    end
                end
            end

            if (wr_fire_w) begin
                s_axi_bresp <= 2'b00;
                if (wr_addr_w[11:0] != REG_CONTROL) begin
                    s_axi_bresp <= 2'b10;
                end else if (wr_strb_w[0]) begin
                    if (wr_data_w[1]) begin
                        armed_q <= 1'b0;
                        busy_q <= 1'b0;
                        in_tile_q <= 1'b0;
                        commit_pending_q <= 1'b0;
                        beat_index_q <= 16'd0;
                    end
                    if (wr_data_w[2]) done_q <= 1'b0;
                    if (wr_data_w[3]) error_q <= 1'b0;
                    if (wr_data_w[0]) begin
                        if (busy_q || armed_q) begin
                            s_axi_bresp <= 2'b10;
                            error_q <= 1'b1;
                        end else begin
                            beat_index_q <= 16'd0;
                            tile_count_q <= 16'd0;
                            armed_q <= 1'b1;
                            busy_q <= 1'b1;
                            done_q <= 1'b0;
                            error_q <= 1'b0;
                            in_tile_q <= 1'b0;
                            commit_pending_q <= 1'b0;
                        end
                    end
                end
                s_axi_bvalid <= 1'b1;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end

            if (rd_fire_w) begin
                s_axi_rdata <= read_reg_value(rd_addr_w[11:0]);
                s_axi_rresp <= is_known_addr(rd_addr_w[11:0]) ? 2'b00 : 2'b10;
                s_axi_rvalid <= 1'b1;
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

endmodule
