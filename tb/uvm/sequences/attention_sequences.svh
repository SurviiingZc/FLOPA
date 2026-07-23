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

  function new(string name = "fa_attention_base_vseq");
    super.new(name);
  endfunction

  task pre_body();
    if (!uvm_config_db#(fa_test_cfg)::get(p_sequencer, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "virtual sequence requires fa_test_cfg")
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

  task load_tensor_tiles();
    bit [255:0] q_word;
    bit [255:0] k_word;
    bit [255:0] v_word;
    for (int unsigned addr = 0; addr < cfg.head_dim; addr++) begin
      q_word = '0;
      k_word = '0;
      v_word = '0;
      for (int unsigned lane = 0; lane < `ATTN_ARRAY_ROWS; lane++) begin
        q_word[lane*8 +: 8] = cfg.tensor.q[lane][addr];
        k_word[lane*8 +: 8] = cfg.tensor.k[lane][addr];
        v_word[lane*8 +: 8] = cfg.tensor.v[lane][addr];
      end
      load_packed_word(FA_TILE_Q, 0, addr[5:0], q_word);
      load_packed_word(FA_TILE_K, 0, addr[5:0], k_word);
      load_packed_word(FA_TILE_V, 0, addr[5:0], v_word);
    end
    commit_tile(FA_TILE_Q, 0);
    commit_tile(FA_TILE_K, 0);
    commit_tile(FA_TILE_V, 0);
  endtask

  task program_supported_prefill();
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

  task start_supported_prefill();
    // start + prefill; the currently implemented MHA mode supports causal mask.
    axil_write(`ATTN_REG_CONTROL,
               32'h0000_0041 | (cfg.causal_en ? 32'h0000_0020 : 32'd0));
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
endclass

class fa_smoke_vseq extends fa_attention_base_vseq;
  `uvm_object_utils(fa_smoke_vseq)
  function new(string name = "fa_smoke_vseq");
    super.new(name);
  endfunction

  task body();
    prepare_tensor();
    load_tensor_tiles();
    program_supported_prefill();
    start_supported_prefill();
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
    load_tensor_tiles();
    program_supported_prefill();
    start_supported_prefill();
    wait_done_or_error();
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
    start_supported_prefill();
    axil_read(`ATTN_REG_STATUS, status, resp);
    if (resp != 2'b00 || !status[2])
      `uvm_error("NEGATIVE", $sformatf("illegal config did not set error status=%08h resp=%0h", status, resp))
    axil_write(`ATTN_REG_CONTROL, 32'h0000_0008);
  endtask
endclass

`endif
