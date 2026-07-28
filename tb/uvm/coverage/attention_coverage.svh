`ifndef ATTENTION_COVERAGE_SVH
`define ATTENTION_COVERAGE_SVH

class fa_axil_coverage extends uvm_subscriber #(fa_axil_item);
  `uvm_component_utils(fa_axil_coverage)
  fa_axil_item tr;

  covergroup cg;
    option.per_instance = 1;
    cp_direction: coverpoint tr.is_read { bins write = {0}; bins read = {1}; }
    cp_addr: coverpoint tr.addr iff (!tr.is_read) {
      bins control = {`ATTN_REG_CONTROL};
      bins status_cfg[] = {`ATTN_REG_SEQ_Q, `ATTN_REG_SEQ_KV, `ATTN_REG_HEAD_DIM,
                           `ATTN_REG_TILE_Q, `ATTN_REG_TILE_K};
      bins scale_cfg[] = {`ATTN_REG_SCORE_SCALE, `ATTN_REG_VALUE_SCALE, `ATTN_REG_OUT_SCALE};
      bins perf_cfg = {`ATTN_REG_PERF_CTRL};
      bins other = default;
    }
    cp_resp: coverpoint tr.resp {
      bins okay = {2'b00};
      bins slverr = {2'b10};
      // AXI4-Lite has no EXOKAY response and accel_regfile only emits OKAY/SLVERR.
      illegal_bins reserved = {2'b01, 2'b11};
    }
    direction_x_addr: cross cp_direction, cp_addr {
      // cp_addr is intentionally sampled only for writes.
      ignore_bins read_unsampled = binsof(cp_direction.read);
    }
  endgroup

  function new(string name = "fa_axil_coverage", uvm_component parent = null);
    super.new(name, parent);
    cg = new();
  endfunction

  function void write(fa_axil_item t);
    tr = t;
    cg.sample();
  endfunction
endclass

class fa_tile_coverage extends uvm_subscriber #(fa_tile_item);
  `uvm_component_utils(fa_tile_coverage)
  fa_tile_item tr;
  virtual fa_status_if status_vif;
  bit [3:0] state;

  covergroup cg;
    option.per_instance = 1;
    cp_kind: coverpoint tr.kind { bins q = {FA_TILE_Q}; bins k = {FA_TILE_K}; bins v = {FA_TILE_V}; }
    cp_bank: coverpoint tr.bank { bins bank0 = {0}; bins bank1 = {1}; }
    cp_action: coverpoint tr.is_commit { bins load = {0}; bins commit = {1}; }
    cp_addr: coverpoint tr.addr iff (!tr.is_commit) {
      bins first = {0};
      bins middle = {[1:62]};
      bins last = {63};
    }
    kind_x_bank_x_action: cross cp_kind, cp_bank, cp_action;
    cp_prefetch_phase: coverpoint {tr.kind, state} iff (!tr.is_commit) {
      bins q_preload = {{FA_TILE_Q, `ATTN_STATE_IDLE}};
      bins k_preload = {{FA_TILE_K, `ATTN_STATE_IDLE}};
      bins v_preload = {{FA_TILE_V, `ATTN_STATE_IDLE}};
      bins q_refill_after_last_qk = {
        {FA_TILE_Q, `ATTN_STATE_SOFTMAX}, {FA_TILE_Q, `ATTN_STATE_PV},
        {FA_TILE_Q, `ATTN_STATE_WRITEBACK}
      };
      bins k_refill_after_qk = {
        {FA_TILE_K, `ATTN_STATE_SOFTMAX}, {FA_TILE_K, `ATTN_STATE_PV},
        {FA_TILE_K, `ATTN_STATE_LOAD_KV}, {FA_TILE_K, `ATTN_STATE_QK}
      };
      bins v_refill_after_pv = {
        {FA_TILE_V, `ATTN_STATE_LOAD_KV}, {FA_TILE_V, `ATTN_STATE_QK},
        {FA_TILE_V, `ATTN_STATE_SOFTMAX}, {FA_TILE_V, `ATTN_STATE_PV},
        {FA_TILE_V, `ATTN_STATE_WRITEBACK}
      };
    }
  endgroup

  function new(string name = "fa_tile_coverage", uvm_component parent = null);
    super.new(name, parent);
    cg = new();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual fa_status_if)::get(this, "", "status_vif", status_vif))
      `uvm_fatal("NOSTATUS", "fa_tile_coverage requires status_vif")
  endfunction

  function void write(fa_tile_item t);
    tr = t;
    state = status_vif.debug_state;
    cg.sample();
  endfunction
endclass

class fa_axi_write_coverage extends uvm_subscriber #(fa_axi_write_item);
  `uvm_component_utils(fa_axi_write_coverage)
  fa_axi_write_item tr;

  covergroup cg;
    option.per_instance = 1;
    cp_burst_len: coverpoint tr.burst_len { bins one_beat = {0}; bins full_16 = {15}; bins other = default; }
    cp_size: coverpoint tr.size { bins bytes16 = {3'd4}; bins unexpected = default; }
    cp_burst: coverpoint tr.burst { bins incr = {2'b01}; bins other = default; }
    cp_last: coverpoint tr.last { bins middle = {0}; bins last = {1}; }
    cp_strobe: coverpoint tr.strb { bins full = {16'hffff}; bins partial = default; }
    length_x_last: cross cp_burst_len, cp_last {
      // AWLEN=0 denotes a one-beat AXI burst, whose only W beat is WLAST.
      ignore_bins one_beat_middle = binsof(cp_burst_len.one_beat) &&
                                    binsof(cp_last.middle);
    }
  endgroup

  function new(string name = "fa_axi_write_coverage", uvm_component parent = null);
    super.new(name, parent);
    cg = new();
  endfunction

  function void write(fa_axi_write_item t);
    tr = t;
    cg.sample();
  endfunction
endclass

class fa_phase_coverage extends uvm_component;
  `uvm_component_utils(fa_phase_coverage)
  virtual fa_status_if vif;
  bit [3:0] state;
  bit irq;

  covergroup cg;
    option.per_instance = 1;
    cp_state: coverpoint state {
      bins idle = {`ATTN_STATE_IDLE};
      bins load_q = {`ATTN_STATE_LOAD_Q};
      bins load_kv = {`ATTN_STATE_LOAD_KV};
      bins qk = {`ATTN_STATE_QK};
      bins softmax = {`ATTN_STATE_SOFTMAX};
      bins pv = {`ATTN_STATE_PV};
      bins writeback = {`ATTN_STATE_WRITEBACK};
      bins done = {`ATTN_STATE_DONE};
      bins error = {`ATTN_STATE_ERROR};
    }
    cp_irq: coverpoint irq { bins low = {0}; bins high = {1}; }
    state_x_irq: cross cp_state, cp_irq {
      // irq_o is registered from scheduler done/error; only terminal states
      // can be high, and terminal states cannot retain a low IRQ.
      ignore_bins done_low = binsof(cp_state.done) && binsof(cp_irq.low);
      ignore_bins error_low = binsof(cp_state.error) && binsof(cp_irq.low);
      ignore_bins nonterminal_high = binsof(cp_irq.high) &&
        (binsof(cp_state.idle) || binsof(cp_state.load_q) ||
         binsof(cp_state.load_kv) || binsof(cp_state.qk) ||
         binsof(cp_state.softmax) || binsof(cp_state.pv) ||
         binsof(cp_state.writeback));
    }
  endgroup

  function new(string name = "fa_phase_coverage", uvm_component parent = null);
    super.new(name, parent);
    cg = new();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual fa_status_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "fa_phase_coverage requires virtual interface status_vif")
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.clk);
      if (vif.rst_n) begin
        state = vif.debug_state;
        irq = vif.irq;
        cg.sample();
      end
    end
  endtask
endclass

class fa_math_coverage extends uvm_subscriber #(fa_model_event);
  `uvm_component_utils(fa_math_coverage)
  fa_model_event tr;

  covergroup cg;
    option.per_instance = 1;
    cp_stimulus: coverpoint tr.stimulus {
      bins canonical = {FA_STIM_CANONICAL};
      bins random_full_range = {FA_STIM_RANDOM_FULL_RANGE};
      bins pwl_segments = {FA_STIM_PWL_SEGMENTS};
      bins arith_rounding = {FA_STIM_ARITH_ROUNDING};
      bins positive_sat = {FA_STIM_POSITIVE_SAT};
      bins negative_sat = {FA_STIM_NEGATIVE_SAT};
    }
    cp_mode: coverpoint tr.decode_en { bins prefill = {0}; bins decode = {1}; }
    cp_tile_shape: coverpoint {tr.multi_q_tile, tr.multi_kv_tile} {
      bins one_by_one = {2'b00};
      bins one_by_many = {2'b01};
      // Prefill Q > KV is rejected by fa_random_qkv_test and is outside the
      // supported workload contract.
      ignore_bins many_by_one = {2'b10};
      bins two_by_two = {2'b11};
    }
    cp_q_tile_count: coverpoint tr.q_tile_count {
      bins one = {1};
      bins two = {2};
      bins mid_tiles = {[3:8]};
      bins long = {[9:16]};
    }
    cp_kv_tile_count: coverpoint tr.kv_tile_count {
      bins one = {1};
      bins two = {2};
      bins mid_tiles = {[3:8]};
      bins long = {[9:16]};
    }
    cp_tail_shape: coverpoint {tr.q_tail_tile, tr.kv_tail_tile} {
      bins aligned = {2'b00};
      bins q_tail = {2'b10};
      bins kv_tail = {2'b01};
      bins both_tail = {2'b11};
    }
    cp_write_backpressure: coverpoint tr.write_backpressured {
      bins unstalled = {0};
      bins stalled = {1};
    }
    cp_input_domain: coverpoint {tr.saw_q_negative, tr.saw_q_zero, tr.saw_q_positive,
                                 tr.saw_k_negative, tr.saw_k_zero, tr.saw_k_positive,
                                 tr.saw_v_negative, tr.saw_v_zero, tr.saw_v_positive} {
      bins full_int8_sign_domain = {9'b111_111_111};
      bins directed_or_degenerate = default;
    }
    cp_causal: coverpoint tr.causal_en { bins disabled = {0}; bins enabled = {1}; }
    cp_pwl_segment: coverpoint tr.pwl_segment_mask {
      wildcard bins seg0 = {8'b???????1};
      wildcard bins seg1 = {8'b??????1?};
      wildcard bins seg2 = {8'b?????1??};
      wildcard bins seg3 = {8'b????1???};
      wildcard bins seg4 = {8'b???1????};
      wildcard bins seg5 = {8'b??1?????};
      wildcard bins seg6 = {8'b?1??????};
      wildcard bins seg7 = {8'b1???????};
    }
    cp_exp_zero: coverpoint tr.saw_exp_zero { bins no = {0}; bins yes = {1}; }
    cp_exp_one: coverpoint tr.saw_exp_one {
      bins yes = {1};
      // Every valid softmax row contains a max lane, so exp(score-max)=exp(0).
      ignore_bins no = {0};
    }
    cp_score_sat: coverpoint {tr.saw_score_pos_sat, tr.saw_score_neg_sat} {
      bins none = {2'b00};
      bins negative = {2'b01};
      // score_scale_pipe receives score-max or m_old-m_new, both <= 0.
      ignore_bins positive_or_both = {2'b10, 2'b11};
    }
    cp_score_round: coverpoint tr.saw_score_round_increment { bins no = {0}; bins yes = {1}; }
    cp_normalizer_round: coverpoint tr.saw_normalizer_round_increment { bins no = {0}; bins yes = {1}; }
    cp_output_sat: coverpoint {tr.saw_output_pos_sat, tr.saw_output_neg_sat} {
      bins none = {2'b00}; bins positive = {2'b10}; bins negative = {2'b01}; bins both = {2'b11};
    }
    cp_valid_lanes: coverpoint tr.valid_lanes {
      bins full = {1024};
      bins causal = {528};
      bins decode_full_context = {32};
      bins two_tile_full = {4096};
      bins decode_long_context = {256};
      bins long_prefill_causal = {131328}; // 512 * 513 / 2
      bins other = default;
    }
    mode_x_causal: cross cp_mode, cp_causal;
  endgroup

  function new(string name = "fa_math_coverage", uvm_component parent = null);
    super.new(name, parent);
    cg = new();
  endfunction

  function void write(fa_model_event t);
    tr = t;
    cg.sample();
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("FCOV_MATH", $sformatf("math functional coverage = %0.2f%%", cg.get_inst_coverage()), UVM_LOW)
  endfunction
endclass

`endif
