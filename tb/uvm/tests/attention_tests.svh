`ifndef ATTENTION_TESTS_SVH
`define ATTENTION_TESTS_SVH

class fa_base_test extends uvm_test;
  `uvm_component_utils(fa_base_test)
  attention_env env;
  fa_test_cfg cfg;

  function new(string name = "fa_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void configure();
    cfg = fa_test_cfg::type_id::create("cfg");
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    configure();
    uvm_config_db#(fa_test_cfg)::set(this, "*", "cfg", cfg);
    env = attention_env::type_id::create("env", this);
  endfunction

  virtual task run_sequence();
    fa_smoke_vseq seq;
    seq = fa_smoke_vseq::type_id::create("smoke_seq");
    seq.start(env.vseqr);
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    run_sequence();
    phase.drop_objection(this);
  endtask
endclass

class fa_smoke_test extends fa_base_test;
  `uvm_component_utils(fa_smoke_test)
  function new(string name = "fa_smoke_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass

class fa_axi_backpressure_test extends fa_base_test;
  `uvm_component_utils(fa_axi_backpressure_test)
  function new(string name = "fa_axi_backpressure_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function void configure();
    super.configure();
    cfg.ready_low_pct = 50;
  endfunction
endclass

class fa_random_qkv_test extends fa_base_test;
  `uvm_component_utils(fa_random_qkv_test)
  function new(string name = "fa_random_qkv_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function void configure();
    int unsigned value;
    bit seq_q_overridden;
    super.configure();
    cfg.seq_q = 512;
    cfg.seq_kv = 512;
    cfg.stimulus = FA_STIM_RANDOM_FULL_RANGE;
    cfg.ready_low_pct = 0;
    if ($value$plusargs("FA_SEQ_Q=%d", value)) begin
      cfg.seq_q = value;
      seq_q_overridden = 1;
    end
    if ($value$plusargs("FA_SEQ_KV=%d", value))
      cfg.seq_kv = value;
    if ($value$plusargs("FA_READY_LOW_PCT=%d", value))
      cfg.ready_low_pct = value;
    if ($value$plusargs("FA_CAUSAL_EN=%d", value)) begin
      if (value > 1)
        `uvm_fatal("RANDOM_CFG", "+FA_CAUSAL_EN must be 0 or 1")
      cfg.causal_en = value;
    end
    if ($value$plusargs("FA_DECODE_EN=%d", value)) begin
      if (value > 1)
        `uvm_fatal("RANDOM_CFG", "+FA_DECODE_EN must be 0 or 1")
      cfg.decode_en = value;
      if (cfg.decode_en && !seq_q_overridden)
        cfg.seq_q = 1;
    end
    if ($value$plusargs("FA_O_BASE=%h", value))
      cfg.o_base = value;
    if (cfg.seq_q == 0 || cfg.seq_q > FA_MAX_SEQ ||
        cfg.seq_kv == 0 || cfg.seq_kv > FA_MAX_SEQ ||
        cfg.ready_low_pct > 75 || (cfg.decode_en && cfg.seq_q != 1) ||
        (!cfg.decode_en && cfg.seq_q > cfg.seq_kv) || cfg.o_base[3:0] != 0)
      `uvm_fatal("RANDOM_CFG", $sformatf(
        "unsupported random configuration q=%0d kv=%0d decode=%0d ready_low_pct=%0d o_base=%08h; prefill requires q <= kv and O base must be 16-byte aligned",
        cfg.seq_q, cfg.seq_kv, cfg.decode_en, cfg.ready_low_pct, cfg.o_base))
    // Only this workload is an SAIF profile; directed tests retain their
    // ordinary transaction order even when compiled with SAIF code.
    cfg.saif_capture = $test$plusargs("SAIF_ENABLE");
  endfunction
  virtual task run_sequence();
    fa_random_qkv_vseq seq;
    seq = fa_random_qkv_vseq::type_id::create("random_qkv_seq");
    seq.start(env.vseqr);
  endtask
endclass

class fa_multihead_underflow_test extends fa_base_test;
  `uvm_component_utils(fa_multihead_underflow_test)
  function new(string name = "fa_multihead_underflow_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function void configure();
    super.configure();
    cfg.seq_q = 32;
    cfg.seq_kv = 32;
    cfg.num_q_heads = 2;
    cfg.num_kv_heads = 2;
    cfg.stimulus = FA_STIM_RANDOM_FULL_RANGE;
  endfunction
  virtual task run_sequence();
    fa_multihead_underflow_vseq seq;
    seq = fa_multihead_underflow_vseq::type_id::create("multihead_underflow_seq");
    seq.start(env.vseqr);
  endtask
endclass

class fa_pwl_corner_test extends fa_base_test;
  `uvm_component_utils(fa_pwl_corner_test)
  function new(string name = "fa_pwl_corner_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function void configure();
    super.configure();
    cfg.stimulus = FA_STIM_PWL_SEGMENTS;
  endfunction
  virtual task run_sequence();
    fa_random_qkv_vseq seq;
    seq = fa_random_qkv_vseq::type_id::create("pwl_corner_seq");
    seq.start(env.vseqr);
  endtask
endclass

class fa_arith_rounding_test extends fa_base_test;
  `uvm_component_utils(fa_arith_rounding_test)
  function new(string name = "fa_arith_rounding_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function void configure();
    super.configure();
    cfg.stimulus = FA_STIM_ARITH_ROUNDING;
    cfg.score_scale = 32'h0002_0005;
    cfg.out_scale = 32'h000e_2000;
  endfunction
  virtual task run_sequence();
    fa_random_qkv_vseq seq;
    seq = fa_random_qkv_vseq::type_id::create("arith_rounding_seq");
    seq.start(env.vseqr);
    if (!env.scoreboard.ref_model.last_event.saw_score_round_increment)
      `uvm_error("ROUNDING", "score-scale guard/sticky rounding corner was not observed")
    if (!env.scoreboard.ref_model.last_event.saw_normalizer_negative_tie)
      `uvm_error("ROUNDING", "normalizer negative half-tie corner was not observed")
    if (!env.scoreboard.ref_model.last_event.reciprocal_seed_mask[6] ||
        !env.scoreboard.ref_model.last_event.reciprocal_seed_mask[12])
      `uvm_error("RECIPROCAL", $sformatf("required LUT seed indices 6/c not both observed mask=%04h",
                                         env.scoreboard.ref_model.last_event.reciprocal_seed_mask))
  endtask
endclass

class fa_positive_saturation_test extends fa_base_test;
  `uvm_component_utils(fa_positive_saturation_test)
  function new(string name = "fa_positive_saturation_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function void configure();
    super.configure();
    cfg.stimulus = FA_STIM_POSITIVE_SAT;
    cfg.out_scale = 32'h0000_0001;
  endfunction
  virtual task run_sequence();
    fa_random_qkv_vseq seq;
    seq = fa_random_qkv_vseq::type_id::create("positive_saturation_seq");
    seq.start(env.vseqr);
  endtask
endclass

class fa_negative_saturation_test extends fa_base_test;
  `uvm_component_utils(fa_negative_saturation_test)
  function new(string name = "fa_negative_saturation_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function void configure();
    super.configure();
    cfg.stimulus = FA_STIM_NEGATIVE_SAT;
  endfunction
  virtual task run_sequence();
    fa_random_qkv_vseq seq;
    seq = fa_random_qkv_vseq::type_id::create("negative_saturation_seq");
    seq.start(env.vseqr);
  endtask
endclass

class fa_decode_smoke_test extends fa_base_test;
  `uvm_component_utils(fa_decode_smoke_test)
  function new(string name = "fa_decode_smoke_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function void configure();
    super.configure();
    cfg.decode_en = 1;
    cfg.causal_en = 1;
    cfg.seq_q = 1;
    cfg.seq_kv = 32;
  endfunction
  virtual task run_sequence();
    fa_random_qkv_vseq seq;
    seq = fa_random_qkv_vseq::type_id::create("decode_smoke_seq");
    seq.start(env.vseqr);
  endtask
endclass

class fa_decode_illegal_config_test extends fa_base_test;
  `uvm_component_utils(fa_decode_illegal_config_test)
  function new(string name = "fa_decode_illegal_config_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function void configure();
    super.configure();
    cfg.enable_data_check = 0;
    cfg.allow_axil_error_response = 1;
  endfunction
  virtual task run_sequence();
    fa_decode_illegal_config_vseq seq;
    seq = fa_decode_illegal_config_vseq::type_id::create("decode_illegal_config_seq");
    seq.start(env.vseqr);
  endtask
endclass

class fa_illegal_config_test extends fa_base_test;
  `uvm_component_utils(fa_illegal_config_test)
  function new(string name = "fa_illegal_config_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function void configure();
    super.configure();
    cfg.enable_data_check = 0;
    cfg.allow_axil_error_response = 1;
    cfg.allow_tile_protocol_error = 1;
  endfunction
  virtual task run_sequence();
    fa_illegal_config_vseq seq;
    seq = fa_illegal_config_vseq::type_id::create("illegal_config_seq");
    seq.start(env.vseqr);
  endtask
endclass

class fa_register_access_test extends fa_base_test;
  `uvm_component_utils(fa_register_access_test)
  function new(string name = "fa_register_access_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function void configure();
    super.configure();
    cfg.enable_data_check = 0;
    cfg.allow_axil_error_response = 1;
  endfunction
  virtual task run_sequence();
    fa_register_access_vseq seq;
    seq = fa_register_access_vseq::type_id::create("register_access_seq");
    seq.start(env.vseqr);
  endtask
endclass

class fa_axi_bresp_error_test extends fa_base_test;
  `uvm_component_utils(fa_axi_bresp_error_test)
  function new(string name = "fa_axi_bresp_error_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function void configure();
    super.configure();
    cfg.inject_axi_bresp_error = 1;
    cfg.enable_data_check = 0;
    cfg.allow_axil_error_response = 1;
  endfunction
  virtual task run_sequence();
    fa_axi_bresp_error_vseq seq;
    seq = fa_axi_bresp_error_vseq::type_id::create("axi_bresp_error_seq");
    seq.start(env.vseqr);
  endtask
endclass

`endif
