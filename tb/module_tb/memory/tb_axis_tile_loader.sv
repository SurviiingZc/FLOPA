`timescale 1ns/1ps
`include "attention_defines.vh"
`include "tb_common.svh"

module tb_axis_tile_loader;
    localparam integer CACHE_ADDR_W = 2;
    localparam integer TILE_BEATS = 8;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg [31:0] awaddr = 32'd0;
    reg awvalid = 1'b0;
    wire awready;
    reg [31:0] wdata = 32'd0;
    reg [3:0] wstrb = 4'h0;
    reg wvalid = 1'b0;
    wire wready;
    wire [1:0] bresp;
    wire bvalid;
    reg bready = 1'b1;
    reg [31:0] araddr = 32'd0;
    reg arvalid = 1'b0;
    wire arready;
    wire [31:0] rdata;
    wire [1:0] rresp;
    wire rvalid;
    reg rready = 1'b1;

    reg [127:0] axis_tdata = 128'd0;
    reg [15:0] axis_tkeep = 16'hffff;
    reg [3:0] axis_tuser = 4'd0;
    reg axis_tlast = 1'b0;
    reg axis_tvalid = 1'b0;
    wire axis_tready;

    wire [1:0] load_kind;
    wire load_bank;
    wire [CACHE_ADDR_W-1:0] load_addr;
    wire load_half;
    wire [127:0] load_data;
    wire load_valid;
    wire load_ready;
    wire [1:0] commit_kind;
    wire commit_bank;
    wire commit_valid;
    wire loader_irq;

    reg q_consume = 1'b0;
    reg q_switch = 1'b0;
    reg k_consume = 1'b0;
    reg k_switch = 1'b0;
    reg v_consume = 1'b0;
    reg v_switch = 1'b0;
    wire cache_error;
    wire q_active_valid;
    wire kv_active_valid;
    wire q_next_valid;
    wire kv_next_valid;
    wire q_active_bank;
    wire kv_active_bank;
    wire k_next_valid;
    wire v_next_valid;
    integer errors = 0;

    axis_tile_loader #(
        .CACHE_ADDR_W(CACHE_ADDR_W),
        .DEFAULT_BEATS(TILE_BEATS)
    ) loader (
        .clk(clk),
        .rst_n(rst_n),
        .s_axi_awaddr(awaddr),
        .s_axi_awvalid(awvalid),
        .s_axi_awready(awready),
        .s_axi_wdata(wdata),
        .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid),
        .s_axi_wready(wready),
        .s_axi_bresp(bresp),
        .s_axi_bvalid(bvalid),
        .s_axi_bready(bready),
        .s_axi_araddr(araddr),
        .s_axi_arvalid(arvalid),
        .s_axi_arready(arready),
        .s_axi_rdata(rdata),
        .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid),
        .s_axi_rready(rready),
        .s_axis_tdata(axis_tdata),
        .s_axis_tkeep(axis_tkeep),
        .s_axis_tuser(axis_tuser),
        .s_axis_tlast(axis_tlast),
        .s_axis_tvalid(axis_tvalid),
        .s_axis_tready(axis_tready),
        .tile_load_kind_o(load_kind),
        .tile_load_bank_o(load_bank),
        .tile_load_addr_o(load_addr),
        .tile_load_half_o(load_half),
        .tile_load_data_o(load_data),
        .tile_load_valid_o(load_valid),
        .tile_load_ready_i(load_ready),
        .tile_commit_kind_o(commit_kind),
        .tile_commit_bank_o(commit_bank),
        .tile_commit_valid_o(commit_valid),
        .irq_o(loader_irq)
    );

    qkv_tile_cache #(
        .ADDR_W(CACHE_ADDR_W),
        .BANKS(16),
        .BANK_W(16)
    ) cache (
        .clk(clk),
        .rst_n(rst_n),
        .clear_i(1'b0),
        .load_kind_i(load_kind),
        .load_bank_i(load_bank),
        .load_addr_i(load_addr),
        .load_half_i(load_half),
        .load_data_i(load_data),
        .load_valid_i(load_valid),
        .load_ready_o(load_ready),
        .commit_kind_i(commit_kind),
        .commit_bank_i(commit_bank),
        .commit_valid_i(commit_valid),
        .q_consume_i(q_consume),
        .q_switch_i(q_switch),
        .k_consume_i(k_consume),
        .k_switch_i(k_switch),
        .v_consume_i(v_consume),
        .v_switch_i(v_switch),
        .q_active_valid_o(q_active_valid),
        .kv_active_valid_o(kv_active_valid),
        .q_next_valid_o(q_next_valid),
        .kv_next_valid_o(kv_next_valid),
        .q_active_bank_o(q_active_bank),
        .kv_active_bank_o(kv_active_bank),
        .k_next_valid_o(k_next_valid),
        .v_next_valid_o(v_next_valid),
        .q_rd_en_i(1'b0),
        .q_rd_addr_i({CACHE_ADDR_W{1'b0}}),
        .q_rd_data_o(),
        .q_rd_valid_o(),
        .k_rd_en_i(1'b0),
        .k_rd_addr_i({CACHE_ADDR_W{1'b0}}),
        .k_rd_data_o(),
        .k_rd_valid_o(),
        .v_rd_en_i(1'b0),
        .v_rd_addr_i({CACHE_ADDR_W{1'b0}}),
        .v_rd_data_o(),
        .v_rd_valid_o(),
        .protocol_error_o(cache_error)
    );

    always #5 clk = ~clk;
    `TB_TIMEOUT(1000, "tb_axis_tile_loader")

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
            `TB_CHECK(bresp == 2'b00, "loader control write response")
        end
    endtask

    task automatic stream_tile;
        input [1:0] kind;
        input bank;
        input job_last;
        integer beat;
        begin
            for (beat = 0; beat < TILE_BEATS; beat = beat + 1) begin
                @(negedge clk);
                axis_tdata = {96'd0, kind, bank, beat[28:0]};
                axis_tuser = {job_last, bank, kind};
                axis_tlast = beat == TILE_BEATS - 1;
                axis_tvalid = 1'b1;
                while (!axis_tready) begin
                    @(negedge clk);
                end
                @(posedge clk);
                #1;
                axis_tvalid = 1'b0;
            end
        end
    endtask

    task automatic release_k;
        begin
            @(negedge clk);
            k_consume = 1'b1;
            k_switch = 1'b1;
            @(negedge clk);
            k_consume = 1'b0;
            k_switch = 1'b0;
        end
    endtask

    task automatic release_v;
        begin
            @(negedge clk);
            v_consume = 1'b1;
            v_switch = 1'b1;
            @(negedge clk);
            v_consume = 1'b0;
            v_switch = 1'b0;
        end
    endtask

    task automatic check_blocked;
        input [1:0] kind;
        input bank;
        begin
            @(posedge clk);
            while (!(axis_tvalid && axis_tuser[1:0] == kind &&
                     axis_tuser[2] == bank)) begin
                @(posedge clk);
            end
            repeat (2) @(posedge clk);
            #1;
            `TB_CHECK(!axis_tready, "occupied bank applies AXIS backpressure")
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        axil_write(32'h000, 32'h0000_000d);

        fork
            begin
                stream_tile(`ATTN_CACHE_Q, 1'b0, 1'b0);
                stream_tile(`ATTN_CACHE_K, 1'b0, 1'b0);
                stream_tile(`ATTN_CACHE_V, 1'b0, 1'b0);
                stream_tile(`ATTN_CACHE_K, 1'b1, 1'b0);
                stream_tile(`ATTN_CACHE_V, 1'b1, 1'b0);
                stream_tile(`ATTN_CACHE_Q, 1'b1, 1'b0);
                stream_tile(`ATTN_CACHE_K, 1'b0, 1'b0);
                stream_tile(`ATTN_CACHE_V, 1'b0, 1'b0);
                stream_tile(`ATTN_CACHE_K, 1'b1, 1'b0);
                stream_tile(`ATTN_CACHE_V, 1'b1, 1'b1);
            end
            begin
                wait (loader.tile_count_q == 3);
                #1;
                `TB_CHECK(q_active_valid && kv_active_valid,
                          "Q0/K0/V0 are ready at the compute start watermark")
                wait (loader.tile_count_q == 6);
                #1;
                `TB_CHECK(q_active_valid && q_next_valid,
                          "both Q banks are ready before compute")
                `TB_CHECK(kv_active_valid && kv_next_valid,
                          "both KV banks are ready before compute")

                check_blocked(`ATTN_CACHE_K, 1'b0);
                release_k();
                wait (loader.tile_count_q == 7);
                check_blocked(`ATTN_CACHE_V, 1'b0);
                release_v();
                wait (loader.tile_count_q == 8);
                check_blocked(`ATTN_CACHE_K, 1'b1);
                release_k();
                wait (loader.tile_count_q == 9);
                check_blocked(`ATTN_CACHE_V, 1'b1);
                release_v();
            end
        join

        wait (loader.tile_count_q == 10);
        repeat (3) @(posedge clk);
        `TB_CHECK(loader.done_q && loader_irq, "job-last completes loader schedule")
        `TB_CHECK(!loader.error_q && !cache_error, "schedule completes without errors")

        axil_write(32'h000, 32'h0000_000d);
        @(negedge clk);
        axis_tuser = 4'b0011;
        axis_tlast = 1'b0;
        axis_tvalid = 1'b1;
        #1;
        `TB_CHECK(axis_tready && !load_valid,
                  "invalid metadata is accepted for error handling but not cached")
        @(posedge clk);
        #1;
        axis_tvalid = 1'b0;
        `TB_CHECK(loader.error_q && loader_irq, "invalid metadata reports loader error")
        `TB_FINISH("tb_axis_tile_loader")
    end
endmodule
