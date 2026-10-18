`timescale 1ns/1ps
`include "attention_defines.vh"

// Gate-safe public-interface replay. Q/K/V files are compact head-token-feature bytes.
// This bench is a streaming service model, not a DDR timing model.
module tb_paper_replay;
    reg clk = 0, rst_n = 0;
    reg [31:0] s_axi_awaddr = 0, s_axi_wdata = 0, s_axi_araddr = 0;
    reg s_axi_awvalid = 0, s_axi_wvalid = 0, s_axi_bready = 1;
    reg [3:0] s_axi_wstrb = 15;
    reg s_axi_arvalid = 0, s_axi_rready = 1;
    wire s_axi_awready, s_axi_wready, s_axi_bvalid;
    wire [1:0] s_axi_bresp, s_axi_rresp;
    wire s_axi_arready, s_axi_rvalid;
    wire [31:0] s_axi_rdata;
    reg [1:0] tile_load_kind_i = 0, tile_commit_kind_i = 0;
    reg tile_load_bank_i = 0, tile_commit_bank_i = 0;
    reg [`ATTN_CACHE_ADDR_W-1:0] tile_load_addr_i = 0;
    reg tile_load_half_i = 0, tile_load_valid_i = 0, tile_commit_valid_i = 0;
    reg [127:0] tile_load_data_i = 0;
    wire tile_load_ready_o;
    wire [31:0] m_axi_awaddr;
    wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;
    wire m_axi_awvalid, m_axi_wvalid, m_axi_wlast, m_axi_bready;
    reg m_axi_awready = 1, m_axi_wready = 1, m_axi_bvalid = 0;
    reg [1:0] m_axi_bresp = 0;
    wire [127:0] m_axi_wdata;
    wire [15:0] m_axi_wstrb;
    wire irq_o;
    wire [3:0] debug_state_o;
    wire [21:0] debug_tile_indices_o;

    byte unsigned q_bytes[], k_bytes[], v_bytes[], expected[], observed[];
    bit written[];
    integer n_q, n_kv, heads, active_d, total_bytes;
    integer q_file, k_file, v_file, o_file, count;
    string vector_dir, result_path, saif_path;
    reg [31:0] score_scale, out_scale;
    longint unsigned cycles = 0, start_cycle = 0, stop_cycle = 0;
    longint unsigned loader_beats = 0, output_bytes = 0, output_beats = 0;
    longint unsigned output_bursts = 0, output_responses = 0;
    longint unsigned loader_wait_cycles = 0;
    integer address = 0, beats_remaining = 0, head_stride_bytes;
    integer output_errors = 0, byte_index, offset, compact_offset;
    reg active_window = 0, finished = 0, start_seen = 0;
    reg [3:0] previous_state = 0;
    realtime period_ns = 1.6;
    bit capture_saif;
    bit stop_pending = 0;

    attention_accel_top dut (.*);

    initial begin
        if ($value$plusargs("CLK_PERIOD_NS=%f", period_ns) && period_ns <= 0)
            $fatal(1, "Invalid clock period");
        forever #(period_ns / 2.0) clk = ~clk;
    end

    task automatic load_binary(input string name, ref byte unsigned data[]);
        integer handle, received;
        handle = $fopen({vector_dir, "/", name}, "rb");
        if (!handle)
            $fatal(1, "Cannot open vector %s", name);
        received = $fread(data, handle);
        if (received != data.size())
            $fatal(1, "Wrong vector size %s got=%0d want=%0d", name, received, data.size());
        $fclose(handle);
    endtask

    task automatic write_register(input reg [31:0] addr, input reg [31:0] value);
        bit aw_done, w_done;
        @(negedge clk);
        s_axi_awaddr = addr;
        s_axi_wdata = value;
        s_axi_awvalid = 1;
        s_axi_wvalid = 1;
        aw_done = 0;
        w_done = 0;
        while (!(aw_done && w_done)) begin
            @(posedge clk);
            if (s_axi_awvalid && s_axi_awready)
                aw_done = 1;
            if (s_axi_wvalid && s_axi_wready)
                w_done = 1;
            @(negedge clk);
            if (aw_done)
                s_axi_awvalid = 0;
            if (w_done)
                s_axi_wvalid = 0;
        end
        wait (s_axi_bvalid);
        if (s_axi_bresp !== 0)
            $fatal(1, "AXIL response addr=%h resp=%h", addr, s_axi_bresp);
        @(negedge clk);
    endtask

    task automatic load_tile(input integer kind, input integer bank,
                             input integer head, input integer tile);
        integer token, index;
        for (integer feature = 0; feature < active_d; feature = feature + 1) begin
            for (integer half = 0; half < 2; half = half + 1) begin
                tile_load_kind_i = 2'(kind);
                tile_load_bank_i = 1'(bank);
                tile_load_addr_i = `ATTN_CACHE_ADDR_W'(feature);
                tile_load_half_i = 1'(half);
                tile_load_data_i = 0;
                for (integer lane = 0; lane < 16; lane = lane + 1) begin
                    token = tile * 32 + half * 16 + lane;
                    if (token < (kind == `ATTN_CACHE_Q ? n_q : n_kv)) begin
                        index = (head * (kind == `ATTN_CACHE_Q ? n_q : n_kv) +
                                 token) * active_d + feature;
                        case (kind)
                            `ATTN_CACHE_Q: tile_load_data_i[lane*8 +: 8] = q_bytes[index];
                            `ATTN_CACHE_K: tile_load_data_i[lane*8 +: 8] = k_bytes[index];
                            `ATTN_CACHE_V: tile_load_data_i[lane*8 +: 8] = v_bytes[index];
                        endcase
                    end
                end
                tile_load_valid_i = 1;
                do @(posedge clk); while (!tile_load_ready_o);
                @(negedge clk);
            end
        end
        tile_load_valid_i = 0;
        tile_commit_kind_i = 2'(kind);
        tile_commit_bank_i = 1'(bank);
        tile_commit_valid_i = 1;
        @(negedge clk);
        tile_commit_valid_i = 0;
    endtask

    always @(posedge clk) begin
        cycles = cycles + 1;
        if (rst_n) begin
            if (tile_load_valid_i && tile_load_ready_o)
                loader_beats = loader_beats + 1;
            if (tile_load_valid_i && !tile_load_ready_o)
                loader_wait_cycles = loader_wait_cycles + 1;
            if (debug_state_o == `ATTN_STATE_ERROR)
                $fatal(1, "DUT entered ERROR");
            if (m_axi_awvalid && m_axi_awready) begin
                if (beats_remaining != 0 || m_axi_awsize !== 4 || m_axi_awburst !== 1)
                    $fatal(1, "Invalid or overlapping output burst");
                address = m_axi_awaddr;
                beats_remaining = int'(m_axi_awlen) + 1;
                output_bursts = output_bursts + 1;
            end
            if (m_axi_wvalid && m_axi_wready) begin
                if (beats_remaining <= 0 || m_axi_wlast !== (beats_remaining == 1))
                    $fatal(1, "Output WLAST/AW mismatch");
                for (byte_index = 0; byte_index < 16; byte_index = byte_index + 1) begin
                    if (m_axi_wstrb[byte_index]) begin
                        offset = address + byte_index;
                        if (offset < 0 || offset / head_stride_bytes >= heads ||
                                offset % head_stride_bytes >= n_q * active_d)
                            $fatal(1, "Write outside a head payload %0d", offset);
                        compact_offset = (offset / head_stride_bytes) * n_q * active_d +
                                         offset % head_stride_bytes;
                        if (written[compact_offset])
                            $fatal(1, "Invalid or repeated output byte %0d", offset);
                        if ($isunknown(m_axi_wdata[byte_index*8 +: 8]))
                            $fatal(1, "Unknown output byte %0d", offset);
                        observed[compact_offset] = m_axi_wdata[byte_index*8 +: 8];
                        written[compact_offset] = 1;
                        if (observed[compact_offset] !== expected[compact_offset]) begin
                            if (output_errors < 8)
                                $display("BYTE_MISMATCH %0d got=%h want=%h", offset,
                                    observed[compact_offset], expected[compact_offset]);
                            output_errors = output_errors + 1;
                        end
                        output_bytes = output_bytes + 1;
                    end
                end
                address = address + 16;
                beats_remaining = beats_remaining - 1;
                output_beats = output_beats + 1;
            end
            if (m_axi_bvalid && m_axi_bready) begin
                output_responses = output_responses + 1;
                if (output_bytes == total_bytes) begin
                    stop_cycle = cycles;
                    stop_pending = 1;
                    finished = 1;
                end
            end
        end
        #0.001;
        if (stop_pending) begin
            if (capture_saif) begin
                $toggle_stop();
                $toggle_report(saif_path, 1.0e-9, dut);
            end
            stop_pending = 0;
            active_window = 0;
        end
        if (rst_n && !start_seen && previous_state == `ATTN_STATE_IDLE &&
                debug_state_o == `ATTN_STATE_LOAD_Q) begin
            // The scheduler accepts START on this edge. Public state works on
            // both the RTL and a flattened mapped netlist.
            start_cycle = cycles;
            start_seen = 1;
            active_window = 1;
            if (capture_saif)
                $toggle_start();
            $display("JOB_START cycle=%0d", start_cycle);
        end
        previous_state = debug_state_o;
    end

    always @(posedge clk) begin
        if (!rst_n)
            m_axi_bvalid <= 0;
        else if (m_axi_bvalid && m_axi_bready)
            m_axi_bvalid <= 0;
        else if (m_axi_wvalid && m_axi_wready && m_axi_wlast)
            m_axi_bvalid <= 1;
    end

    initial begin : run
        integer global_q, global_kv, report_handle, observed_handle;
        if (!$value$plusargs("VECTOR_DIR=%s", vector_dir) ||
                !$value$plusargs("RESULT=%s", result_path) ||
                !$value$plusargs("NQ=%d", n_q) || !$value$plusargs("NKV=%d", n_kv) ||
                !$value$plusargs("HEADS=%d", heads) || !$value$plusargs("DIM=%d", active_d) ||
                !$value$plusargs("SCORE_SCALE=%h", score_scale) ||
                !$value$plusargs("OUT_SCALE=%h", out_scale))
            $fatal(1, "Missing replay configuration");
        if (n_q < 1 || n_q > 65535 || n_kv < 1 || n_kv > 65535 ||
                heads < 1 || heads > 16 || active_d < 1 || active_d > 128)
            $fatal(1, "Invalid replay dimensions");
        capture_saif = $test$plusargs("SAIF_ENABLE");
        if (capture_saif) begin
            if (!$value$plusargs("SAIF_FILE=%s", saif_path))
                $fatal(1, "SAIF file missing");
            $set_toggle_region(dut);
        end
        total_bytes = heads * n_q * active_d;
        head_stride_bytes = (n_q * active_d + 15) & ~15;
        q_bytes = new[total_bytes];
        k_bytes = new[heads * n_kv * active_d];
        v_bytes = new[heads * n_kv * active_d];
        expected = new[total_bytes];
        observed = new[total_bytes];
        written = new[total_bytes];
        load_binary("q.bin", q_bytes);
        load_binary("k.bin", k_bytes);
        load_binary("v.bin", v_bytes);
        load_binary("o.bin", expected);
        repeat (8) @(negedge clk);
        rst_n = 1;
        write_register(`ATTN_REG_O_BASE_LO, 0);
        write_register(`ATTN_REG_O_BASE_HI, 0);
        write_register(`ATTN_REG_SEQ_Q, n_q);
        write_register(`ATTN_REG_SEQ_KV, n_kv);
        write_register(`ATTN_REG_NUM_Q_HEADS, heads);
        write_register(`ATTN_REG_HEAD_DIM, active_d);
        write_register(`ATTN_REG_SCORE_SCALE, score_scale);
        write_register(`ATTN_REG_OUT_SCALE, out_scale);
        write_register(`ATTN_REG_PERF_CTRL, 0);
        write_register(`ATTN_REG_CONTROL, 1);
        @(negedge clk);
        global_q = 0;
        global_kv = 0;
        for (integer head = 0; head < heads; head = head + 1) begin
            for (integer qt = 0; qt < (n_q + 31) / 32; qt = qt + 1) begin
                load_tile(`ATTN_CACHE_Q, global_q % 2, head, qt);
                for (integer kt = 0; kt < (n_kv + 31) / 32; kt = kt + 1) begin
                    load_tile(`ATTN_CACHE_K, global_kv % 2, head, kt);
                    load_tile(`ATTN_CACHE_V, global_kv % 2, head, kt);
                    global_kv = global_kv + 1;
                end
                global_q = global_q + 1;
            end
        end
        wait (finished);
        @(negedge clk);
        if (output_errors || output_bytes != total_bytes || !start_seen)
            $fatal(1, "OUTPUT_CHECK errors=%0d bytes=%0d", output_errors, output_bytes);
        report_handle = $fopen(result_path, "w");
        $fdisplay(report_handle, "status,heads,nq,nkv,d,cycles,loader_bytes,output_bytes");
        $fdisplay(report_handle, "pass,%0d,%0d,%0d,%0d,%0d,%0d,%0d", heads, n_q, n_kv,
            active_d, stop_cycle - start_cycle, loader_beats * 16, output_bytes);
        $fclose(report_handle);
        observed_handle = $fopen({result_path, ".observed.bin"}, "wb");
        foreach (observed[index])
            $fwrite(observed_handle, "%c", observed[index]);
        $fclose(observed_handle);
        $display("REPLAY_PASS cycles=%0d start=%0d stop=%0d bytes=%0d loader=%0d wait=%0d",
            stop_cycle - start_cycle, start_cycle, stop_cycle, output_bytes,
            loader_beats * 16, loader_wait_cycles);
        $display("[PASS] tb_paper_replay");
        $finish;
    end

    initial begin
        repeat (64'd3000000000) @(posedge clk);
        $fatal(1, "Replay timeout");
    end
endmodule
