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
    super.configure();
    cfg.stimulus = FA_STIM_RANDOM_SMALL;
    cfg.ready_low_pct = 25;
  endfunction
  virtual task run_sequence();
    fa_random_qkv_vseq seq;
    seq = fa_random_qkv_vseq::type_id::create("random_qkv_seq");
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
  endfunction
  virtual task run_sequence();
    fa_random_qkv_vseq seq;
    seq = fa_random_qkv_vseq::type_id::create("arith_rounding_seq");
    seq.start(env.vseqr);
    if (!env.scoreboard.ref_model.last_event.saw_score_round_increment)
      `uvm_error("ROUNDING", "score-scale guard/sticky rounding corner was not observed")
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

class fa_causal_random_test extends fa_base_test;
  `uvm_component_utils(fa_causal_random_test)
  function new(string name = "fa_causal_random_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function void configure();
    super.configure();
    cfg.stimulus = FA_STIM_RANDOM_SMALL;
    cfg.causal_en = 1;
    cfg.ready_low_pct = 25;
  endfunction
  virtual task run_sequence();
    fa_random_qkv_vseq seq;
    seq = fa_random_qkv_vseq::type_id::create("causal_random_seq");
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
  endfunction
  virtual task run_sequence();
    fa_illegal_config_vseq seq;
    seq = fa_illegal_config_vseq::type_id::create("illegal_config_seq");
    seq.start(env.vseqr);
  endtask
endclass

`endif
