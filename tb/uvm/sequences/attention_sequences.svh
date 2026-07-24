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
                            output bit [1:0] resp, input bit [3:0] strb = 4'hf);
    fa_axil_item tr;
    fa_axil_single_seq seq;
    tr = fa_axil_item::type_id::create($sformatf("wr_rsp_%03h", addr));
    tr.is_read = 0;
    tr.addr = addr;
    tr.data = data;
    tr.strb = strb;
    seq = fa_axil_single_seq::type_id::create($sformatf("wr_rsp_seq_%03h", addr));
    seq.tr = tr;
    seq.start(p_sequencer.axil_sqr);
    resp = tr.resp;
  endtask

  task axil_read(bit [31:0] addr, output bit [31:0] data, output bit [1:0] resp);
    fa_axil_item tr;
    fa_axil_single_seq seq;
    tr = fa_axil_item::type_id::create($sformatf("rd_%03h", addr));
    tr.is_read = 1;
    tr.addr = addr;
    tr.strb = 4'h0;
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
    seq = fa_tile_single_seq::type_id::create($sformatf("load_seq_%0d_%0d_%0d", kind, bank, addr));
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
    axil_write(`ATTN_REG_VALUE_SCALE, cfg.value_scale);
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
    int unsigned prefetch_tile;
    int unsigned missing_tile;
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

    // At most two tiles can live in the cache.  Keep tile 0/1 resident before
    // the job starts; every later tile is loaded into the bank released by the
    // scheduler.  This covers arbitrary 32-row chunks up to FA_MAX_SEQ.
    for (int unsigned q_tile = 0; q_tile < q_tile_count; q_tile++) begin
      for (int unsigned kv_tile = 1; kv_tile < kv_tile_count; kv_tile++) begin
        wait_for_kv_tile_index(q_tile, kv_tile);
        if (kv_tile + 1 < kv_tile_count) begin
          load_kv_tile((kv_tile + 1) % 2, kv_tile + 1);
        end else if (!cfg.decode_en && q_tile + 1 < q_tile_count && kv_tile[0]) begin
          // An odd final KV tile consumes bank 1 and releases bank 0, so KV0
          // for the next Q tile can be prefetched immediately.  For an even
          // final tile bank 0 is still active; loading KV1 into bank 1 would
          // let the next Q tile start at KV1 before KV0 is available.
          prefetch_tile = 0;
          load_kv_tile(prefetch_tile[0], prefetch_tile);
        end
      end

      if (!cfg.decode_en && q_tile + 1 < q_tile_count) begin
        wait_for_tile_state(`ATTN_STATE_WRITEBACK, q_tile, kv_tile_count - 1);
        if (kv_tile_count == 1) begin
          load_kv_tile(0, 0);
        end else if ((kv_tile_count - 1) % 2) begin
          // KV0 was prefetched into bank 0 on the final LOAD_KV transition.
          load_kv_tile(1, 1);
        end else begin
          // The final active bank was bank 0.  Keep bank 1 empty until KV0
          // has been committed to bank 0, then restore KV1 for the next loop.
          load_kv_tile(0, 0);
          load_kv_tile(1, 1);
        end
        // q_tile_index is stable after the writeback edge, unlike the
        // single-cycle LOAD_Q state.  At this point the old Q bank is free.
        if (q_tile + 2 < q_tile_count) begin
          wait_for_q_tile_index(q_tile + 1);
          load_tensor_tile(FA_TILE_Q, (q_tile + 2) % 2, q_tile + 2);
        end
      end
    end
    wait_done_or_error(500000);
    stop_saif_capture();
  endtask
endclass

