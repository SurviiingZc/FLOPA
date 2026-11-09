`ifndef ATTENTION_SEQUENCES_SVH
`define ATTENTION_SEQUENCES_SVH

class fa_axil_single_seq extends uvm_sequence #(fa_axil_item);
    `uvm_object_utils(fa_axil_single_seq)
    fa_axil_item tr;

    function new(string name = "fa_axil_single_seq");
        super.new(name);
    endfunction

    task body();
        start_item(tr);
        finish_item(tr);
    endtask
endclass

class fa_tile_single_seq extends uvm_sequence #(fa_tile_item);
    `uvm_object_utils(fa_tile_single_seq)
    fa_tile_item tr;

    function new(string name = "fa_tile_single_seq");
        super.new(name);
    endfunction

    task body();
        start_item(tr);
        finish_item(tr);
    endtask
endclass

class fa_attention_base_vseq extends uvm_sequence #(uvm_sequence_item);
    `uvm_object_utils(fa_attention_base_vseq)
    `uvm_declare_p_sequencer(fa_virtual_sequencer)
    fa_test_cfg cfg;
    virtual fa_saif_control_if saif_vif;

    function new(string name = "fa_attention_base_vseq");
        super.new(name);
    endfunction

    task pre_body();
        if (!uvm_config_db#(fa_test_cfg)::get(p_sequencer, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "virtual sequence requires fa_test_cfg")
        if (cfg.saif_capture &&
                !uvm_config_db#(virtual fa_saif_control_if)::get(p_sequencer, "", "saif_vif",
                    saif_vif))
            `uvm_fatal("NOSAIF", "SAIF capture requires fa_saif_control_if")
        if (p_sequencer.status_vif == null)
            `uvm_fatal("NOSTATUS", "virtual sequence requires status_vif for phase-aware loading")
    endtask

    task start_saif_capture();
        if (cfg.saif_capture) begin
            if (!saif_vif.enabled)
                `uvm_fatal("SAIF", "cfg.saif_capture requires +SAIF_ENABLE")
            saif_vif.start_capture();
        end
    endtask

    task stop_saif_capture();
        if (cfg.saif_capture)
            saif_vif.stop_capture();
    endtask

    task axil_write(bit [31:0] addr, bit [31:0] data, bit [3:0] strb = 4'hf);
        fa_axil_item tr;
        fa_axil_single_seq seq;
        tr = fa_axil_item::type_id::create($sformatf("wr_%03h", addr));
        tr.is_read = 0;
        tr.addr = addr;
        tr.data = data;
        tr.strb = strb;
        seq = fa_axil_single_seq::type_id::create($sformatf("wr_seq_%03h", addr));
        seq.tr = tr;
        seq.start(p_sequencer.axil_sqr);
    endtask

    task axil_write_with_resp(input bit [31:0] addr, input bit [31:0] data,
                                output bit [1:0] resp, input bit [3:0] strb = 4'hf,
                                input int unsigned aw_delay_cycles = 0,
                                input int unsigned w_delay_cycles = 0,
                                input int unsigned bready_delay_cycles = 0);
        fa_axil_item tr;
        fa_axil_single_seq seq;
        tr = fa_axil_item::type_id::create($sformatf("wr_rsp_%03h", addr));
        tr.is_read = 0;
        tr.addr = addr;
        tr.data = data;
        tr.strb = strb;
        tr.aw_delay_cycles = aw_delay_cycles;
        tr.w_delay_cycles = w_delay_cycles;
        tr.bready_delay_cycles = bready_delay_cycles;
        seq = fa_axil_single_seq::type_id::create($sformatf("wr_rsp_seq_%03h", addr));
        seq.tr = tr;
        seq.start(p_sequencer.axil_sqr);
        resp = tr.resp;
    endtask

    task axil_read(bit [31:0] addr, output bit [31:0] data, output bit [1:0] resp,
                                input int unsigned ar_delay_cycles = 0,
                                input int unsigned rready_delay_cycles = 0);
        fa_axil_item tr;
        fa_axil_single_seq seq;
        tr = fa_axil_item::type_id::create($sformatf("rd_%03h", addr));
        tr.is_read = 1;
        tr.addr = addr;
        tr.strb = 4'h0;
        tr.ar_delay_cycles = ar_delay_cycles;
        tr.rready_delay_cycles = rready_delay_cycles;
        seq = fa_axil_single_seq::type_id::create($sformatf("rd_seq_%03h", addr));
        seq.tr = tr;
        seq.start(p_sequencer.axil_sqr);
        data = tr.rdata;
        resp = tr.resp;
    endtask

    task load_packed_word(fa_tile_kind_e kind, bit bank, bit [`ATTN_CACHE_ADDR_W-1:0] addr,
                                bit [255:0] data);
        fa_tile_item tr;
        fa_tile_single_seq seq;
        tr = fa_tile_item::type_id::create($sformatf("load_%0d_%0d_%0d", kind, bank, addr));
        tr.kind = kind;
        tr.bank = bank;
        tr.addr = addr;
        tr.data = data;
        tr.is_commit = 0;
        tr.upper_half_only = 0;
        tr.lower_half_only = 0;
        seq = fa_tile_single_seq::type_id::create($sformatf("load_seq_%0d_%0d_%0d", kind, bank,
            addr));
        seq.tr = tr;
        seq.start(p_sequencer.tile_sqr);
    endtask

    task send_single_half(fa_tile_kind_e kind, bit bank, bit [`ATTN_CACHE_ADDR_W-1:0] addr,
                                bit [255:0] data, bit upper);
        fa_tile_item tr;
        fa_tile_single_seq seq;
        tr = fa_tile_item::type_id::create(upper ? "single_upper_half" : "single_lower_half");
        tr.kind = kind;
        tr.bank = bank;
        tr.addr = addr;
        tr.data = data;
        tr.is_commit = 0;
        tr.upper_half_only = upper;
        tr.lower_half_only = !upper;
        seq = fa_tile_single_seq::type_id::create(upper ? "single_upper_half_seq" :
                                "single_lower_half_seq");
        seq.tr = tr;
        seq.start(p_sequencer.tile_sqr);
    endtask

    task send_malformed_upper_half(fa_tile_kind_e kind, bit bank,
                                bit [`ATTN_CACHE_ADDR_W-1:0] addr, bit [255:0] data);
        fa_tile_item tr;
        fa_tile_single_seq seq;
        tr = fa_tile_item::type_id::create("malformed_upper_half");
        tr.kind = kind;
        tr.bank = bank;
        tr.addr = addr;
        tr.data = data;
        tr.is_commit = 0;
        tr.upper_half_only = 1;
        tr.lower_half_only = 0;
        seq = fa_tile_single_seq::type_id::create("malformed_upper_half_seq");
        seq.tr = tr;
        seq.start(p_sequencer.tile_sqr);
    endtask

    task load_word(fa_tile_kind_e kind, bit bank, bit [`ATTN_CACHE_ADDR_W-1:0] addr, bit [7:0]
        value);
        load_packed_word(kind, bank, addr, {32{value}});
    endtask

    task commit_tile(fa_tile_kind_e kind, bit bank);
        fa_tile_item tr;
        fa_tile_single_seq seq;
        tr = fa_tile_item::type_id::create($sformatf("commit_%0d_%0d", kind, bank));
        tr.kind = kind;
        tr.bank = bank;
        tr.addr = '0;
        tr.data = '0;
        tr.is_commit = 1;
        seq = fa_tile_single_seq::type_id::create($sformatf("commit_seq_%0d_%0d", kind, bank));
        seq.tr = tr;
        seq.start(p_sequencer.tile_sqr);
    endtask

    task prepare_tensor();
        cfg.tensor.fill_pattern(cfg.stimulus, cfg.seq_q, cfg.seq_kv);
    endtask

    task load_tensor_tile(fa_tile_kind_e kind, bit bank, int unsigned tile_index,
                                int unsigned head = 0);
        bit [255:0] word;
        int unsigned logical_lane;
        if (tile_index >= ((kind == FA_TILE_Q ? cfg.seq_q : cfg.seq_kv) +
                                (kind == FA_TILE_Q ? `ATTN_TILE_Q : `ATTN_TILE_K) - 1) /
                                (kind == FA_TILE_Q ? `ATTN_TILE_Q : `ATTN_TILE_K))
            `uvm_fatal("TILE_INDEX", $sformatf("logical tile %0d exceeds configured %s length",
                                tile_index, kind == FA_TILE_Q ? "Q" : "KV"))
        for (int unsigned addr = 0; addr < cfg.head_dim; addr++) begin
            word = '0;
            for (int unsigned lane = 0; lane < `ATTN_ARRAY_ROWS; lane++) begin
                logical_lane = tile_index * `ATTN_ARRAY_ROWS + lane;
                case (kind)
                    FA_TILE_Q: word[lane*8 +: 8] = cfg.tensor.value_at(FA_TILE_Q, head,
                        logical_lane, addr);
                    FA_TILE_K: word[lane*8 +: 8] = cfg.tensor.value_at(FA_TILE_K, head,
                        logical_lane, addr);
                    FA_TILE_V: word[lane*8 +: 8] = cfg.tensor.value_at(FA_TILE_V, head,
                        logical_lane, addr);
                    default: `uvm_fatal("TILE_KIND", $sformatf("unsupported kind %0d", kind))
                endcase
            end
            load_packed_word(kind, bank, addr[`ATTN_CACHE_ADDR_W-1:0], word);
        end
        commit_tile(kind, bank);
    endtask

    task load_kv_tile(bit bank, int unsigned tile_index, int unsigned head = 0);
        load_tensor_tile(FA_TILE_K, bank, tile_index, head);
        load_tensor_tile(FA_TILE_V, bank, tile_index, head);
    endtask

    task load_tensor_tiles();
        int unsigned q_tile_count;
        int unsigned kv_tile_count;
        q_tile_count = (cfg.seq_q + `ATTN_TILE_Q - 1) / `ATTN_TILE_Q;
        kv_tile_count = (cfg.seq_kv + `ATTN_TILE_K - 1) / `ATTN_TILE_K;
        for (int unsigned tile = 0; tile < q_tile_count && tile < 2; tile++)
            load_tensor_tile(FA_TILE_Q, tile % 2, tile);
        for (int unsigned tile = 0; tile < kv_tile_count && tile < 2; tile++)
            load_kv_tile(tile % 2, tile);
    endtask

    task program_supported_job();
        axil_write(`ATTN_REG_O_BASE_LO, cfg.o_base);
        axil_write(`ATTN_REG_O_BASE_HI, 32'd0);
        axil_write(`ATTN_REG_SEQ_Q, cfg.seq_q);
        axil_write(`ATTN_REG_SEQ_KV, cfg.seq_kv);
        axil_write(`ATTN_REG_NUM_Q_HEADS, cfg.num_q_heads);
        axil_write(`ATTN_REG_NUM_KV_HEADS, cfg.num_kv_heads);
        axil_write(`ATTN_REG_HEAD_DIM, cfg.head_dim);
        axil_write(`ATTN_REG_O_STRIDE, cfg.head_dim);
        axil_write(`ATTN_REG_SCORE_SCALE, cfg.score_scale);
        axil_write(`ATTN_REG_OUT_SCALE, cfg.out_scale);
        axil_write(`ATTN_REG_PERF_CTRL, 32'd0);
    endtask

    task start_supported_job();
        axil_write(`ATTN_REG_CONTROL, 32'h0000_0001);
    endtask

    task wait_done_or_error(int unsigned max_polls = 20000);
        bit [31:0] status;
        bit [1:0] resp;
        for (int unsigned poll = 0; poll < max_polls; poll++) begin
            axil_read(`ATTN_REG_STATUS, status, resp);
            if (resp != 2'b00)
                `uvm_fatal("STATUS", $sformatf("status read response %0h", resp))
            if (status[2])
                `uvm_fatal("DUT_ERROR", $sformatf("DUT entered error, status=%08h", status))
            if (status[1])
                return;
        end
        `uvm_fatal("TIMEOUT", "Timed out waiting for DUT done status")
    endtask

    task wait_for_state(bit [3:0] target_state, int unsigned max_cycles = 200000);
        for (int unsigned cycle = 0; cycle < max_cycles; cycle++) begin
            if (p_sequencer.status_vif.debug_state == target_state)
                return;
            @(posedge p_sequencer.status_vif.clk);
        end
        `uvm_fatal("PHASE_TIMEOUT", $sformatf("timed out waiting for scheduler state %0d",
            target_state))
    endtask

endclass
`endif
