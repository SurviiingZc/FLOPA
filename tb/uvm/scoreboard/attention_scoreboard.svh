`ifndef ATTENTION_SCOREBOARD_SVH
`define ATTENTION_SCOREBOARD_SVH

class attention_scoreboard extends uvm_component;
    `uvm_component_utils(attention_scoreboard)
    uvm_tlm_analysis_fifo #(fa_axil_item) axil_fifo;
    uvm_tlm_analysis_fifo #(fa_tile_item) tile_fifo;
    uvm_tlm_analysis_fifo #(fa_axi_write_item) write_fifo;
    uvm_analysis_port #(fa_model_event) model_ap;
    attention_ref_model ref_model;
    fa_test_cfg cfg;
    virtual fa_status_if vif;
    int unsigned output_beats;
    int unsigned output_bytes;
    int unsigned q_load_words;
    int unsigned k_load_words;
    int unsigned v_load_words;
    int unsigned completed_jobs;
    longint unsigned checked_bytes;
    longint unsigned start_cycles;
    longint unsigned start_qk;
    longint unsigned start_pv;
    longint unsigned start_norm;
    longint unsigned start_loader_beats;
    bit start_seen;
    bit model_reported;
    bit job_open;
    bit output_seen[int unsigned];

    function new(string name = "attention_scoreboard", uvm_component parent = null);
        super.new(name, parent);
        model_ap = new("model_ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        axil_fifo = new("axil_fifo", this);
        tile_fifo = new("tile_fifo", this);
        write_fifo = new("write_fifo", this);
        ref_model = attention_ref_model::type_id::create("ref_model");
        if (!uvm_config_db#(fa_test_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "scoreboard requires cfg")
        if (!uvm_config_db#(virtual fa_status_if)::get(this, "", "status_vif", vif))
            `uvm_fatal("NOVIF", "scoreboard requires status_vif")
    endfunction

    function int unsigned q_tiles();
        return (cfg.seq_q + `ATTN_TILE_Q - 1) / `ATTN_TILE_Q;
    endfunction

    function int unsigned kv_tiles();
        return (cfg.seq_kv + `ATTN_TILE_K - 1) / `ATTN_TILE_K;
    endfunction

    function int unsigned head_stride();
        return ((cfg.seq_q * cfg.head_dim + 15) / 16) * 16;
    endfunction

    function void begin_job();
        if (job_open)
            `uvm_fatal("SB_LIFETIME", "new job began before previous job was checked")
        output_beats = 0;
        output_bytes = 0;
        q_load_words = 0;
        k_load_words = 0;
        v_load_words = 0;
        start_seen = 0;
        model_reported = 0;
        output_seen.delete();
        ref_model.golden_valid = 0;
        ref_model.q_loaded = 0;
        ref_model.k_loaded = 0;
        ref_model.v_loaded = 0;
        start_cycles = vif.cycles;
        start_qk = vif.qk_features;
        start_pv = vif.pv_features;
        start_norm = vif.norm_features;
        start_loader_beats = vif.loader_beats;
        job_open = 1;
    endfunction

    function void maybe_calculate_golden();
        if (job_open && start_seen && cfg.enable_reference_model &&
            !ref_model.golden_valid && ref_model.q_loaded &&
            ref_model.k_loaded && ref_model.v_loaded) begin
            ref_model.calculate(cfg);
            if (ref_model.golden_valid && !model_reported) begin
                model_ap.write(ref_model.last_event);
                model_reported = 1;
            end
        end
    endfunction

    function void check_load_payload(fa_tile_item tr, int unsigned count);
        int unsigned tiles_per_head;
        int unsigned logical_tile;
        int unsigned logical_row;
        int unsigned head;
        int unsigned expected_feature;
        byte signed expected_value;
        tiles_per_head = (tr.kind == FA_TILE_Q) ? q_tiles() : q_tiles() * kv_tiles();
        head = count / (tiles_per_head * cfg.head_dim);
        logical_tile = (count / cfg.head_dim) % tiles_per_head;
        if (tr.kind != FA_TILE_Q)
            logical_tile %= kv_tiles();
        expected_feature = count % cfg.head_dim;
        if (tr.addr != expected_feature || head >= cfg.num_q_heads)
            `uvm_error("SB_LOAD_ORDER", $sformatf(
                "kind=%0d count=%0d feature=%0d expected=%0d head=%0d",
                tr.kind, count, tr.addr, expected_feature, head))
        for (int unsigned lane = 0; lane < `ATTN_ARRAY_ROWS; lane++) begin
            logical_row = logical_tile * `ATTN_ARRAY_ROWS + lane;
            expected_value = cfg.tensor.value_at(tr.kind, head, logical_row, tr.addr);
            if ($signed(tr.data[lane*8 +: 8]) !== expected_value)
                `uvm_error("SB_LOAD_DATA", $sformatf(
                    "kind=%0d head=%0d token=%0d feature=%0d expected=%0d actual=%0d",
                    tr.kind, head, logical_row, tr.addr, expected_value,
                    $signed(tr.data[lane*8 +: 8])))
        end
    endfunction

    task consume_axil();
        fa_axil_item tr;
        forever begin
            axil_fifo.get(tr);
            if (tr.resp != 0 && !cfg.allow_axil_error_response)
                `uvm_error("SB_AXIL", $sformatf("response=%0h address=%08h", tr.resp, tr.addr))
            if (job_open && !tr.is_read && tr.addr == `ATTN_REG_CONTROL &&
                tr.data[0] && tr.strb[0] && tr.resp == 0) begin
                start_seen = 1;
                maybe_calculate_golden();
            end
        end
    endtask

    task consume_tile();
        fa_tile_item tr;
        forever begin
            tile_fifo.get(tr);
            if (!tr.is_commit && job_open) begin
                case (tr.kind)
                    FA_TILE_Q: begin
                        check_load_payload(tr, q_load_words);
                        q_load_words++;
                    end
                    FA_TILE_K: begin
                        check_load_payload(tr, k_load_words);
                        k_load_words++;
                    end
                    FA_TILE_V: begin
                        check_load_payload(tr, v_load_words);
                        v_load_words++;
                    end
                endcase
                ref_model.load_word(tr);
                maybe_calculate_golden();
            end
        end
    endtask

    task compare_write_beat(fa_axi_write_item tr);
        int unsigned byte_address;
        int unsigned local_byte;
        int unsigned head;
        bit [7:0] expected_value;
        for (int unsigned lane = 0; lane < 16; lane++) begin
            if (tr.strb[lane]) begin
                byte_address = tr.addr + lane - cfg.o_base;
                head = byte_address / head_stride();
                local_byte = byte_address % head_stride();
                if (tr.addr < cfg.o_base || head >= cfg.num_q_heads ||
                    local_byte >= cfg.seq_q * cfg.head_dim) begin
                    `uvm_error("SB_ADDR", $sformatf(
                        "unexpected valid output byte address=%08h head=%0d local=%0d",
                        tr.addr + lane, head, local_byte))
                end else begin
                    if (output_seen.exists(byte_address))
                        `uvm_error("SB_DUP", $sformatf("duplicate byte=%0d", byte_address))
                    output_seen[byte_address] = 1;
                    expected_value = ref_model.expected_byte(head, local_byte);
                    if (tr.data[lane*8 +: 8] !== expected_value)
                        `uvm_error("SB_DATA", $sformatf(
                            "head=%0d row=%0d d=%0d expected=%0d actual=%0d address=%08h",
                            head, local_byte / cfg.head_dim, local_byte % cfg.head_dim,
                            $signed(expected_value), $signed(tr.data[lane*8 +: 8]),
                            tr.addr + lane))
                end
                output_bytes++;
            end
        end
    endtask

    task consume_write();
        fa_axi_write_item tr;
        forever begin
            write_fifo.get(tr);
            if (!job_open)
                `uvm_error("SB_UNEXPECTED_WRITE", "AXI output occurred outside an accepted job")
            output_beats++;
            if (tr.size != 4 || tr.burst != 1 || tr.strb == 0)
                `uvm_error("SB_AXI", "invalid AXI shape or empty output beat")
            if (cfg.enable_data_check) begin
                if (!ref_model.golden_valid)
                    `uvm_error("SB_MODEL", "output arrived before complete bit-accurate reference")
                else
                    compare_write_beat(tr);
            end
        end
    endtask

    function void check_job();
        int unsigned expected_bytes;
        int unsigned expected_q_words;
        int unsigned expected_kv_words;
        int unsigned expected_features;
        int unsigned expected_norm;
        longint unsigned useful_macs;
        expected_bytes = cfg.num_q_heads * cfg.seq_q * cfg.head_dim;
        expected_q_words = cfg.num_q_heads * q_tiles() * cfg.head_dim;
        expected_kv_words = expected_q_words * kv_tiles();
        expected_features = expected_kv_words;
        expected_norm = cfg.num_q_heads * q_tiles() * 4 * cfg.head_dim;
        useful_macs = 2 * cfg.num_q_heads * cfg.seq_q * cfg.seq_kv * cfg.head_dim;
        if (!job_open || !ref_model.golden_valid || output_bytes != expected_bytes)
            `uvm_error("SB_BYTES", $sformatf(
                "job=%0d golden=%0d bytes=%0d expected=%0d",
                job_open, ref_model.golden_valid, output_bytes, expected_bytes))
        for (int unsigned head = 0; head < cfg.num_q_heads; head++)
            for (int unsigned index = 0; index < cfg.seq_q * cfg.head_dim; index++)
                if (!output_seen.exists(head * head_stride() + index))
                    `uvm_error("SB_MISSING", $sformatf("head=%0d byte=%0d", head, index))
        if (q_load_words != expected_q_words || k_load_words != expected_kv_words ||
            v_load_words != expected_kv_words)
            `uvm_error("SB_LOAD_COUNT", $sformatf(
                "Q/K/V words=%0d/%0d/%0d expected=%0d/%0d/%0d",
                q_load_words, k_load_words, v_load_words,
                expected_q_words, expected_kv_words, expected_kv_words))
        if (vif.loader_beats - start_loader_beats !=
            2 * (expected_q_words + 2 * expected_kv_words))
            `uvm_error("SB_LOADER_BEATS", "actual accepted loader beat count is incorrect")
        if (vif.qk_features - start_qk != expected_features ||
            vif.pv_features - start_pv != expected_features ||
            vif.norm_features - start_norm != expected_norm)
            `uvm_error("SB_FEATURES", $sformatf(
                "QK/PV/norm issues=%0d/%0d/%0d expected=%0d/%0d/%0d",
                vif.qk_features - start_qk, vif.pv_features - start_pv,
                vif.norm_features - start_norm, expected_features,
                expected_features, expected_norm))
        completed_jobs++;
        checked_bytes += output_bytes;
        `uvm_info("RUNTIME_JOB", $sformatf(
            {"job=%0d d=%0d q=%0d kv=%0d heads=%0d bytes=%0d cycles=%0d ",
             "qk=%0d pv=%0d norm=%0d useful_macs=%0d loader_beats=%0d"},
            completed_jobs, cfg.head_dim, cfg.seq_q, cfg.seq_kv, cfg.num_q_heads,
            output_bytes, vif.cycles - start_cycles, vif.qk_features - start_qk,
            vif.pv_features - start_pv, vif.norm_features - start_norm,
            useful_macs, vif.loader_beats - start_loader_beats), UVM_LOW)
        job_open = 0;
    endfunction

    function void abandon_reset_job();
        job_open = 0;
        ref_model.golden_valid = 0;
        output_seen.delete();
    endfunction

    task run_phase(uvm_phase phase);
        fork
            consume_axil();
            consume_tile();
            consume_write();
        join
    endtask

    function void report_phase(uvm_phase phase);
        if (job_open)
            `uvm_error("SB_INCOMPLETE", "a job was not completed and checked")
        `uvm_info("SB_SUMMARY", $sformatf(
            "completed_jobs=%0d checked_bytes=%0d", completed_jobs, checked_bytes), UVM_LOW)
    endfunction
endclass
`endif
