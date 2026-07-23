`ifndef FA_UVM_TYPES_SVH
`define FA_UVM_TYPES_SVH

typedef enum bit [1:0] {
  FA_TILE_Q = `ATTN_CACHE_Q,
  FA_TILE_K = `ATTN_CACHE_K,
  FA_TILE_V = `ATTN_CACHE_V
} fa_tile_kind_e;

typedef enum int unsigned {
  FA_STIM_CANONICAL,
  FA_STIM_RANDOM_SMALL,
  FA_STIM_PWL_SEGMENTS,
  FA_STIM_ARITH_ROUNDING,
  FA_STIM_POSITIVE_SAT,
  FA_STIM_NEGATIVE_SAT
} fa_stimulus_e;

class fa_qkv_tensor extends uvm_object;
  `uvm_object_utils(fa_qkv_tensor)
  byte signed q [0:`ATTN_ARRAY_ROWS-1][0:`ATTN_HEAD_DIM-1];
  byte signed k [0:`ATTN_ARRAY_COLS-1][0:`ATTN_HEAD_DIM-1];
  byte signed v [0:`ATTN_ARRAY_COLS-1][0:`ATTN_HEAD_DIM-1];

  function new(string name = "fa_qkv_tensor");
    super.new(name);
  endfunction

  function void fill_constant(byte signed q_value, byte signed k_value,
                              byte signed v_value);
    for (int unsigned row = 0; row < `ATTN_ARRAY_ROWS; row++)
      for (int unsigned dim = 0; dim < `ATTN_HEAD_DIM; dim++) begin
        q[row][dim] = q_value;
        k[row][dim] = k_value;
        v[row][dim] = v_value;
      end
  endfunction

  function void fill_random_small();
    int signed value;
    for (int unsigned row = 0; row < `ATTN_ARRAY_ROWS; row++)
      for (int unsigned dim = 0; dim < `ATTN_HEAD_DIM; dim++) begin
        value = -4 + $urandom_range(8);
        q[row][dim] = value;
        value = -4 + $urandom_range(8);
        k[row][dim] = value;
        value = -96 + $urandom_range(192);
        v[row][dim] = value;
      end
  endfunction

  function void fill_pwl_segments();
    // Q dot K produces score deltas at 256-point boundaries, covering every
    // PWL segment and the x <= -2048 zero-output clamp.
    int signed key_level;
    for (int unsigned row = 0; row < `ATTN_ARRAY_ROWS; row++)
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
    for (int unsigned row = 0; row < `ATTN_ARRAY_ROWS; row++)
      for (int unsigned dim = 0; dim < `ATTN_HEAD_DIM; dim++) begin
        q[row][dim] = (dim == 0) ? 8'sd1 : 8'sd0;
        k[row][dim] = (dim == 0) ? (8'sd2 - (row % 4)) : 8'sd0;
        v[row][dim] = 8'sd1;
      end
  endfunction

  function void fill_pattern(fa_stimulus_e stimulus);
    case (stimulus)
      FA_STIM_CANONICAL: fill_constant(8'sd0, 8'sd0, 8'sd1);
      FA_STIM_RANDOM_SMALL: fill_random_small();
      FA_STIM_PWL_SEGMENTS: fill_pwl_segments();
      FA_STIM_ARITH_ROUNDING: fill_arith_rounding();
      FA_STIM_POSITIVE_SAT: fill_constant(8'sd0, 8'sd0, 8'sd127);
      FA_STIM_NEGATIVE_SAT: fill_constant(8'sd0, 8'sd0, -8'sd128);
      default: fill_constant(8'sd0, 8'sd0, 8'sd0);
    endcase
  endfunction
endclass

class fa_model_event extends uvm_sequence_item;
  fa_stimulus_e stimulus;
  bit causal_en;
  bit [7:0] pwl_segment_mask;
  bit saw_exp_zero;
  bit saw_exp_one;
  bit saw_score_pos_sat;
  bit saw_score_neg_sat;
  bit saw_score_round_increment;
  bit saw_normalizer_round_increment;
  bit saw_output_pos_sat;
  bit saw_output_neg_sat;
  int unsigned valid_lanes;

  `uvm_object_utils_begin(fa_model_event)
    `uvm_field_enum(fa_stimulus_e, stimulus, UVM_DEFAULT)
    `uvm_field_int(causal_en, UVM_DEFAULT)
    `uvm_field_int(pwl_segment_mask, UVM_DEFAULT)
    `uvm_field_int(saw_exp_zero, UVM_DEFAULT)
    `uvm_field_int(saw_exp_one, UVM_DEFAULT)
    `uvm_field_int(saw_score_pos_sat, UVM_DEFAULT)
    `uvm_field_int(saw_score_neg_sat, UVM_DEFAULT)
    `uvm_field_int(saw_score_round_increment, UVM_DEFAULT)
    `uvm_field_int(saw_normalizer_round_increment, UVM_DEFAULT)
    `uvm_field_int(saw_output_pos_sat, UVM_DEFAULT)
    `uvm_field_int(saw_output_neg_sat, UVM_DEFAULT)
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
  bit [31:0]       out_scale;
  bit              causal_en;
  bit              enable_reference_model;
  fa_stimulus_e    stimulus;
  fa_qkv_tensor    tensor;
  bit              canonical_const_v;
  byte signed      canonical_value;
  bit              enable_data_check;
  bit              allow_axil_error_response;

  constraint c_supported_prefill {
    seq_q inside {[1:32]};
    seq_kv inside {[1:64]};
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
    `uvm_field_int(out_scale, UVM_DEFAULT)
    `uvm_field_int(causal_en, UVM_DEFAULT)
    `uvm_field_enum(fa_stimulus_e, stimulus, UVM_DEFAULT)
    `uvm_field_int(enable_reference_model, UVM_DEFAULT)
    `uvm_field_int(canonical_const_v, UVM_DEFAULT)
    `uvm_field_int(canonical_value, UVM_DEFAULT)
    `uvm_field_int(enable_data_check, UVM_DEFAULT)
    `uvm_field_int(allow_axil_error_response, UVM_DEFAULT)
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
    out_scale = 32'h000f_0001;
    causal_en = 0;
    enable_reference_model = 1;
    stimulus = FA_STIM_CANONICAL;
    tensor = fa_qkv_tensor::type_id::create("tensor");
    canonical_const_v = 1;
    canonical_value = 1;
    enable_data_check = 1;
    allow_axil_error_response = 0;
  endfunction
endclass

`endif
