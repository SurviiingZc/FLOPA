`timescale 1ns/1ps

// Two complete O versions per row. One single-port bank supplies O_old while
// the other receives O_new. A PV pass changes ownership only after the previous
// pass has drained; normalization reads the most recently written version.
module o_accumulator_bank #(
    parameter integer ROWS = 8,
    parameter integer HEAD_DIM = 128,
    parameter integer GROUP_SIZE = 32,
    parameter integer DATA_W = 32,
    parameter integer ROW_IDX_W = (ROWS < 2) ? 1 : $clog2(ROWS),
    parameter integer FEATURE_IDX_W = (HEAD_DIM < 2) ? 1 : $clog2(HEAD_DIM)
)(
    input                                   clk,
    input                                   rst_n,
    input                                   clear_i,
    input                                   pass_start_i,
    input                                   first_pass_i,
    input                                   rd_current_i,
    input                                   rd_en_i,
    input       [FEATURE_IDX_W-1:0]          rd_feature_i,
    output reg                              rd_valid_o,
    output reg  [ROWS*DATA_W-1:0]            rd_data_o,
    input       [ROWS-1:0]                   wr_valid_i,
    input       [ROWS*FEATURE_IDX_W-1:0]      wr_feature_i,
    input       [ROWS*DATA_W-1:0]             wr_data_i
);

    reg write_bank_q;
    reg read_bank_q;
    wire selected_read_bank_w = rd_current_i ? write_bank_q : !write_bank_q;
    integer row;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_bank_q <= 1'b0;
            read_bank_q <= 1'b0;
            rd_valid_o <= 1'b0;
        end else if (clear_i) begin
            write_bank_q <= 1'b0;
            rd_valid_o <= 1'b0;
        end else begin
            if (pass_start_i)
                write_bank_q <= first_pass_i ? 1'b0 : !write_bank_q;
            rd_valid_o <= rd_en_i;
            if (rd_en_i)
                read_bank_q <= selected_read_bank_w;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (HEAD_DIM > 256 || DATA_W % 8 != 0)
            $fatal(1, "o_accumulator_bank unsupported physical geometry");
    end
    always @(posedge clk) begin
        if (rst_n && !clear_i) begin
            if (pass_start_i && (rd_en_i || |wr_valid_i))
                $fatal(1, "O version switched before previous pass drained");
            if (rd_en_i && selected_read_bank_w == write_bank_q && |wr_valid_i)
                $fatal(1, "O single-port version-bank collision");
        end
    end
`endif

`ifdef ATTN_ASIC
    wire [DATA_W-1:0] macro_q_w [0:ROWS-1][0:1];
    generate
        genvar macro_row;
        genvar version;
        for (macro_row = 0; macro_row < ROWS; macro_row = macro_row + 1) begin : g_row
            for (version = 0; version < 2; version = version + 1) begin : g_version
                wire wr_select_w = wr_valid_i[macro_row] && write_bank_q == version;
                wire rd_select_w = rd_en_i && selected_read_bank_w == version;
                wire [FEATURE_IDX_W-1:0] wr_feature_w =
                    wr_feature_i[macro_row*FEATURE_IDX_W +: FEATURE_IDX_W];
                asic_sram_256xwide #(.WIDTH(DATA_W)) u_mem (
                    .clk(clk), .en_i(wr_select_w || rd_select_w),
                    .wr_en_i(wr_select_w),
                    .addr_i(wr_select_w ?
                        {{(8-FEATURE_IDX_W){1'b0}}, wr_feature_w} :
                        {{(8-FEATURE_IDX_W){1'b0}}, rd_feature_i}),
                    .wr_data_i(wr_data_i[macro_row*DATA_W +: DATA_W]),
                    .rd_data_o(macro_q_w[macro_row][version])
                );
            end
        end
    endgenerate
    always @* begin
        rd_data_o = {ROWS*DATA_W{1'b0}};
        for (row = 0; row < ROWS; row = row + 1)
            rd_data_o[row*DATA_W +: DATA_W] = macro_q_w[row][read_bank_q];
    end
`else
    (* ram_style = "block" *) reg [DATA_W-1:0] mem [0:ROWS-1][0:1][0:HEAD_DIM-1];
    always @(posedge clk) begin
        if (rst_n && !clear_i) begin
            if (rd_en_i) begin
                for (row = 0; row < ROWS; row = row + 1)
                    rd_data_o[row*DATA_W +: DATA_W] <=
                        mem[row][selected_read_bank_w][rd_feature_i];
            end
            for (row = 0; row < ROWS; row = row + 1) begin
                if (wr_valid_i[row])
                    mem[row][write_bank_q]
                        [wr_feature_i[row*FEATURE_IDX_W +: FEATURE_IDX_W]] <=
                            wr_data_i[row*DATA_W +: DATA_W];
            end
        end
    end
`endif

endmodule