class fa_illegal_config_vseq extends fa_attention_base_vseq;
  `uvm_object_utils(fa_illegal_config_vseq)
  function new(string name = "fa_illegal_config_vseq");
    super.new(name);
  endfunction

  task body();
    bit [31:0] status;
    bit [1:0] resp;
    axil_write(`ATTN_REG_SEQ_Q, 32'd0);
    axil_write(`ATTN_REG_SEQ_KV, 32'd32);
    axil_write(`ATTN_REG_NUM_Q_HEADS, 32'd1);
    axil_write(`ATTN_REG_NUM_KV_HEADS, 32'd1);
    axil_write(`ATTN_REG_HEAD_DIM, `ATTN_HEAD_DIM);
    axil_write(`ATTN_REG_TILE_Q, `ATTN_TILE_Q);
    axil_write(`ATTN_REG_TILE_K, `ATTN_TILE_K);
    start_supported_job();
    repeat (2) @(posedge p_sequencer.status_vif.clk);
    axil_read(`ATTN_REG_STATUS, status, resp);
    if (resp != 2'b00 || !status[2])
      `uvm_error("NEGATIVE", $sformatf("illegal config did not set error status=%08h resp=%0h", status, resp))
    axil_write(`ATTN_REG_CONTROL, 32'h0000_0008);
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

  task body();
    bit [1:0] resp;
    bit [31:0] data;
    check_read(`ATTN_REG_VERSION, 32'h0002_0000);
    check_write(`ATTN_REG_Q_BASE_LO, 32'h0000_1000);
    check_write(`ATTN_REG_Q_BASE_HI, 32'h0000_0000);
    check_write(`ATTN_REG_K_BASE_LO, 32'h0000_2000);
    check_write(`ATTN_REG_K_BASE_HI, 32'h0000_0000);
    check_write(`ATTN_REG_V_BASE_LO, 32'h0000_3000);
    check_write(`ATTN_REG_V_BASE_HI, 32'h0000_0000);
    check_write(`ATTN_REG_O_BASE_LO, 32'h0000_0ff0);
    check_write(`ATTN_REG_O_BASE_HI, 32'h0000_0000);
    check_write(`ATTN_REG_Q_STRIDE, 32'h0000_0040);
    check_write(`ATTN_REG_K_STRIDE, 32'h0000_0040);
    check_write(`ATTN_REG_V_STRIDE, 32'h0000_0040);
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
    check_write(`ATTN_REG_VALUE_SCALE, 32'h0001_0001);
    check_write(`ATTN_REG_OUT_SCALE, 32'h000f_0001);
    check_write(`ATTN_REG_MASK_CFG, 32'h0000_0001);
    check_write(`ATTN_REG_PERF_CTRL, 32'h0000_0001);
    check_write(`ATTN_REG_PERF_CTRL, 32'h0000_0000);

    check_read(`ATTN_REG_CONTROL, 32'h0000_0040);
    check_read(`ATTN_REG_STATUS, 32'd0, 1'b0);
    check_read(`ATTN_REG_ERROR_CODE, 32'd0);
    check_read(`ATTN_REG_Q_BASE_LO, 32'h0000_1000);
    check_read(`ATTN_REG_Q_BASE_HI, 32'd0);
    check_read(`ATTN_REG_K_BASE_LO, 32'h0000_2000);
    check_read(`ATTN_REG_K_BASE_HI, 32'd0);
    check_read(`ATTN_REG_V_BASE_LO, 32'h0000_3000);
    check_read(`ATTN_REG_V_BASE_HI, 32'd0);
    check_read(`ATTN_REG_O_BASE_LO, 32'h0000_0ff0);
    check_read(`ATTN_REG_O_BASE_HI, 32'd0);
    check_read(`ATTN_REG_Q_STRIDE, 32'h0000_0040);
    check_read(`ATTN_REG_K_STRIDE, 32'h0000_0040);
    check_read(`ATTN_REG_V_STRIDE, 32'h0000_0040);
    check_read(`ATTN_REG_O_STRIDE, 32'h0000_0040);
    check_read(`ATTN_REG_SEQ_Q, 32'd32);
    check_read(`ATTN_REG_SEQ_KV, 32'd32);
    check_read(`ATTN_REG_NUM_Q_HEADS, 32'd1);
    check_read(`ATTN_REG_NUM_KV_HEADS, 32'd1);
    check_read(`ATTN_REG_HEAD_DIM, `ATTN_HEAD_DIM);
    check_read(`ATTN_REG_TILE_Q, `ATTN_TILE_Q);
    check_read(`ATTN_REG_TILE_K, `ATTN_TILE_K);
    check_read(`ATTN_REG_MODE, 32'h0000_0004);
    check_read(`ATTN_REG_VALUE_SCALE, 32'h0001_0001);
    check_read(`ATTN_REG_OUT_SCALE, 32'h000f_0001);
    check_read(`ATTN_REG_MASK_CFG, 32'h0000_0001);
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
    wait_for_state(`ATTN_STATE_ERROR, 200000);
    repeat (2) @(posedge p_sequencer.status_vif.clk);
    axil_read(`ATTN_REG_STATUS, status, resp);
    if (resp != 2'b00 || !status[2])
      `uvm_error("AXI_BRESP", $sformatf("BRESP error did not reach scheduler status=%08h resp=%0h", status, resp))
    axil_write(`ATTN_REG_CONTROL, 32'h0000_0008);
    wait_for_state(`ATTN_STATE_IDLE, 200000);
  endtask
endclass

`endif
