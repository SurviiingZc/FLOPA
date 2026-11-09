`timescale 1ns/1ps
`include "attention_defines.vh"

// Physical rows reserve MAX_D bytes. Streaming removes every unused feature
// slot and concatenates rows into a compact byte stream under AXI backpressure.
module output_buffer #(
    parameter integer ROWS = 32,
    parameter integer NORM_LANES = 8,
    parameter integer HEAD_DIM = 128,
    parameter integer OUT_W = 8,
    parameter integer GROUP_SIZE = 32,
    parameter integer NUM_STRIPES = ROWS / NORM_LANES,
    parameter integer STRIPE_IDX_W = (NUM_STRIPES < 2) ? 1 : $clog2(NUM_STRIPES),
    parameter integer FEATURE_IDX_W = (HEAD_DIM < 2) ? 1 : $clog2(HEAD_DIM),
    parameter integer GROUPS = (HEAD_DIM + GROUP_SIZE - 1) / GROUP_SIZE,
    parameter integer ADDR_W = (ROWS*GROUPS < 2) ? 1 : $clog2(ROWS*GROUPS)
)(
    input                                   clk,
    input                                   rst_n,
    input                                   clock_en_i,
    input                                   clear_tile_i,
    input       [7:0]                       head_dim_i,
    input                                   norm_valid_i,
    input       [STRIPE_IDX_W-1:0]           norm_stripe_i,
    input       [FEATURE_IDX_W-1:0]          norm_feature_i,
    input       [NORM_LANES*OUT_W-1:0]        norm_data_i,
    output                                  norm_ready_o,
    output reg                              norm_group_done_o,
    input                                   stream_start_i,
    input       [15:0]                      stream_bytes_i,
    output      [127:0]                     stream_data_o,
    output      [15:0]                      stream_strb_o,
    output                                  stream_valid_o,
    input                                   stream_ready_i,
    output                                  stream_last_o,
    output reg                              stream_busy_o,
    output reg                              stream_done_o
);

    localparam integer LOCAL_ROW_W = (NORM_LANES < 2) ? 1 : $clog2(NORM_LANES);
    localparam integer GROUP_IDX_W = (GROUPS < 2) ? 1 : $clog2(GROUPS);
    localparam integer ROW_IDX_W = (ROWS < 2) ? 1 : $clog2(ROWS);
    localparam [1:0] STREAM_REQ = 2'd0;
    localparam [1:0] STREAM_WAIT = 2'd1;
    localparam [1:0] STREAM_APPEND = 2'd2;
    localparam [1:0] STREAM_EMIT = 2'd3;

    reg [255:0] pack_q [0:NORM_LANES-1];
    reg flush_active_q;
    reg [LOCAL_ROW_W-1:0] flush_row_q;
    reg [STRIPE_IDX_W-1:0] flush_stripe_q;
    reg [GROUP_IDX_W-1:0] flush_group_q;
    reg [1:0] stream_state_q;
    reg [ROW_IDX_W-1:0] stream_row_q;
    reg [GROUP_IDX_W-1:0] stream_group_q;
    reg [383:0] reservoir_q;
    reg [5:0] reservoir_bytes_q;
    reg [15:0] bytes_left_q;
    reg [7:0] last_feature_q;
    reg [GROUP_IDX_W-1:0] last_group_q;
    reg [5:0] last_group_bytes_q;

    wire [4:0] norm_offset_w = norm_feature_i[4:0];
    wire [GROUP_IDX_W-1:0] norm_group_w = norm_feature_i >> 5;
    wire norm_group_last_w = norm_offset_w == 31 || norm_feature_i == last_feature_q;
    wire [4:0] final_pad_bytes_w = 5'd31 - norm_offset_w;
    wire [ROW_IDX_W-1:0] flush_global_row_w =
        flush_stripe_q * NORM_LANES + flush_row_q;
    wire [ADDR_W-1:0] write_addr_w = flush_global_row_w * GROUPS + flush_group_q;
    wire [ADDR_W-1:0] read_addr_w = stream_row_q * GROUPS + stream_group_q;
    wire read_en_w = stream_busy_o && stream_state_q == STREAM_REQ;
    wire [255:0] memory_data_w;
    wire [5:0] chunk_bytes_w = stream_group_q == last_group_q ?
        last_group_bytes_q : 6'd32;
    wire [5:0] emit_bytes_w = bytes_left_q >= 16 ? 6'd16 : {2'd0, bytes_left_q[3:0]};
    wire stream_fire_w = stream_valid_o && stream_ready_i;
    wire gated_clk_w;
    integer lane;

    fa_clock_gate u_clock_gate (
        .clk_i(clk), .enable_i(!rst_n || clock_en_i || clear_tile_i),
        .test_enable_i(1'b0), .clk_o(gated_clk_w)
    );

    assign norm_ready_o = !flush_active_q && !stream_busy_o;
    assign stream_data_o = reservoir_q[127:0];
    assign stream_valid_o = stream_busy_o && stream_state_q == STREAM_EMIT &&
        reservoir_bytes_q >= emit_bytes_w;
    assign stream_strb_o = bytes_left_q >= 16 ? 16'hffff :
        ~(16'hffff << bytes_left_q[3:0]);
    assign stream_last_o = stream_valid_o && bytes_left_q <= 16;

`ifndef SYNTHESIS
    reg [4:0] expected_offset_q;
    initial begin
        if (OUT_W != 8 || GROUP_SIZE != 32 || ROWS % NORM_LANES != 0)
            $fatal(1, "output_buffer invalid physical geometry");
        if (ROWS*GROUPS > 256)
            $fatal(1, "output_buffer exceeds the physical SRAM depth");
    end
    always @(posedge gated_clk_w or negedge rst_n) begin
        if (!rst_n)
            expected_offset_q <= 0;
        else if (clear_tile_i)
            expected_offset_q <= 0;
        else if (norm_valid_i && norm_ready_o) begin
            if (norm_offset_w != expected_offset_q)
                $fatal(1, "output_buffer out-of-order feature");
            expected_offset_q <= norm_group_last_w ? 0 : expected_offset_q + 1'b1;
        end
    end
`endif

`ifdef ATTN_ASIC
    asic_sram_256xwide #(.WIDTH(256)) u_out_mem (
        .clk(gated_clk_w), .en_i(flush_active_q || read_en_w),
        .wr_en_i(flush_active_q),
        .addr_i({{(8-ADDR_W){1'b0}}, flush_active_q ? write_addr_w : read_addr_w}),
        .wr_data_i(pack_q[0]), .rd_data_o(memory_data_w)
    );
`else
    (* ram_style = "block" *) reg [255:0] mem [0:ROWS*GROUPS-1];
    reg [255:0] memory_data_q;
    assign memory_data_w = memory_data_q;
    always @(posedge gated_clk_w) begin
        if (flush_active_q)
            mem[write_addr_w] <= pack_q[0];
        else if (read_en_w)
            memory_data_q <= mem[read_addr_w];
    end
`endif

    always @(posedge gated_clk_w or negedge rst_n) begin
        if (!rst_n) begin
            flush_active_q <= 1'b0;
            flush_row_q <= 0;
            flush_stripe_q <= 0;
            flush_group_q <= 0;
            norm_group_done_o <= 1'b0;
            stream_busy_o <= 1'b0;
            stream_done_o <= 1'b0;
            stream_state_q <= STREAM_REQ;
            stream_row_q <= 0;
            stream_group_q <= 0;
            reservoir_q <= 0;
            reservoir_bytes_q <= 0;
            bytes_left_q <= 0;
            last_feature_q <= `ATTN_DEFAULT_HEAD_DIM - 1;
            last_group_q <= (`ATTN_DEFAULT_HEAD_DIM - 1) >> 5;
            last_group_bytes_q <= 32;
        end else begin
            norm_group_done_o <= 1'b0;
            stream_done_o <= 1'b0;
            if (clear_tile_i) begin
                flush_active_q <= 1'b0;
                stream_busy_o <= 1'b0;
                reservoir_bytes_q <= 0;
                reservoir_q <= 0;
                bytes_left_q <= 0;
                last_feature_q <= head_dim_i - 1'b1;
                last_group_q <= (head_dim_i - 1'b1) >> 5;
                last_group_bytes_q <= {1'b0, ((head_dim_i - 1'b1) & 8'h1f)} + 1'b1;
            end else begin
                if (norm_valid_i && norm_ready_o) begin
                    for (lane = 0; lane < NORM_LANES; lane = lane + 1) begin
                        if (norm_offset_w == 0)
                            pack_q[lane] <=
                                {norm_data_i[lane*8 +: 8], 248'd0} >>
                                ((norm_feature_i == last_feature_q) ?
                                    {final_pad_bytes_w, 3'd0} : 8'd0);
                        else
                            pack_q[lane] <=
                                {norm_data_i[lane*8 +: 8], pack_q[lane][255:8]} >>
                                ((norm_feature_i == last_feature_q) ?
                                    {final_pad_bytes_w, 3'd0} : 8'd0);
                    end
                    if (norm_group_last_w) begin
                        flush_active_q <= 1'b1;
                        flush_row_q <= 0;
                        flush_stripe_q <= norm_stripe_i;
                        flush_group_q <= norm_group_w;
                    end
                end
                if (flush_active_q) begin
                    for (lane = 0; lane < NORM_LANES-1; lane = lane + 1)
                        pack_q[lane] <= pack_q[lane+1];
                    pack_q[NORM_LANES-1] <= 0;
                    if (flush_row_q == NORM_LANES-1) begin
                        flush_active_q <= 1'b0;
                        norm_group_done_o <= 1'b1;
                    end else
                        flush_row_q <= flush_row_q + 1'b1;
                end

                if (stream_start_i && !stream_busy_o && stream_bytes_i != 0) begin
                    stream_busy_o <= 1'b1;
                    stream_state_q <= STREAM_REQ;
                    stream_row_q <= 0;
                    stream_group_q <= 0;
                    reservoir_q <= 0;
                    reservoir_bytes_q <= 0;
                    bytes_left_q <= stream_bytes_i;
                end else if (stream_busy_o) begin
                    case (stream_state_q)
                        STREAM_REQ: stream_state_q <= STREAM_WAIT;
                        STREAM_WAIT: stream_state_q <= STREAM_APPEND;
                        STREAM_APPEND: begin
                            reservoir_q <= reservoir_q |
                                ({128'd0, memory_data_w} << {reservoir_bytes_q, 3'd0});
                            reservoir_bytes_q <= reservoir_bytes_q + chunk_bytes_w;
                            if (stream_group_q == last_group_q) begin
                                stream_row_q <= stream_row_q + 1'b1;
                                stream_group_q <= 0;
                            end else
                                stream_group_q <= stream_group_q + 1'b1;
                            stream_state_q <= STREAM_EMIT;
                        end
                        STREAM_EMIT: begin
                            if (stream_fire_w) begin
                                reservoir_q <= reservoir_q >> 128;
                                reservoir_bytes_q <= reservoir_bytes_q - emit_bytes_w;
                                bytes_left_q <= bytes_left_q - emit_bytes_w;
                                if (bytes_left_q <= 16) begin
                                    stream_busy_o <= 1'b0;
                                    stream_done_o <= 1'b1;
                                end else if ((reservoir_bytes_q - emit_bytes_w < 16) &&
                                    (reservoir_bytes_q < bytes_left_q))
                                    stream_state_q <= STREAM_REQ;
                            end else if (reservoir_bytes_q < emit_bytes_w)
                                stream_state_q <= STREAM_REQ;
                        end
                        default: stream_state_q <= STREAM_REQ;
                    endcase
                end
            end
        end
    end
endmodule
