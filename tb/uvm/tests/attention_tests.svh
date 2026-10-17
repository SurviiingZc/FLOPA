`ifndef ATTENTION_TESTS_SVH
`define ATTENTION_TESTS_SVH

class fa_base_test extends uvm_test;
    `uvm_component_utils(fa_base_test)
    attention_env env;
    fa_test_cfg cfg;
    string scenario;

    function new(string name = "fa_base_test", uvm_component parent = null);
        super.new(name, parent);
        scenario = "single";
    endfunction

    virtual function void configure();
        int unsigned value;
        cfg = fa_test_cfg::type_id::create("cfg");
        cfg.seq_q = 3;
        cfg.seq_kv = 5;
        cfg.head_dim = 64;
        cfg.num_q_heads = 1;
        cfg.num_kv_heads = 1;
        cfg.stimulus = FA_STIM_RANDOM_FULL_RANGE;
        cfg.score_scale = 32'h0008_0001;
        cfg.ready_low_pct = 50;
        cfg.o_base = 32'h0000_0ff0;
        if ($value$plusargs("FA_HEAD_DIM=%d", value)) cfg.head_dim = value;
        if ($value$plusargs("FA_HEADS=%d", value)) cfg.num_q_heads = value;
        if ($value$plusargs("FA_SEQ_Q=%d", value)) cfg.seq_q = value;
        if ($value$plusargs("FA_SEQ_KV=%d", value)) cfg.seq_kv = value;
        if ($value$plusargs("FA_READY_LOW_PCT=%d", value)) cfg.ready_low_pct = value;
        if ($value$plusargs("FA_SCORE_SCALE=%h", value)) cfg.score_scale = value;
        if ($value$plusargs("FA_OUT_SCALE=%h", value)) cfg.out_scale = value;
        if ($value$plusargs("FA_O_BASE=%h", value)) cfg.o_base = value;
        if (cfg.head_dim == 0 || cfg.head_dim > `ATTN_HEAD_DIM ||
            cfg.seq_q == 0 || cfg.seq_q > FA_MAX_SEQ ||
            cfg.seq_kv == 0 || cfg.seq_kv > FA_MAX_SEQ ||
            cfg.num_q_heads == 0 || cfg.num_q_heads > FA_MAX_HEADS ||
            cfg.o_base[3:0] != 0 || cfg.ready_low_pct > 75)
            `uvm_fatal("TEST_CFG", "invalid runtime-d test command line")
        cfg.num_kv_heads = cfg.num_q_heads;
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        configure();
        uvm_config_db#(fa_test_cfg)::set(this, "*", "cfg", cfg);
        env = attention_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
        fa_runtime_d_vseq seq;
        phase.raise_objection(this);
        seq = fa_runtime_d_vseq::type_id::create("runtime_sequence");
        seq.scenario = scenario;
        seq.start(env.vseqr);
        phase.drop_objection(this);
    endtask
endclass

class fa_smoke_test extends fa_base_test;
    `uvm_component_utils(fa_smoke_test)
    function new(string name = "fa_smoke_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
endclass

class fa_random_qkv_test extends fa_base_test;
    `uvm_component_utils(fa_random_qkv_test)
    function new(string name = "fa_random_qkv_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
endclass

class fa_axi_backpressure_test extends fa_base_test;
    `uvm_component_utils(fa_axi_backpressure_test)
    function new(string name = "fa_axi_backpressure_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
endclass

class fa_runtime_d_smoke_test extends fa_base_test;
    `uvm_component_utils(fa_runtime_d_smoke_test)
    function new(string name = "fa_runtime_d_smoke_test", uvm_component parent = null);
        super.new(name, parent);
        scenario = "switch";
    endfunction
endclass

class fa_runtime_d_range_test extends fa_base_test;
    `uvm_component_utils(fa_runtime_d_range_test)
    function new(string name = "fa_runtime_d_range_test", uvm_component parent = null);
        super.new(name, parent);
        scenario = "range";
    endfunction
endclass

class fa_runtime_d_boundary_test extends fa_base_test;
    `uvm_component_utils(fa_runtime_d_boundary_test)
    function new(string name = "fa_runtime_d_boundary_test", uvm_component parent = null);
        super.new(name, parent);
        scenario = "boundary";
    endfunction
endclass

class fa_runtime_d_multihead_test extends fa_base_test;
    `uvm_component_utils(fa_runtime_d_multihead_test)
    function new(string name = "fa_runtime_d_multihead_test", uvm_component parent = null);
        super.new(name, parent);
        scenario = "multihead";
    endfunction
endclass

class fa_runtime_d_control_test extends fa_base_test;
    `uvm_component_utils(fa_runtime_d_control_test)
    function new(string name = "fa_runtime_d_control_test", uvm_component parent = null);
        super.new(name, parent);
        scenario = "control";
    endfunction

    virtual function void configure();
        super.configure();
        cfg.allow_axil_error_response = 1;
    endfunction
endclass

class fa_runtime_d_arith_test extends fa_base_test;
    `uvm_component_utils(fa_runtime_d_arith_test)
    function new(string name = "fa_runtime_d_arith_test", uvm_component parent = null);
        super.new(name, parent);
        scenario = "arith";
    endfunction
endclass
`endif
