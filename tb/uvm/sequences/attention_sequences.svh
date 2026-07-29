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
        !uvm_config_db#(virtual fa_saif_control_if)::get(p_sequencer, "", "saif_vif", saif_vif))
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

  task load_packed_word(fa_tile_kind_e kind, bit bank, bit [5:0] addr,
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
    seq = fa_tile_single_seq::type_id::create($sformatf("load_seq_%0d_%0d_%0d", kind, bank, addr));
    seq.tr = tr;
    seq.start(p_sequencer.tile_sqr);
  endtask

  task send_single_half(fa_tile_kind_e kind, bit bank, bit [5:0] addr,
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
                                 bit [5:0] addr, bit [255:0] data);
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

  task load_word(fa_tile_kind_e kind, bit bank, bit [5:0] addr, bit [7:0] value);
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

  task load_tensor_tile(fa_tile_kind_e kind, bit bank, int unsigned tile_index);
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
          FA_TILE_Q: word[lane*8 +: 8] = cfg.tensor.q[logical_lane][addr];
          FA_TILE_K: word[lane*8 +: 8] = cfg.tensor.k[logical_lane][addr];
          FA_TILE_V: word[lane*8 +: 8] = cfg.tensor.v[logical_lane][addr];
          default: `uvm_fatal("TILE_KIND", $sformatf("unsupported kind %0d", kind))
        endcase
      end
      load_packed_word(kind, bank, addr[5:0], word);
    end
    commit_tile(kind, bank);
  endtask

  task load_kv_tile(bit bank, int unsigned tile_index);
    load_tensor_tile(FA_TILE_K, bank, tile_index);
    load_tensor_tile(FA_TILE_V, bank, tile_index);
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
    axil_write(`ATTN_REG_TILE_Q, cfg.tile_q);
    axil_write(`ATTN_REG_TILE_K, cfg.tile_k);
    axil_write(`ATTN_REG_O_STRIDE, cfg.head_dim);
    axil_write(`ATTN_REG_SCORE_SCALE, cfg.score_scale);
    axil_write(`ATTN_REG_OUT_SCALE, cfg.out_scale);
    axil_write(`ATTN_REG_PERF_CTRL, 32'd0);
  endtask

  task start_supported_job();
    bit [31:0] control;
    control = 32'h0000_0001 |
              (cfg.decode_en ? 32'h0000_0080 : 32'h0000_0040) |
              (cfg.causal_en ? 32'h0000_0020 : 32'd0);
    axil_write(`ATTN_REG_CONTROL, control);
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
    `uvm_fatal("PHASE_TIMEOUT", $sformatf("timed out waiting for scheduler state %0d", target_state))
  endtask

  task wait_for_tile_state(bit [3:0] target_state, int unsigned q_tile,
                           int unsigned kv_tile, int unsigned max_cycles = 500000);
    for (int unsigned cycle = 0; cycle < max_cycles; cycle++) begin
      if (p_sequencer.status_vif.debug_state == target_state &&
          p_sequencer.status_vif.q_tile_index == q_tile &&
          p_sequencer.status_vif.kv_tile_index == kv_tile)
        return;
      @(posedge p_sequencer.status_vif.clk);
    end
    `uvm_fatal("TILE_PHASE_TIMEOUT", $sformatf(
      "timed out waiting for state=%0d q_tile=%0d kv_tile=%0d",
      target_state, q_tile, kv_tile))
  endtask

  task wait_for_kv_tile_index(int unsigned q_tile, int unsigned kv_tile,
                              int unsigned max_cycles = 500000);
    for (int unsigned cycle = 0; cycle < max_cycles; cycle++) begin
      // kv_tile_index advances only after PV has consumed the prior tile, so
      // the opposite bank is safe to refill even if LOAD_KV lasted one cycle.
      if (p_sequencer.status_vif.q_tile_index == q_tile &&
          p_sequencer.status_vif.kv_tile_index == kv_tile)
        return;
      @(posedge p_sequencer.status_vif.clk);
    end
    `uvm_fatal("KV_INDEX_TIMEOUT", $sformatf(
      "timed out waiting for q_tile=%0d kv_tile=%0d; current state=%0d q_tile=%0d kv_tile=%0d",
      q_tile, kv_tile, p_sequencer.status_vif.debug_state,
      p_sequencer.status_vif.q_tile_index, p_sequencer.status_vif.kv_tile_index))
  endtask

  task wait_for_q_tile_index(int unsigned q_tile, int unsigned max_cycles = 500000);
    for (int unsigned cycle = 0; cycle < max_cycles; cycle++) begin
      if (p_sequencer.status_vif.q_tile_index == q_tile)
        return;
      @(posedge p_sequencer.status_vif.clk);
    end
    `uvm_fatal("Q_INDEX_TIMEOUT", $sformatf(
      "timed out waiting for q_tile=%0d; current state=%0d q_tile=%0d kv_tile=%0d",
      q_tile, p_sequencer.status_vif.debug_state,
      p_sequencer.status_vif.q_tile_index, p_sequencer.status_vif.kv_tile_index))
  endtask

  task wait_for_qk_consumed(int unsigned q_tile, int unsigned kv_tile,
                            int unsigned max_cycles = 500000);
    bit [3:0] state;
    for (int unsigned cycle = 0; cycle < max_cycles; cycle++) begin
      state = p_sequencer.status_vif.debug_state;
      if (p_sequencer.status_vif.q_tile_index > q_tile ||
          (p_sequencer.status_vif.q_tile_index == q_tile &&
           (p_sequencer.status_vif.kv_tile_index > kv_tile ||
            (p_sequencer.status_vif.kv_tile_index == kv_tile &&
             (state == `ATTN_STATE_SOFTMAX || state == `ATTN_STATE_PV ||
              state == `ATTN_STATE_WRITEBACK || state == `ATTN_STATE_DONE)))))
        return;
      @(posedge p_sequencer.status_vif.clk);
    end
    `uvm_fatal("QK_CONSUME_TIMEOUT", $sformatf(
      "timed out waiting for QK consume q_tile=%0d kv_tile=%0d; current state=%0d q_tile=%0d kv_tile=%0d",
      q_tile, kv_tile, p_sequencer.status_vif.debug_state,
      p_sequencer.status_vif.q_tile_index, p_sequencer.status_vif.kv_tile_index))
  endtask

  task wait_for_pv_consumed(int unsigned q_tile, int unsigned kv_tile,
                            int unsigned max_cycles = 500000);
    bit [3:0] state;
    for (int unsigned cycle = 0; cycle < max_cycles; cycle++) begin
      state = p_sequencer.status_vif.debug_state;
      if (p_sequencer.status_vif.q_tile_index > q_tile ||
          (p_sequencer.status_vif.q_tile_index == q_tile &&
           (p_sequencer.status_vif.kv_tile_index > kv_tile ||
            (p_sequencer.status_vif.kv_tile_index == kv_tile &&
             (state == `ATTN_STATE_WRITEBACK || state == `ATTN_STATE_DONE)))))
        return;
      @(posedge p_sequencer.status_vif.clk);
    end
    `uvm_fatal("PV_CONSUME_TIMEOUT", $sformatf(
      "timed out waiting for PV consume q_tile=%0d kv_tile=%0d; current state=%0d q_tile=%0d kv_tile=%0d",
      q_tile, kv_tile, p_sequencer.status_vif.debug_state,
      p_sequencer.status_vif.q_tile_index, p_sequencer.status_vif.kv_tile_index))
  endtask
