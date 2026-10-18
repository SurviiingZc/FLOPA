`timescale 1ns/1ps

// Reproduce the committed PE arithmetic, including per-KV-tile alpha=32767.
// PASS means the INT32 limitation was reproduced, not that long N is qualified.
module tb_paper_pv_range;
    localparam DATA_W = 8, SCORE_W = 32, PROB_W = 16, SUM_W = 32, TAG_W = 6;
    reg clk = 0, rst_n = 0, clear_i = 0, clear_score_i = 0;
    reg q_valid_i = 0, k_valid_i = 0;
    reg [7:0] q_data_i = 0, k_data_i = 0;
    wire q_valid_o, k_valid_o;
    wire [7:0] q_data_o, k_data_o;
    reg score_lane_valid_i = 1;
    reg max_valid_i = 0, m_valid_i = 0;
    reg [31:0] max_data_i = 0, m_data_i = 0;
    wire max_valid_o, m_valid_o;
    wire [31:0] max_data_o, m_data_o, delta_o;
    reg prob_load_i = 0;
    reg [15:0] prob_data_i = 32767;
    reg pv_mac_valid_i = 0, sum_valid_i = 0;
    reg [31:0] sum_data_i = 0;
    reg [5:0] sum_tag_i = 0;
    wire sum_valid_o;
    wire [31:0] sum_data_o;
    wire [5:0] sum_tag_o;
    longint signed reference_sum, before_wrap, wide_sum;
    integer first_overflow, overflow_count;

    fsa_fused_pe #(
        .DATA_W(DATA_W), .SCORE_W(SCORE_W), .PROB_W(PROB_W),
        .SUM_W(SUM_W), .TAG_W(TAG_W)
    ) dut (.*);

    always #5 clk = ~clk;

    task automatic run_case(input integer v_value, input integer expected_first);
        reference_sum = 0;
        wide_sum = 0;
        first_overflow = 0;
        overflow_count = 0;
        for (integer token = 0; token < 16384; token = token + 1) begin
            if (token % 32 == 0) begin
                reference_sum = (reference_sum * 32767) >>> 15;
                wide_sum = (wide_sum * 32767) >>> 15;
            end
            @(negedge clk);
            k_data_i = 8'(v_value);
            k_valid_i = 1;
            sum_valid_i = 1;
            pv_mac_valid_i = 1;
            sum_data_i = reference_sum[31:0];
            sum_tag_i = 6'(token);
            before_wrap = reference_sum + 32767 * v_value;
            wide_sum = wide_sum + 32767 * v_value;
            if (before_wrap < -64'sd2147483648 || before_wrap > 64'sd2147483647) begin
                if (first_overflow == 0)
                    first_overflow = token + 1;
                overflow_count = overflow_count + 1;
            end
            reference_sum = $signed(before_wrap[31:0]);
            @(posedge clk);
            #1;
            if (!sum_valid_o || $signed(sum_data_o) !== reference_sum ||
                    sum_tag_o !== 6'(token))
                $fatal(1, "RTL_SHADOW_MISMATCH token=%0d rtl=%0d ref=%0d",
                    token + 1, $signed(sum_data_o), reference_sum);
            @(negedge clk);
            k_valid_i = 0;
            sum_valid_i = 0;
            pv_mac_valid_i = 0;
        end
        if (first_overflow != expected_first)
            $fatal(1, "UNEXPECTED_BOUNDARY v=%0d first=%0d", v_value, first_overflow);
        $display("PV_RANGE v=%0d N=16384 first_overflow=%0d overflows=%0d wide=%0d rtl=%0d",
            v_value, first_overflow, overflow_count, wide_sum, reference_sum);
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        prob_load_i = 1;
        @(negedge clk);
        prob_load_i = 0;
        run_case(-128, 513);
        run_case(127, 517);
        $display("[PASS] tb_paper_pv_range: reproduced INT32 limit in unchanged RTL");
        $finish;
    end

    initial begin
        repeat (200000) @(posedge clk);
        $fatal(1, "timeout");
    end
endmodule
