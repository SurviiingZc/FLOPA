// Test-only observers; the accelerator RTL and gate jobs are unchanged.
module tb_sram_byte_counter (
    input clk,
    input ceb,
    input web,
    input [7:0] bweb
);
    longint unsigned reads = 0;
    longint unsigned writes = 0;
    string path;
    initial path = $sformatf("%m");
    always @(posedge clk) begin
        if (tb_paper_replay.rst_n && tb_paper_replay.active_window && ceb === 1'b0) begin
            if (web === 1'b0) begin
                if (bweb !== 8'h00)
                    $fatal(1, "Unexpected partial macro write %s", path);
                writes++;
            end else if (web === 1'b1) begin
                reads++;
            end else begin
                $fatal(1, "Unknown active macro WEB %s", path);
            end
        end
    end
    final $display("MEM_TRAFFIC,%s,%0d,%0d", path, reads, writes);
endmodule

bind uhdsp_256x8m4s tb_sram_byte_counter u_byte_traffic (
    .clk(CLK), .ceb(CEB), .web(WEB), .bweb(BWEB)
);

module tb_pe_probability_counter (
    input clk,
    input load,
    input pv,
    input lane_valid
);
    longint unsigned physical_loads = 0;
    longint unsigned useful_loads = 0;
    longint unsigned physical_uses = 0;
    longint unsigned useful_uses = 0;
    always @(posedge clk) begin
        if (tb_paper_replay.rst_n && tb_paper_replay.active_window) begin
            if (load) begin
                physical_loads++;
                if (lane_valid) useful_loads++;
            end
            if (pv) begin
                physical_uses++;
                if (lane_valid) useful_uses++;
            end
        end
    end
    final $display("PE_TRAFFIC,%m,%0d,%0d,%0d,%0d",
        physical_loads, useful_loads, physical_uses, useful_uses);
endmodule

bind fsa_fused_pe tb_pe_probability_counter u_probability_traffic (
    .clk(clk), .load(prob_load_i), .pv(pv_mac_valid_w), .lane_valid(score_lane_valid_i)
);

module tb_probability_column_trace #(
    parameter integer ROWS = 32,
    parameter integer PROB_W = 16,
    parameter integer COL_IDX_W = 5
)(
    input clk,
    input valid,
    input [COL_IDX_W-1:0] column,
    input [ROWS*PROB_W-1:0] data
);
    integer handle;
    integer expected_column = 31;
    longint unsigned tiles = 0;
    string filename;
    initial begin
        if (!$value$plusargs("P_TRACE=%s", filename))
            $fatal(1, "Missing P_TRACE path");
        handle = $fopen(filename, "w");
        if (!handle) $fatal(1, "Cannot open P trace");
    end
    always @(posedge clk) begin
        if (tb_paper_replay.rst_n && tb_paper_replay.active_window && valid) begin
            if (column != expected_column || $isunknown(data))
                $fatal(1, "Invalid P trace column=%0d expected=%0d unknown=%0d",
                       column, expected_column, $isunknown(data));
            $fdisplay(handle, "%0d %0128h", column, data);
            if (column == 0) begin
                expected_column = 31;
                tiles++;
            end else begin
                expected_column--;
            end
        end
    end
    final begin
        if (expected_column != 31) $error("Incomplete P tile at end of trace");
        $fclose(handle);
        $display("P_TRACE_TILES,%0d", tiles);
    end
endmodule

bind fsa_fused_array tb_probability_column_trace #(
    .ROWS(ROWS), .PROB_W(PROB_W), .COL_IDX_W(COL_IDX_W)
) u_probability_trace (
    .clk(array_clk_w), .valid(prob_write_valid_w), .column(prob_write_col_w),
    .data(exp_data_w)
);