endclass

class fa_smoke_vseq extends fa_attention_base_vseq;
  `uvm_object_utils(fa_smoke_vseq)
  function new(string name = "fa_smoke_vseq");
    super.new(name);
  endfunction

  task body();
    prepare_tensor();
    load_tensor_tiles();
    program_supported_job();
    start_supported_job();
    wait_done_or_error();
  endtask
endclass

class fa_random_qkv_vseq extends fa_attention_base_vseq;
  `uvm_object_utils(fa_random_qkv_vseq)
  function new(string name = "fa_random_qkv_vseq");
    super.new(name);
  endfunction

  task body();
    int unsigned q_tile_count;
    int unsigned kv_tile_count;
    int unsigned total_kv_uses;
    prepare_tensor();
    q_tile_count = (cfg.seq_q + `ATTN_TILE_Q - 1) / `ATTN_TILE_Q;
    kv_tile_count = (cfg.seq_kv + `ATTN_TILE_K - 1) / `ATTN_TILE_K;
    if (cfg.saif_capture) begin
      // Program registers before the measured window; capture the tile loads,
      // accelerator execution, output AXI transactions, and backpressure.
      program_supported_job();
      start_saif_capture();
      load_tensor_tiles();
      start_supported_job();
    end else begin
      load_tensor_tiles();
      program_supported_job();
      start_supported_job();
    end

    // Treat all (Q tile, KV tile) computations as one continuous ping-pong
    // stream. Bank parity must not restart at a Q-tile boundary because the RTL
    // bank pointers also continue toggling across that boundary.
    total_kv_uses = q_tile_count * kv_tile_count;
    fork
      begin : q_prefetch_worker
        // Q[t-2] is dead after its final QK, so refill that bank with Q[t].
        for (int unsigned q_tile = 2; q_tile < q_tile_count; q_tile++) begin
          wait_for_qk_consumed(q_tile - 2, kv_tile_count - 1);
          load_tensor_tile(FA_TILE_Q, q_tile % 2, q_tile);
        end
      end
      begin : k_prefetch_worker
        // K[g-2] is dead as soon as QK completes. This moves the 128 K beats
        // ahead of PV instead of placing all 256 K/V beats after PV.
        for (int unsigned global_tile = 2; global_tile < total_kv_uses; global_tile++) begin
          int unsigned source_tile;
          source_tile = global_tile - 2;
          wait_for_qk_consumed(source_tile / kv_tile_count,
                               source_tile % kv_tile_count);
          load_tensor_tile(FA_TILE_K, global_tile % 2,
                           global_tile % kv_tile_count);
        end
      end
      begin : v_prefetch_worker
        // V[g-2] remains live through PV and is refilled immediately afterward.
        for (int unsigned global_tile = 2; global_tile < total_kv_uses; global_tile++) begin
          int unsigned source_tile;
          source_tile = global_tile - 2;
          wait_for_pv_consumed(source_tile / kv_tile_count,
                              source_tile % kv_tile_count);
          load_tensor_tile(FA_TILE_V, global_tile % 2,
                           global_tile % kv_tile_count);
        end
      end
    join
    wait_done_or_error(500000);
    stop_saif_capture();
  endtask
endclass

class fa_multihead_underflow_vseq extends fa_attention_base_vseq;
  `uvm_object_utils(fa_multihead_underflow_vseq)
  function new(string name = "fa_multihead_underflow_vseq");
    super.new(name);
  endfunction

  task body();
    prepare_tensor();
    load_tensor_tile(FA_TILE_Q, 0, 0);
    load_kv_tile(0, 0);
    program_supported_job();
    start_supported_job();

    // Leave all next banks empty at the head boundary. Refill each bank only
    // after its independent release point to cover all pending-switch paths.
    fork
      begin
        wait_for_qk_consumed(0, 0);
        load_tensor_tile(FA_TILE_Q, 1, 0);
      end
      begin
        wait_for_qk_consumed(0, 0);
        load_tensor_tile(FA_TILE_K, 1, 0);
      end
      begin
        wait_for_pv_consumed(0, 0);
        load_tensor_tile(FA_TILE_V, 1, 0);
      end
    join
    wait_done_or_error(500000);
  endtask
endclass

class fa_illegal_config_vseq extends fa_attention_base_vseq;
  `uvm_object_utils(fa_illegal_config_vseq)
  function new(string name = "fa_illegal_config_vseq");
    super.new(name);
  endfunction

  task expect_bad_cfg(bit [31:0] addr, bit [31:0] bad_value,
                      bit [31:0] restore_value, string field_name);
    bit [31:0] status;
    bit [1:0] resp;
    axil_write(addr, bad_value);
    start_supported_job();
    repeat (2) @(posedge p_sequencer.status_vif.clk);
    axil_read(`ATTN_REG_STATUS, status, resp);
    if (resp != 2'b00 || !status[2])
      `uvm_error("NEGATIVE", $sformatf("%s invalid value did not set error status=%08h resp=%0h",
                                       field_name, status, resp))
    axil_write(`ATTN_REG_CONTROL, 32'h0000_0008);
    wait_for_state(`ATTN_STATE_IDLE, 200000);
    axil_write(addr, restore_value);
  endtask

  task expect_bad_control(bit [31:0] control, string case_name);
    bit [31:0] status;
    bit [1:0] resp;
    axil_write(`ATTN_REG_CONTROL, control);
    repeat (2) @(posedge p_sequencer.status_vif.clk);
    axil_read(`ATTN_REG_STATUS, status, resp);
    if (resp != 2'b00 || !status[2])
      `uvm_error("NEGATIVE", $sformatf("%s did not set error status=%08h resp=%0h",
                                       case_name, status, resp))
    axil_write(`ATTN_REG_CONTROL, 32'h0000_0008);
    wait_for_state(`ATTN_STATE_IDLE, 200000);
  endtask

  task check_tile_error_and_reset(string case_name);
    bit [31:0] status;
    bit [1:0] resp;
    wait_for_state(`ATTN_STATE_ERROR, 200000);
    axil_read(`ATTN_REG_STATUS, status, resp);
    if (resp != 2'b00 || !status[2])
      `uvm_error("NEGATIVE", $sformatf("%s did not set error status=%08h resp=%0h",
                                       case_name, status, resp))
    axil_write(`ATTN_REG_CONTROL, 32'h0000_0002);
    wait_for_state(`ATTN_STATE_IDLE, 200000);
  endtask

  task body();
    bit [31:0] status;
    bit [1:0] resp;
    program_supported_job();
    expect_bad_cfg(`ATTN_REG_SEQ_Q, 0, cfg.seq_q, "SEQ_Q");
    expect_bad_cfg(`ATTN_REG_SEQ_KV, 0, cfg.seq_kv, "SEQ_KV");
    expect_bad_cfg(`ATTN_REG_NUM_Q_HEADS, 0, cfg.num_q_heads, "NUM_Q_HEADS");
    expect_bad_cfg(`ATTN_REG_NUM_KV_HEADS, 0, cfg.num_kv_heads, "NUM_KV_HEADS");
    expect_bad_cfg(`ATTN_REG_NUM_Q_HEADS, 2, cfg.num_q_heads, "Q/KV head mismatch");
    expect_bad_cfg(`ATTN_REG_HEAD_DIM, `ATTN_HEAD_DIM-1, cfg.head_dim, "HEAD_DIM");
    expect_bad_cfg(`ATTN_REG_TILE_Q, `ATTN_TILE_Q-1, cfg.tile_q, "TILE_Q");
    expect_bad_cfg(`ATTN_REG_TILE_K, `ATTN_TILE_K-1, cfg.tile_k, "TILE_K");
    expect_bad_cfg(`ATTN_REG_O_BASE_LO, 1, cfg.o_base, "O_BASE alignment");
    expect_bad_control(32'h0000_0051, "unsupported MODE_SEL");
    expect_bad_control(32'h0000_00c1, "prefill/decode simultaneously enabled");

    // A double commit is the integration-visible ping-pong protocol fault.
    commit_tile(FA_TILE_Q, 0);
    commit_tile(FA_TILE_Q, 0);
    check_tile_error_and_reset("duplicate Q tile commit");

    commit_tile(FA_TILE_K, 0);
    commit_tile(FA_TILE_K, 0);
    check_tile_error_and_reset("duplicate K tile commit");

    commit_tile(FA_TILE_V, 0);
    commit_tile(FA_TILE_V, 0);
    check_tile_error_and_reset("duplicate V tile commit");

    // Reuse this negative test for the cache half-word protocol.
    send_malformed_upper_half(FA_TILE_Q, 1, 0, 256'h1);
    check_tile_error_and_reset("missing lower tile half");

    send_single_half(FA_TILE_Q, 0, 0, 256'h11, 0);
    send_single_half(FA_TILE_K, 0, 0, 256'h22, 1);
    check_tile_error_and_reset("tile half kind mismatch");

    send_single_half(FA_TILE_Q, 0, 0, 256'h33, 0);
    send_single_half(FA_TILE_Q, 1, 0, 256'h44, 1);
    check_tile_error_and_reset("tile half bank mismatch");

    send_single_half(FA_TILE_Q, 0, 0, 256'h55, 0);
    send_single_half(FA_TILE_Q, 0, 1, 256'h66, 1);
    check_tile_error_and_reset("tile half address mismatch");

    // A legal START while busy must be rejected independently of bad config.
    prepare_tensor();
    load_tensor_tiles();
    program_supported_job();
    start_supported_job();
    wait_for_state(`ATTN_STATE_QK, 200000);
    axil_write_with_resp(`ATTN_REG_CONTROL, 32'h0000_0041, resp);
    if (resp != 2'b10)
      `uvm_error("NEGATIVE", $sformatf("busy START resp=%0h expected=2", resp))
    axil_read(`ATTN_REG_STATUS, status, resp);
    if (resp != 2'b00 || !status[2])
      `uvm_error("NEGATIVE", $sformatf("busy START did not set sticky error status=%08h resp=%0h",
                                       status, resp))
    axil_write(`ATTN_REG_CONTROL, 32'h0000_0002);
    wait_for_state(`ATTN_STATE_IDLE, 200000);
  endtask
endclass

class fa_decode_illegal_config_vseq extends fa_attention_base_vseq;
  `uvm_object_utils(fa_decode_illegal_config_vseq)
  function new(string name = "fa_decode_illegal_config_vseq");
    super.new(name);
  endfunction

  task body();
    bit [31:0] status;
    bit [1:0] resp;
    axil_write(`ATTN_REG_SEQ_Q, 32'd2);
    axil_write(`ATTN_REG_SEQ_KV, 32'd32);
    axil_write(`ATTN_REG_NUM_Q_HEADS, 32'd1);
    axil_write(`ATTN_REG_NUM_KV_HEADS, 32'd1);
    axil_write(`ATTN_REG_HEAD_DIM, `ATTN_HEAD_DIM);
    axil_write(`ATTN_REG_TILE_Q, `ATTN_TILE_Q);
    axil_write(`ATTN_REG_TILE_K, `ATTN_TILE_K);
    axil_write(`ATTN_REG_CONTROL, 32'h0000_0081);
    repeat (2) @(posedge p_sequencer.status_vif.clk);
    axil_read(`ATTN_REG_STATUS, status, resp);
    if (resp != 2'b00 || !status[2])
      `uvm_error("DECODE_NEGATIVE", $sformatf("decode seq_q=2 did not set error status=%08h resp=%0h", status, resp))
    axil_write(`ATTN_REG_CONTROL, 32'h0000_0008);
  endtask
endclass

class fa_register_access_vseq extends fa_attention_base_vseq;
  `uvm_object_utils(fa_register_access_vseq)
  function new(string name = "fa_register_access_vseq");
    super.new(name);
  endfunction

  task check_read(bit [31:0] addr, bit [31:0] expected, bit check_data = 1'b1);
    bit [31:0] data;
    bit [1:0] resp;
    axil_read(addr, data, resp);
    if (resp != 2'b00)
      `uvm_error("REG_READ", $sformatf("read %03h returned resp=%0h", addr, resp))
    else if (check_data && data !== expected)
      `uvm_error("REG_READ", $sformatf("read %03h expected=%08h actual=%08h", addr, expected, data))
  endtask

  task check_write(bit [31:0] addr, bit [31:0] data, bit [3:0] strb = 4'hf);
    bit [1:0] resp;
    axil_write_with_resp(addr, data, resp, strb);
    if (resp != 2'b00)
      `uvm_error("REG_WRITE", $sformatf("write %03h returned resp=%0h", addr, resp))
  endtask

  task toggle_full_width(bit [31:0] addr);
    check_write(addr, 32'haaaa_aaaa);
    check_read(addr, 32'haaaa_aaaa);
    check_write(addr, 32'h5555_5555);
    check_read(addr, 32'h5555_5555);
  endtask

  task check_reserved_razwi(bit [31:0] addr);
    check_write(addr, 32'haaaa_aaaa);
    check_read(addr, 32'd0);
    check_write(addr, 32'h5555_5555);
    check_read(addr, 32'd0);
  endtask

  task check_timed_write(bit [31:0] addr, bit [31:0] data,
                         int unsigned aw_delay, int unsigned w_delay,
                         int unsigned bready_delay);
    bit [1:0] resp;
    axil_write_with_resp(addr, data, resp, 4'hf,
                         aw_delay, w_delay, bready_delay);
    if (resp != 2'b00)
      `uvm_error("REG_TIMING", $sformatf("timed write %03h returned resp=%0h", addr, resp))
  endtask

  task check_timed_read(bit [31:0] addr, bit [31:0] expected,
                        int unsigned ar_delay, int unsigned rready_delay);
    bit [31:0] data;
    bit [1:0] resp;
    axil_read(addr, data, resp, ar_delay, rready_delay);
    if (resp != 2'b00 || data !== expected)
      `uvm_error("REG_TIMING", $sformatf("timed read %03h expected=%08h actual=%08h resp=%0h",
                                        addr, expected, data, resp))
  endtask

  task body();
    bit [1:0] resp;
    bit [31:0] data;
    check_read(`ATTN_REG_VERSION, 32'h0002_0000);
    check_reserved_razwi(`ATTN_REG_Q_BASE_LO);
    check_reserved_razwi(`ATTN_REG_Q_BASE_HI);
    check_reserved_razwi(`ATTN_REG_K_BASE_LO);
    check_reserved_razwi(`ATTN_REG_K_BASE_HI);
    check_reserved_razwi(`ATTN_REG_V_BASE_LO);
    check_reserved_razwi(`ATTN_REG_V_BASE_HI);
    toggle_full_width(`ATTN_REG_O_BASE_LO);
    toggle_full_width(`ATTN_REG_O_BASE_HI);
    check_reserved_razwi(`ATTN_REG_Q_STRIDE);
    check_reserved_razwi(`ATTN_REG_K_STRIDE);
    check_reserved_razwi(`ATTN_REG_V_STRIDE);
    toggle_full_width(`ATTN_REG_O_STRIDE);
    toggle_full_width(`ATTN_REG_SCORE_SCALE);
    check_reserved_razwi(`ATTN_REG_VALUE_SCALE);
    toggle_full_width(`ATTN_REG_OUT_SCALE);
    check_reserved_razwi(`ATTN_REG_MASK_CFG);
    // Exercise AW-first, W-first, delayed BREADY, delayed AR, and delayed RREADY
    // in this existing register test instead of adding a protocol-only testcase.
    check_timed_write(`ATTN_REG_O_BASE_LO, 32'ha5a5_5a50, 0, 3, 2);
    check_timed_write(`ATTN_REG_O_BASE_HI, 32'h5a5a_a5a5, 3, 0, 2);
    check_timed_read(`ATTN_REG_VERSION, 32'h0002_0000, 2, 3);
    check_write(`ATTN_REG_O_BASE_LO, 32'h0000_0ff0);
    check_write(`ATTN_REG_O_BASE_HI, 32'h0000_0000);
    check_write(`ATTN_REG_O_STRIDE, 32'h0000_0040);
    check_write(`ATTN_REG_SEQ_Q, 32'd32);
    check_write(`ATTN_REG_SEQ_KV, 32'd32);
    check_write(`ATTN_REG_NUM_Q_HEADS, 32'd1);
    check_write(`ATTN_REG_NUM_KV_HEADS, 32'd1);
    check_write(`ATTN_REG_HEAD_DIM, `ATTN_HEAD_DIM);
    check_write(`ATTN_REG_TILE_Q, `ATTN_TILE_Q);
    check_write(`ATTN_REG_TILE_K, `ATTN_TILE_K);
    check_write(`ATTN_REG_MODE, 32'h0000_0004);
    check_write(`ATTN_REG_SCORE_SCALE, 32'h1122_3344);
    check_write(`ATTN_REG_SCORE_SCALE, 32'h0000_aa00, 4'b0010);
    check_read(`ATTN_REG_SCORE_SCALE, 32'h1122_aa44);
    check_write(`ATTN_REG_OUT_SCALE, 32'h000f_0001);
    check_write(`ATTN_REG_PERF_CTRL, 32'h0000_0001);
    check_write(`ATTN_REG_PERF_CTRL, 32'h0000_0000);
    // Byte zero disabled: START/control bits must be ignored without side effects.
    check_write(`ATTN_REG_CONTROL, 32'h0000_0001, 4'b1110);
    check_write(`ATTN_REG_CONTROL, 32'h0000_0001, 4'b0000);
    axil_read(`ATTN_REG_STATUS, data, resp);
    if (resp != 2'b00 || data[2:0] != 3'b000 || !data[3])
      `uvm_error("REG_WRITE", $sformatf("disabled CONTROL byte changed state status=%08h resp=%0h",
                                        data, resp))

    check_read(`ATTN_REG_CONTROL, 32'h0000_0040);
    check_read(`ATTN_REG_STATUS, 32'd0, 1'b0);
    check_read(`ATTN_REG_ERROR_CODE, 32'd0);
    check_read(`ATTN_REG_Q_BASE_LO, 32'd0);
    check_read(`ATTN_REG_Q_BASE_HI, 32'd0);
    check_read(`ATTN_REG_K_BASE_LO, 32'd0);
    check_read(`ATTN_REG_K_BASE_HI, 32'd0);
    check_read(`ATTN_REG_V_BASE_LO, 32'd0);
    check_read(`ATTN_REG_V_BASE_HI, 32'd0);
    check_read(`ATTN_REG_O_BASE_LO, 32'h0000_0ff0);
    check_read(`ATTN_REG_O_BASE_HI, 32'd0);
    check_read(`ATTN_REG_Q_STRIDE, 32'd0);
    check_read(`ATTN_REG_K_STRIDE, 32'd0);
    check_read(`ATTN_REG_V_STRIDE, 32'd0);
    check_read(`ATTN_REG_O_STRIDE, 32'h0000_0040);
    check_read(`ATTN_REG_SEQ_Q, 32'd32);
    check_read(`ATTN_REG_SEQ_KV, 32'd32);
    check_read(`ATTN_REG_NUM_Q_HEADS, 32'd1);
    check_read(`ATTN_REG_NUM_KV_HEADS, 32'd1);
    check_read(`ATTN_REG_HEAD_DIM, `ATTN_HEAD_DIM);
    check_read(`ATTN_REG_TILE_Q, `ATTN_TILE_Q);
    check_read(`ATTN_REG_TILE_K, `ATTN_TILE_K);
    check_read(`ATTN_REG_MODE, 32'h0000_0004);
    check_read(`ATTN_REG_VALUE_SCALE, 32'd0);
    check_read(`ATTN_REG_OUT_SCALE, 32'h000f_0001);
    check_read(`ATTN_REG_MASK_CFG, 32'd0);
    check_read(`ATTN_REG_PERF_CTRL, 32'd0);
    check_read(`ATTN_REG_PERF_CYCLES_LO, 32'd0, 1'b0);
    check_read(`ATTN_REG_PERF_CYCLES_HI, 32'd0, 1'b0);
    check_read(`ATTN_REG_PERF_STALL_LO, 32'd0, 1'b0);
    check_read(`ATTN_REG_PERF_STALL_HI, 32'd0, 1'b0);
    check_read(`ATTN_REG_PERF_MAC_LO, 32'd0, 1'b0);
    check_read(`ATTN_REG_PERF_MAC_HI, 32'd0, 1'b0);
    check_read(`ATTN_REG_PERF_TILES, 32'd0, 1'b0);

    axil_write_with_resp(`ATTN_REG_STATUS, 32'd0, resp);
    if (resp != 2'b10)
      `uvm_error("REG_WRITE", $sformatf("read-only write resp=%0h expected=2", resp))
    axil_read(12'h0fc, data, resp);
    if (resp != 2'b10)
      `uvm_error("REG_READ", $sformatf("unknown read resp=%0h expected=2", resp))
    axil_write_with_resp(12'h0fc, 32'd0, resp);
    if (resp != 2'b10)
      `uvm_error("REG_WRITE", $sformatf("unknown write resp=%0h expected=2", resp))
  endtask
endclass

class fa_axi_bresp_error_vseq extends fa_attention_base_vseq;
  `uvm_object_utils(fa_axi_bresp_error_vseq)
  function new(string name = "fa_axi_bresp_error_vseq");
    super.new(name);
  endfunction

  task body();
    bit [31:0] status;
    bit [1:0] resp;
    prepare_tensor();
    load_tensor_tiles();
    program_supported_job();
    start_supported_job();
    wait_for_state(`ATTN_STATE_QK, 200000);
    axil_write_with_resp(`ATTN_REG_PERF_CTRL, 32'h0000_0001, resp);
    if (resp != 2'b00)
      `uvm_error("AXI_BUSY_CFG", $sformatf("busy PERF_CTRL write resp=%0h expected=0", resp))
    axil_write_with_resp(`ATTN_REG_SEQ_Q, cfg.seq_q, resp);
    if (resp != 2'b10)
      `uvm_error("AXI_BUSY_CFG", $sformatf("busy configuration write resp=%0h expected=2", resp))
    wait_for_state(`ATTN_STATE_ERROR, 200000);
    repeat (2) @(posedge p_sequencer.status_vif.clk);
    axil_read(`ATTN_REG_STATUS, status, resp);
    if (resp != 2'b00 || !status[2])
      `uvm_error("AXI_BRESP", $sformatf("BRESP error did not reach scheduler status=%08h resp=%0h", status, resp))
    axil_write(`ATTN_REG_CONTROL, 32'h0000_0008);
    wait_for_state(`ATTN_STATE_IDLE, 200000);

    // The responder injects one error only. Prove CLEAR_ERROR recovery first.
    load_tensor_tiles();
    start_supported_job();
    wait_for_state(`ATTN_STATE_LOAD_Q, 200000);
    wait_done_or_error(200000);

    // Exercise a true soft reset from DONE, then run again.
    axil_write(`ATTN_REG_CONTROL, 32'h0000_0002);
    wait_for_state(`ATTN_STATE_IDLE, 200000);
    load_tensor_tiles();
    start_supported_job();
    wait_for_state(`ATTN_STATE_LOAD_Q, 200000);
    wait_done_or_error(200000);

    // Finally restart directly from DONE without clearing it first.
    load_tensor_tiles();
    start_supported_job();
    wait_for_state(`ATTN_STATE_LOAD_Q, 200000);
    wait_done_or_error(200000);
    axil_write(`ATTN_REG_CONTROL, 32'h0000_0004);
    wait_for_state(`ATTN_STATE_IDLE, 200000);
  endtask
endclass

`endif
