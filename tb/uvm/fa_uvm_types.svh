`ifndef FA_UVM_TYPES_SVH
`define FA_UVM_TYPES_SVH

typedef enum bit [1:0] {
  FA_TILE_Q = `ATTN_CACHE_Q,
  FA_TILE_K = `ATTN_CACHE_K,
  FA_TILE_V = `ATTN_CACHE_V
} fa_tile_kind_e;

typedef enum int unsigned {
  FA_STIM_CANONICAL,
  FA_STIM_RANDOM_FULL_RANGE,
  FA_STIM_PWL_SEGMENTS,
  FA_STIM_ARITH_ROUNDING,
  FA_STIM_POSITIVE_SAT,
  FA_STIM_NEGATIVE_SAT
} fa_stimulus_e;

// UVM uses the architectural 16-bit sequence registers, but caps the
// reference model at 512 tokens so the regression exercises long streaming
// ping-pong traffic without making every smoke test prohibitively expensive.
localparam int unsigned FA_MAX_SEQ = 512;

class fa_qkv_tensor extends uvm_object;
  `uvm_object_utils(fa_qkv_tensor)
  byte signed q [0:FA_MAX_SEQ-1][0:`ATTN_HEAD_DIM-1];
  byte signed k [0:FA_MAX_SEQ-1][0:`ATTN_HEAD_DIM-1];
  byte signed v [0:FA_MAX_SEQ-1][0:`ATTN_HEAD_DIM-1];

  function new(string name = "fa_qkv_tensor");
    super.new(name);
  endfunction

  function void fill_constant(byte signed q_value, byte signed k_value,
                              byte signed v_value);
    for (int unsigned row = 0; row < FA_MAX_SEQ; row++)
      for (int unsigned dim = 0; dim < `ATTN_HEAD_DIM; dim++) begin
        q[row][dim] = q_value;
        k[row][dim] = k_value;
        v[row][dim] = v_value;
      end
  endfunction

  function void fill_random_full_range(int unsigned active_q_rows,
                                       int unsigned active_kv_rows);
    int signed anchor_values [0:5];
    for (int unsigned row = 0; row < FA_MAX_SEQ; row++)
      for (int unsigned dim = 0; dim < `ATTN_HEAD_DIM; dim++) begin
        q[row][dim] = $urandom_range(0, 255) - 128;
        k[row][dim] = $urandom_range(0, 255) - 128;
        v[row][dim] = $urandom_range(0, 255) - 128;
      end

    // Every remaining lane is independently uniform across INT8.  Place six
    // values covering the sign classes and rails on random active rows so
    // every random job also proves that the full input domain reached the DUT.
    anchor_values[0] = -128;
    anchor_values[1] = -64;
    anchor_values[2] = -1;
    anchor_values[3] = 0;
    anchor_values[4] = 1;
    anchor_values[5] = 127;
    for (int unsigned anchor = 0; anchor < 6; anchor++) begin
      q[$urandom_range(0, active_q_rows - 1)][anchor] = anchor_values[anchor];
      k[$urandom_range(0, active_kv_rows - 1)][anchor] = anchor_values[anchor];
      v[$urandom_range(0, active_kv_rows - 1)][anchor] = anchor_values[anchor];
    end
  endfunction

  function void fill_pwl_segments();
    // Q dot K produces score deltas at 256-point boundaries, covering every
    // PWL segment and the x <= -2048 zero-output clamp.
    int signed key_level;
    for (int unsigned row = 0; row < FA_MAX_SEQ; row++)
      for (int unsigned dim = 0; dim < `ATTN_HEAD_DIM; dim++) begin
        q[row][dim] = 8'sd1;
        key_level = 8 - (row * 4);
        if (key_level < -128) key_level = -128;
        k[row][dim] = key_level;
        v[row][dim] = ((row + dim) % 17) - 8;
      end
  endfunction

  function void fill_arith_rounding();
    // The first Q/K feature makes score deltas of 0, -1, -2 and -3. With
    // scale mantissa=5 and shift=2, -1*5 has guard and sticky bits both set.
    for (int unsigned row = 0; row < FA_MAX_SEQ; row++)
      for (int unsigned dim = 0; dim < `ATTN_HEAD_DIM; dim++) begin
        q[row][dim] = (dim == 0) ? 8'sd1 : 8'sd0;
        k[row][dim] = (dim == 0) ? (8'sd2 - (row % 4)) : 8'sd0;
        v[row][dim] = 8'sd1;
      end
  endfunction

  function void fill_score_spread(byte signed value_value);
    // score_scale_pipe consumes score - max.  Drive a positive maximum and a
    // strongly negative lane so the reachable negative clamp is exercised.
    for (int unsigned row = 0; row < FA_MAX_SEQ; row++)
      for (int unsigned dim = 0; dim < `ATTN_HEAD_DIM; dim++) begin
        q[row][dim] = 8'sd127;
        k[row][dim] = (row == 0) ? 8'sd127 : -8'sd128;
        v[row][dim] = value_value;
      end
  endfunction

  function void fill_pattern(fa_stimulus_e stimulus,
                             int unsigned active_q_rows = FA_MAX_SEQ,
                             int unsigned active_kv_rows = FA_MAX_SEQ);
    case (stimulus)
      FA_STIM_CANONICAL: fill_constant(8'sd0, 8'sd0, 8'sd1);
      FA_STIM_RANDOM_FULL_RANGE: fill_random_full_range(active_q_rows, active_kv_rows);
      FA_STIM_PWL_SEGMENTS: fill_pwl_segments();
      FA_STIM_ARITH_ROUNDING: fill_arith_rounding();
      FA_STIM_POSITIVE_SAT: fill_score_spread(8'sd127);
      FA_STIM_NEGATIVE_SAT: fill_score_spread(-8'sd128);
      default: fill_constant(8'sd0, 8'sd0, 8'sd0);
    endcase
  endfunction
endclass

class fa_model_event extends uvm_sequence_item;
  fa_stimulus_e stimulus;
  bit decode_en;
  bit causal_en;
  bit multi_q_tile;
  bit multi_kv_tile;
  bit [7:0] pwl_segment_mask;
  bit saw_exp_zero;
  bit saw_exp_one;
  bit saw_score_pos_sat;
  bit saw_score_neg_sat;
  bit saw_score_round_increment;
  bit saw_normalizer_round_increment;
  bit saw_output_pos_sat;
  bit saw_output_neg_sat;
  bit saw_q_negative;
  bit saw_q_zero;
  bit saw_q_positive;
  bit saw_k_negative;
  bit saw_k_zero;
  bit saw_k_positive;
  bit saw_v_negative;
  bit saw_v_zero;
  bit saw_v_positive;
  bit q_tail_tile;
  bit kv_tail_tile;
  bit write_backpressured;
  int unsigned q_tile_count;
  int unsigned kv_tile_count;
  int unsigned valid_lanes;

  `uvm_object_utils_begin(fa_model_event)
    `uvm_field_enum(fa_stimulus_e, stimulus, UVM_DEFAULT)
    `uvm_field_int(decode_en, UVM_DEFAULT)
    `uvm_field_int(causal_en, UVM_DEFAULT)
    `uvm_field_int(multi_q_tile, UVM_DEFAULT)
    `uvm_field_int(multi_kv_tile, UVM_DEFAULT)
    `uvm_field_int(pwl_segment_mask, UVM_DEFAULT)
    `uvm_field_int(saw_exp_zero, UVM_DEFAULT)
    `uvm_field_int(saw_exp_one, UVM_DEFAULT)
    `uvm_field_int(saw_score_pos_sat, UVM_DEFAULT)
    `uvm_field_int(saw_score_neg_sat, UVM_DEFAULT)
    `uvm_field_int(saw_score_round_increment, UVM_DEFAULT)
    `uvm_field_int(saw_normalizer_round_increment, UVM_DEFAULT)
    `uvm_field_int(saw_output_pos_sat, UVM_DEFAULT)
    `uvm_field_int(saw_output_neg_sat, UVM_DEFAULT)
    `uvm_field_int(saw_q_negative, UVM_DEFAULT)
    `uvm_field_int(saw_q_zero, UVM_DEFAULT)
    `uvm_field_int(saw_q_positive, UVM_DEFAULT)
    `uvm_field_int(saw_k_negative, UVM_DEFAULT)
    `uvm_field_int(saw_k_zero, UVM_DEFAULT)
    `uvm_field_int(saw_k_positive, UVM_DEFAULT)
    `uvm_field_int(saw_v_negative, UVM_DEFAULT)
    `uvm_field_int(saw_v_zero, UVM_DEFAULT)
    `uvm_field_int(saw_v_positive, UVM_DEFAULT)
    `uvm_field_int(q_tail_tile, UVM_DEFAULT)
    `uvm_field_int(kv_tail_tile, UVM_DEFAULT)
    `uvm_field_int(write_backpressured, UVM_DEFAULT)
    `uvm_field_int(q_tile_count, UVM_DEFAULT)
    `uvm_field_int(kv_tile_count, UVM_DEFAULT)
    `uvm_field_int(valid_lanes, UVM_DEFAULT)
  `uvm_object_utils_end

  function new(string name = "fa_model_event");
    super.new(name);
  endfunction
endclass

class fa_axil_item extends uvm_sequence_item;
  rand bit        is_read;
  rand bit [31:0] addr;
  rand bit [31:0] data;
  rand bit [3:0]  strb;
       bit [31:0] rdata;
       bit [1:0]  resp;

  `uvm_object_utils_begin(fa_axil_item)
    `uvm_field_int(is_read, UVM_DEFAULT)
    `uvm_field_int(addr, UVM_DEFAULT)
    `uvm_field_int(data, UVM_DEFAULT)
    `uvm_field_int(strb, UVM_DEFAULT)
    `uvm_field_int(rdata, UVM_DEFAULT)
    `uvm_field_int(resp, UVM_DEFAULT)
  `uvm_object_utils_end

  function new(string name = "fa_axil_item");
    super.new(name);
  endfunction
endclass

class fa_tile_item extends uvm_sequence_item;
  rand fa_tile_kind_e kind;
  rand bit            bank;
  rand bit [5:0]      addr;
  rand bit [255:0]    data;
  rand bit            is_commit;

  `uvm_object_utils_begin(fa_tile_item)
    `uvm_field_enum(fa_tile_kind_e, kind, UVM_DEFAULT)
    `uvm_field_int(bank, UVM_DEFAULT)
    `uvm_field_int(addr, UVM_DEFAULT)
    `uvm_field_int(data, UVM_DEFAULT)
    `uvm_field_int(is_commit, UVM_DEFAULT)
  `uvm_object_utils_end

  function new(string name = "fa_tile_item");
    super.new(name);
  endfunction
endclass

class fa_axi_write_item extends uvm_sequence_item;
  bit [31:0]  addr;
  bit [7:0]   burst_len;
  bit [2:0]   size;
  bit [1:0]   burst;
  bit [127:0] data;
  bit [15:0]  strb;
  bit         last;
  bit [1:0]   resp;

  `uvm_object_utils_begin(fa_axi_write_item)
    `uvm_field_int(addr, UVM_DEFAULT)
    `uvm_field_int(burst_len, UVM_DEFAULT)
    `uvm_field_int(size, UVM_DEFAULT)
    `uvm_field_int(burst, UVM_DEFAULT)
    `uvm_field_int(data, UVM_DEFAULT)
    `uvm_field_int(strb, UVM_DEFAULT)
    `uvm_field_int(last, UVM_DEFAULT)
    `uvm_field_int(resp, UVM_DEFAULT)
  `uvm_object_utils_end

  function new(string name = "fa_axi_write_item");
    super.new(name);
  endfunction
endclass

class fa_test_cfg extends uvm_object;
  rand int unsigned seq_q;
  rand int unsigned seq_kv;
  rand int unsigned num_q_heads;
  rand int unsigned num_kv_heads;
  rand int unsigned head_dim;
  rand int unsigned tile_q;
  rand int unsigned tile_k;
  rand int unsigned ready_low_pct;
  bit [31:0]       score_scale;
  bit [31:0]       value_scale;
  bit [31:0]       out_scale;
  bit [31:0]       o_base;
  bit              decode_en;
  bit              causal_en;
  bit              enable_reference_model;
  fa_stimulus_e    stimulus;
  fa_qkv_tensor    tensor;
  bit              canonical_const_v;
  byte signed      canonical_value;
  bit              enable_data_check;
  bit              allow_axil_error_response;
  bit              inject_axi_bresp_error;
  bit              saif_capture;

  constraint c_supported_mode {
    seq_q inside {[1:FA_MAX_SEQ]};
    seq_kv inside {[1:FA_MAX_SEQ]};
    decode_en -> seq_q == 1;
    num_q_heads == 1;
    num_kv_heads == 1;
    head_dim == `ATTN_HEAD_DIM;
    tile_q == `ATTN_TILE_Q;
    tile_k == `ATTN_TILE_K;
    ready_low_pct inside {[0:75]};
  }

  `uvm_object_utils_begin(fa_test_cfg)
    `uvm_field_int(seq_q, UVM_DEFAULT)
    `uvm_field_int(seq_kv, UVM_DEFAULT)
    `uvm_field_int(num_q_heads, UVM_DEFAULT)
    `uvm_field_int(num_kv_heads, UVM_DEFAULT)
    `uvm_field_int(head_dim, UVM_DEFAULT)
    `uvm_field_int(tile_q, UVM_DEFAULT)
    `uvm_field_int(tile_k, UVM_DEFAULT)
    `uvm_field_int(ready_low_pct, UVM_DEFAULT)
    `uvm_field_int(score_scale, UVM_DEFAULT)
    `uvm_field_int(value_scale, UVM_DEFAULT)
    `uvm_field_int(out_scale, UVM_DEFAULT)
    `uvm_field_int(o_base, UVM_DEFAULT)
    `uvm_field_int(decode_en, UVM_DEFAULT)
    `uvm_field_int(causal_en, UVM_DEFAULT)
    `uvm_field_enum(fa_stimulus_e, stimulus, UVM_DEFAULT)
    `uvm_field_int(enable_reference_model, UVM_DEFAULT)
    `uvm_field_int(canonical_const_v, UVM_DEFAULT)
    `uvm_field_int(canonical_value, UVM_DEFAULT)
    `uvm_field_int(enable_data_check, UVM_DEFAULT)
    `uvm_field_int(allow_axil_error_response, UVM_DEFAULT)
    `uvm_field_int(inject_axi_bresp_error, UVM_DEFAULT)
    `uvm_field_int(saif_capture, UVM_DEFAULT)
  `uvm_object_utils_end

  function new(string name = "fa_test_cfg");
    super.new(name);
    seq_q = `ATTN_TILE_Q;
    seq_kv = `ATTN_TILE_K;
    num_q_heads = 1;
    num_kv_heads = 1;
    head_dim = `ATTN_HEAD_DIM;
    tile_q = `ATTN_TILE_Q;
    tile_k = `ATTN_TILE_K;
    ready_low_pct = 0;
    score_scale = 32'h0000_0001;
    value_scale = 32'h0000_0001;
    out_scale = 32'h000f_0001;
    o_base = 32'd0;
    decode_en = 0;
    causal_en = 0;
    enable_reference_model = 1;
    stimulus = FA_STIM_CANONICAL;
    tensor = fa_qkv_tensor::type_id::create("tensor");
    canonical_const_v = 1;
    canonical_value = 1;
    enable_data_check = 1;
    allow_axil_error_response = 0;
    inject_axi_bresp_error = 0;
    saif_capture = 0;
  endfunction
endclass

`endif
