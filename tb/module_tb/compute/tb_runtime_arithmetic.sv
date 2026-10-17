`timescale 1ns/1ps

// Focused arithmetic/clock tests complement short end-to-end UVM jobs.
module tb_runtime_arithmetic;
    reg clk = 0;
    always #5 clk = ~clk;

    reg mult_rst_n = 0;
    reg mult_valid_i = 0;
    reg signed [31:0] mult_a = 0;
    reg signed [30:0] mult_b = 0;
    wire mult_valid_o;
    wire signed [62:0] mult_product;
    reg [2:0] mult_ref_valid = 0;
    reg signed [62:0] mult_ref_product[0:2];
    integer mult_checked = 0;
    bit mult_done = 0;

    fa_signed_mult_pipe3 mult (
        .clk(clk), .rst_n(mult_rst_n), .valid_i(mult_valid_i),
        .a_i(mult_a), .b_i(mult_b), .valid_o(mult_valid_o), .product_o(mult_product)
    );

    always @(posedge clk or negedge mult_rst_n) begin
        if (!mult_rst_n)
            mult_ref_valid <= 0;
        else begin
            mult_ref_valid <= {mult_ref_valid[1:0], mult_valid_i};
            if (mult_valid_i)
                mult_ref_product[0] <= $signed(mult_a) * $signed(mult_b);
            mult_ref_product[1] <= mult_ref_product[0];
            mult_ref_product[2] <= mult_ref_product[1];
        end
    end

    always @(negedge clk) begin
        #1;
        if (mult_rst_n) begin
            if (mult_valid_o !== mult_ref_valid[2])
                $fatal(1, "pipe3 valid/bubble/reset mismatch");
            if (mult_valid_o) begin
                if (mult_product !== mult_ref_product[2])
                    $fatal(1, "pipe3 exact product mismatch got=%0d expected=%0d",
                        mult_product, mult_ref_product[2]);
                mult_checked++;
            end
        end
    end

    task automatic drive_mult(input reg signed [31:0] a,
        input reg signed [30:0] b, input bit valid);
        @(negedge clk);
        mult_a = a;
        mult_b = b;
        mult_valid_i = valid;
    endtask

    task automatic test_mult();
        reg signed [31:0] a_values[8] = '{
            32'sh8000_0000, 32'sh7fff_ffff, -1, 0, 1,
            32'sh0000_ffff, 32'shffff_0001, 32'sh0001_0000};
        reg signed [30:0] b_values[8] = '{
            31'sh4000_0000, 31'sh3fff_ffff, -1, 0, 1,
            31'sh0000_7fff, 31'sh7fff_8001, 31'sh0000_8000};
        repeat (3) @(negedge clk);
        mult_rst_n = 1;
        foreach (a_values[ai])
            foreach (b_values[bi])
                drive_mult(a_values[ai], b_values[bi], 1);
        for (int index = 0; index < 600; index++) begin
            drive_mult($random, $random, (index % 7) != 3);
            if (index == 299) begin
                // An asynchronous assertion cancels in-flight valid tokens.
                #2 mult_rst_n = 0;
                #1;
                if (mult_valid_o !== 0)
                    $fatal(1, "pipe3 valid not asynchronously cleared");
                repeat (2) @(negedge clk);
                mult_rst_n = 1;
            end
        end
        repeat (6) drive_mult(0, 0, 0);
        if (mult_checked < 570)
            $fatal(1, "pipe3 too few comparisons: %0d", mult_checked);
        $display("[PASS] signed_mult_pipe3 exact_products=%0d", mult_checked);
        mult_done = 1;
    endtask

    reg norm_rst_n = 0;
    reg norm_clock_en = 1;
    reg norm_clear = 0;
    reg norm_valid_i = 0;
    reg [255:0] norm_acc = 0;
    reg [255:0] norm_l = 0;
    reg [31:0] norm_scale = 1;
    reg [7:0] norm_tag_i = 0;
    wire norm_valid_o;
    wire [63:0] norm_result;
    wire [7:0] norm_tag_o;
    reg [63:0] expected_result[0:255];
    reg [7:0] expected_tag[0:255];
    integer norm_wr = 0;
    integer norm_rd = 0;
    integer norm_checked = 0;
    integer norm_edges = 0;
    bit norm_done = 0;

    online_normalizer #(.LANES(8), .TAG_W(8)) norm (
        .clk(clk), .rst_n(norm_rst_n), .clock_en_i(norm_clock_en), .clear_i(norm_clear),
        .valid_i(norm_valid_i), .acc_rows_i(norm_acc), .l_rows_i(norm_l),
        .out_scale_i(norm_scale), .tag_i(norm_tag_i), .valid_o(norm_valid_o),
        .out_rows_o(norm_result), .tag_o(norm_tag_o)
    );

    // With l=32768, the published reciprocal LUT returns exactly 32767.
    // Independent 64-bit arithmetic preserves the RTL's signed rounding rule.
    function automatic [7:0] golden_norm(input reg signed [31:0] acc,
        input reg [31:0] scale);
        reg signed [63:0] value;
        reg signed [63:0] rounded;
        reg guard_bit;
        reg sticky;
        integer shift;
        value = $signed({{32{acc[31]}}, acc}) * 64'sd32767;
        value = value >>> 15;
        value = value * $signed(scale[15:0]);
        shift = scale[21:16];
        guard_bit = 0;
        sticky = 0;
        if (shift > 0) begin
            guard_bit = value[shift - 1];
            for (int bit_index = 0; bit_index < shift - 1; bit_index++)
                sticky |= value[bit_index];
        end
        rounded = value >>> shift;
        if (guard_bit && (!value[63] || sticky))
            rounded = rounded + 64'sd1;
        if (rounded > 127) return 8'd127;
        if (rounded < -128) return 8'h80;
        return rounded[7:0];
    endfunction

    always @(posedge clk) begin
        if (!norm_rst_n || norm_clear) begin
            norm_wr = 0;
            norm_rd = 0;
        end else if (norm_clock_en && norm_valid_i) begin
            for (int lane = 0; lane < 8; lane++)
                expected_result[norm_wr][lane*8 +: 8] =
                    golden_norm($signed(norm_acc[lane*32 +: 32]), norm_scale);
            expected_tag[norm_wr] = norm_tag_i;
            norm_wr++;
        end
    end

    always @(posedge norm.gated_clk_w)
        norm_edges++;

    always @(negedge clk) begin
        #1;
        if (norm_rst_n && !norm_clear && norm_valid_o) begin
            if (norm_rd >= norm_wr || norm_tag_o !== expected_tag[norm_rd] ||
                norm_result !== expected_result[norm_rd])
                $fatal(1, "normalizer value/tag mismatch index=%0d got=%h expected=%h",
                    norm_rd, norm_result, expected_result[norm_rd]);
            norm_rd++;
            norm_checked++;
        end
    end

    task automatic drive_norm(input integer index, input bit valid);
        @(negedge clk);
        norm_valid_i = valid;
        norm_tag_i = index;
        norm_scale = (index % 3 == 0) ? 32'h0000_0001 :
            (index % 3 == 1) ? 32'h0004_0003 : 32'h0002_0001;
        for (int lane = 0; lane < 8; lane++) begin
            norm_acc[lane*32 +: 32] = (index * 13 + lane * 31 - 513);
            norm_l[lane*32 +: 32] = 32768;
        end
    endtask

    task automatic test_norm();
        integer idle_edges;
        repeat (3) @(negedge clk);
        norm_rst_n = 1;
        for (int index = 0; index < 100; index++)
            drive_norm(index, index % 5 != 2);
        drive_norm(0, 0);
        repeat (30) @(negedge clk);
        if (norm_wr != norm_rd || norm_checked != 80)
            $fatal(1, "normalizer missing output wr=%0d rd=%0d checked=%0d",
                norm_wr, norm_rd, norm_checked);
        norm_clock_en = 0;
        repeat (3) @(negedge clk);
        idle_edges = norm_edges;
        repeat (12) @(negedge clk);
        if (norm_edges != idle_edges)
            $fatal(1, "normalizer clock did not gate during idle");
        norm_clear = 1;
        repeat (2) @(negedge clk);
        norm_clear = 0;
        if (norm_valid_o !== 0)
            $fatal(1, "normalizer clear did not flush a closed clock branch");
        norm_clock_en = 1;
        drive_norm(201, 1);
        drive_norm(202, 1);
        #2 norm_rst_n = 0;
        norm_valid_i = 0;
        #1;
        if (norm_valid_o !== 0)
            $fatal(1, "normalizer asynchronous reset did not clear output valid");
        repeat (2) @(negedge clk);
        norm_rst_n = 1;
        drive_norm(203, 1);
        drive_norm(0, 0);
        repeat (30) @(negedge clk);
        if (norm_wr != norm_rd || norm_checked != 81)
            $fatal(1, "normalizer reset recovery wr=%0d rd=%0d total=%0d",
                norm_wr, norm_rd, norm_checked);
        $display("[PASS] online_normalizer exact_vectors=%0d lanes=8", norm_checked);
        norm_done = 1;
    endtask

    reg gate_enable = 0;
    reg gate_test_enable = 0;
    wire gate_clk;
    bit gate_done = 0;
    time gate_rise;
    integer gate_edges = 0;
    fa_clock_gate gate (
        .clk_i(clk), .enable_i(gate_enable),
        .test_enable_i(gate_test_enable), .clk_o(gate_clk)
    );
    always @(posedge gate_clk) begin
        gate_rise = $time;
        gate_edges++;
    end
    always @(negedge gate_clk) begin
        if ($time > 10 && $time - gate_rise < 5)
            $fatal(1, "ICG produced a truncated high pulse");
    end
    task automatic test_gate();
        integer initial_edges;
        repeat (3) @(negedge clk);
        gate_enable = 1;
        @(posedge clk);
        #2 gate_enable = 0;
        #1;
        if (gate_clk !== 1)
            $fatal(1, "ICG enable changed clock during high phase");
        repeat (3) @(negedge clk);
        initial_edges = gate_edges;
        repeat (5) @(negedge clk);
        if (gate_edges != initial_edges)
            $fatal(1, "ICG continued clocking while disabled");
        gate_test_enable = 1;
        repeat (3) @(negedge clk);
        if (gate_edges - initial_edges != 3)
            $fatal(1, "ICG test enable did not force the clock open");
        gate_test_enable = 0;
        $display("[PASS] clock_gate idle_high_phase_test_enable");
        gate_done = 1;
    endtask

    initial begin
        fork
            test_mult();
            test_norm();
            test_gate();
        join
        if (!(mult_done && norm_done && gate_done))
            $fatal(1, "focused tests failed to finish");
        $display("[PASS] tb_runtime_arithmetic");
        $finish;
    end
    initial begin
        repeat (1500) @(posedge clk);
        $fatal(1, "focused arithmetic timeout");
    end
endmodule
