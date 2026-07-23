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
    cfg.tensor.fill_pattern(cfg.stimulus);
  endtask

  task load_tensor_tile(fa_tile_kind_e kind, bit bank, int unsigned tile_index);
    bit [255:0] word;
    int unsigned logical_lane;
    if (tile_index >= 2)
      `uvm_fatal("TILE_INDEX", $sformatf("unsupported logical tile %0d", tile_index))
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
    load_tensor_tile(FA_TILE_Q, 0, 0);
    load_kv_tile(0, 0);
  endtask

  task program_supported_job();
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
    prepare_tensor();
    if (cfg.saif_capture) begin
      // Program registers before the measured window; capture the tile loads,
      // accelerator execution, output AXI transactions, and backpressure.
      program_supported_job();
      start_saif_capture();
      load_tensor_tiles();
      start_supported_job();
      wait_done_or_error();
      stop_saif_capture();
    end else begin
      load_tensor_tiles();
      program_supported_job();
      start_supported_job();
      wait_done_or_error();
    end
  endtask
endclass

class fa_two_tile_pingpong_vseq extends fa_attention_base_vseq;
  `uvm_object_utils(fa_two_tile_pingpong_vseq)
  function new(string name = "fa_two_tile_pingpong_vseq");
    super.new(name);
  endfunction

  task body();
    if (cfg.decode_en || cfg.seq_q != 2 * `ATTN_TILE_Q ||
        cfg.seq_kv != 2 * `ATTN_TILE_K)
      `uvm_fatal("TWO_TILE_CFG", "two-tile sequence requires prefill seq_q=64 and seq_kv=64")

    prepare_tensor();
    // Exclude one-time AXI-Lite setup but retain every two-tile data movement
    // phase, including the bank refills that exercise the ping-pong control.
    if (cfg.saif_capture) begin
      program_supported_job();
      start_saif_capture();
    end
    // Q0/Q1 occupy separate banks. K/V is consumed per Q tile, so refill a
    // bank only after the first pass has released it.
    load_tensor_tile(FA_TILE_Q, 0, 0);
    load_tensor_tile(FA_TILE_Q, 1, 1);
    load_kv_tile(0, 0);
    load_kv_tile(1, 1);
    if (!cfg.saif_capture)
      program_supported_job();
    start_supported_job();

    wait_for_state(`ATTN_STATE_PV);
    wait_for_state(`ATTN_STATE_LOAD_KV);
    load_kv_tile(0, 0);

    wait_for_state(`ATTN_STATE_WRITEBACK);
    load_kv_tile(1, 1);
    wait_done_or_error(100000);
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
    axil_read(`ATTN_REG_STATUS, status, resp);
    if (resp != 2'b00 || !status[2])
      `uvm_error("NEGATIVE", $sformatf("illegal config did not set error status=%08h resp=%0h", status, resp))
    axil_write(`ATTN_REG_CONTROL, 32'h0000_0008);
  endtask
endclass

class fa_decode_vseq extends fa_attention_base_vseq;
  `uvm_object_utils(fa_decode_vseq)
  function new(string name = "fa_decode_vseq");
    super.new(name);
  endfunction

  task body();
    if (!cfg.decode_en || cfg.seq_q != 1)
      `uvm_fatal("DECODE_CFG", "fa_decode_vseq requires decode_en=1 and seq_q=1")
    prepare_tensor();
    load_tensor_tiles();
    program_supported_job();
    start_supported_job();
    wait_done_or_error();
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
    axil_read(`ATTN_REG_STATUS, status, resp);
    if (resp != 2'b00 || !status[2])
      `uvm_error("DECODE_NEGATIVE", $sformatf("decode seq_q=2 did not set error status=%08h resp=%0h", status, resp))
    axil_write(`ATTN_REG_CONTROL, 32'h0000_0008);
  endtask
endclass

`endif
