`ifndef ATTENTION_REF_MODEL_SVH
`define ATTENTION_REF_MODEL_SVH

// Bit-accurate first-tile model for the active 32x32x64 prefill datapath.
// It mirrors score_scale_pipe, pwl_exp_unit, reciprocal_lut, and
// online_normalizer. Online accumulation across multiple KV tiles is excluded
// until the serialized LSE recurrence is modelled as a separate milestone.
class attention_ref_model extends uvm_object;
  `uvm_object_utils(attention_ref_model)

  byte signed q_mem [0:`ATTN_ARRAY_ROWS-1][0:`ATTN_HEAD_DIM-1];
  byte signed k_mem [0:`ATTN_ARRAY_COLS-1][0:`ATTN_HEAD_DIM-1];
  byte signed v_mem [0:`ATTN_ARRAY_COLS-1][0:`ATTN_HEAD_DIM-1];
  byte signed expected [0:`ATTN_ARRAY_ROWS-1][0:`ATTN_HEAD_DIM-1];
  bit q_loaded;
  bit k_loaded;
  bit v_loaded;
  bit golden_valid;
  fa_model_event last_event;

  function new(string name = "attention_ref_model");
    super.new(name);
    last_event = fa_model_event::type_id::create("last_event");
  endfunction

  function automatic longint signed signed16(bit [15:0] value);
    return $signed(value);
  endfunction

  function automatic bit [15:0] score_scale_exact(
    longint signed score, bit [31:0] scale_cfg, ref fa_model_event model_ev);
    longint signed product;
    longint signed shifted;
    longint signed clamped;
    int unsigned shift;
    bit guard_bit;
    bit sticky_bit;
    bit round_increment;
    bit [63:0] product_bits;
    product = score * $signed(scale_cfg[15:0]);
    shift = scale_cfg[21:16];
    shifted = product >>> shift;
    if (shifted > 65535) model_ev.saw_score_pos_sat = 1;
    if (shifted < -65536) model_ev.saw_score_neg_sat = 1;
    if (shifted > 65535) clamped = 65535;
    else if (shifted < -65536) clamped = -65536;
    else clamped = shifted;
    product_bits = product;
    guard_bit = 0;
    sticky_bit = 0;
    if (shift != 0) begin
      guard_bit = product_bits[shift-1];
      for (int unsigned bit_index = 0; bit_index < shift-1; bit_index++)
        sticky_bit |= product_bits[bit_index];
    end
    round_increment = guard_bit && (!product_bits[63] || sticky_bit);
    if (round_increment) model_ev.saw_score_round_increment = 1;
    clamped += round_increment;
    if (clamped > 32767) return 16'sh7fff;
    if (clamped < -32768) return 16'sh8000;
    return clamped[15:0];
  endfunction

  function automatic bit [15:0] pwl_exp_exact(
    longint signed x, ref fa_model_event model_ev);
    int unsigned magnitude;
    int unsigned segment;
    int unsigned fraction;
    int unsigned base_lo;
    int unsigned base_hi;
    int unsigned result;
    if (x >= 0) begin
      model_ev.saw_exp_one = 1;
      return 16'd32767;
    end
    if (x <= -2048) begin
      model_ev.saw_exp_zero = 1;
      return 16'd0;
    end
    magnitude = -x;
    segment = magnitude[11:8];
    fraction = magnitude[7:0];
    model_ev.pwl_segment_mask[segment] = 1'b1;
    case (segment)
      0: begin base_lo = 32767; base_hi = 12055; end
      1: begin base_lo = 12055; base_hi = 4435; end
      2: begin base_lo = 4435; base_hi = 1632; end
      3: begin base_lo = 1632; base_hi = 600; end
      4: begin base_lo = 600; base_hi = 221; end
      5: begin base_lo = 221; base_hi = 81; end
      6: begin base_lo = 81; base_hi = 30; end
      default: begin base_lo = 30; base_hi = 11; end
    endcase
    result = base_lo - (((base_lo - base_hi) * fraction) >> 8);
    if (result > 32767) return 16'd32767;
    return result[15:0];
  endfunction

  function automatic longint unsigned reciprocal_exact(longint unsigned value);
    int signed msb;
    longint unsigned normalized;
    longint unsigned seed;
    if (value == 0) return 0;
    msb = 31;
    while (msb > 0 && !value[msb]) msb--;
    if (msb >= 15) normalized = value >> (msb - 15);
    else normalized = value << (15 - msb);
    case (normalized[14:11])
      0: seed = 32767;
      1: seed = 30840;
      2: seed = 29127;
      3: seed = 27594;
      4: seed = 26214;
      5: seed = 24966;
      6: seed = 23831;
      7: seed = 22795;
      8: seed = 21845;
      9: seed = 20972;
      10: seed = 20165;
      11: seed = 19418;
      12: seed = 18725;
      13: seed = 18079;
      14: seed = 17476;
      default: seed = 16913;
    endcase
    if (msb > 15) return seed >> (msb - 15);
    return seed << (15 - msb);
  endfunction

  function automatic bit normalizer_round_increment(
    longint signed value, int unsigned shift);
    bit [63:0] bits;
    bit guard_bit;
    bit sticky_bit;
    bits = value;
    guard_bit = 0;
    sticky_bit = 0;
    if (shift != 0) begin
      guard_bit = bits[shift-1];
      for (int unsigned bit_index = 0; bit_index < shift-1; bit_index++)
        sticky_bit |= bits[bit_index];
    end
    return guard_bit && (!bits[63] || sticky_bit);
  endfunction

  function automatic byte signed normalize_exact(
    longint signed accumulator, longint unsigned l_value, bit [31:0] out_scale,
    ref fa_model_event model_ev);
    longint signed normalized;
    longint signed scale_product;
    longint signed shifted;
    longint signed rounded;
    longint unsigned reciprocal;
    int unsigned shift;
    reciprocal = reciprocal_exact(l_value);
    normalized = (accumulator * $signed({1'b0, reciprocal[29:0]})) >>> 15;
    scale_product = normalized * $signed(out_scale[15:0]);
    shift = out_scale[21:16];
    shifted = scale_product >>> shift;
    rounded = shifted + normalizer_round_increment(scale_product, shift);
    if (normalizer_round_increment(scale_product, shift))
      model_ev.saw_normalizer_round_increment = 1;
    if (shifted > 127 || rounded > 127) begin
      model_ev.saw_output_pos_sat = 1;
      return 8'sd127;
    end
    if (shifted < -128 || rounded < -128) begin
      model_ev.saw_output_neg_sat = 1;
      return -8'sd128;
    end
    return rounded[7:0];
  endfunction

  function void load_word(fa_tile_item tr);
    if (tr.bank != 0 || tr.is_commit || tr.addr >= `ATTN_HEAD_DIM)
      return;
    for (int unsigned lane = 0; lane < `ATTN_ARRAY_ROWS; lane++) begin
      case (tr.kind)
        FA_TILE_Q: q_mem[lane][tr.addr] = $signed(tr.data[lane*8 +: 8]);
        FA_TILE_K: k_mem[lane][tr.addr] = $signed(tr.data[lane*8 +: 8]);
        FA_TILE_V: v_mem[lane][tr.addr] = $signed(tr.data[lane*8 +: 8]);
      endcase
    end
    case (tr.kind)
      FA_TILE_Q: q_loaded = 1;
      FA_TILE_K: k_loaded = 1;
      FA_TILE_V: v_loaded = 1;
    endcase
  endfunction

  function void calculate(fa_test_cfg cfg);
    longint signed score [0:`ATTN_ARRAY_ROWS-1][0:`ATTN_ARRAY_COLS-1];
    longint signed raw_dot;
    longint signed row_max;
    longint unsigned l_value;
    longint signed accumulator;
    bit [15:0] probability;
    bit valid_lane;
    bit have_row_max;
    golden_valid = 0;
    last_event = fa_model_event::type_id::create("model_event");
    last_event.stimulus = cfg.stimulus;
    last_event.causal_en = cfg.causal_en;
    if (!(q_loaded && k_loaded && v_loaded)) begin
      `uvm_error("REF_INPUT", "Reference model started before all Q/K/V words were observed")
      return;
    end
    if (cfg.seq_q != `ATTN_ARRAY_ROWS || cfg.seq_kv != `ATTN_ARRAY_COLS ||
        cfg.head_dim != `ATTN_HEAD_DIM) begin
      `uvm_error("REF_SCOPE", "Bit-exact model currently supports one full 32x32x64 tile")
      return;
    end
    for (int unsigned row = 0; row < `ATTN_ARRAY_ROWS; row++) begin
      row_max = 0;
      have_row_max = 0;
      for (int unsigned col = 0; col < `ATTN_ARRAY_COLS; col++) begin
        raw_dot = 0;
        for (int unsigned dim = 0; dim < `ATTN_HEAD_DIM; dim++)
          raw_dot += q_mem[row][dim] * k_mem[col][dim];
        score[row][col] = raw_dot;
        valid_lane = !cfg.causal_en || (col <= row);
        if (valid_lane && (!have_row_max || raw_dot > row_max)) begin
          row_max = raw_dot;
          have_row_max = 1;
        end
      end
      l_value = 0;
      for (int unsigned col = 0; col < `ATTN_ARRAY_COLS; col++) begin
        valid_lane = !cfg.causal_en || (col <= row);
        if (valid_lane) begin
          probability = pwl_exp_exact(
              signed16(score_scale_exact(score[row][col] - row_max,
                                         cfg.score_scale, last_event)), last_event);
          l_value += probability;
          last_event.valid_lanes++;
        end
      end
      for (int unsigned dim = 0; dim < `ATTN_HEAD_DIM; dim++) begin
        accumulator = 0;
        for (int unsigned col = 0; col < `ATTN_ARRAY_COLS; col++) begin
          valid_lane = !cfg.causal_en || (col <= row);
          if (valid_lane) begin
            probability = pwl_exp_exact(
                signed16(score_scale_exact(score[row][col] - row_max,
                                           cfg.score_scale, last_event)), last_event);
            accumulator += $signed({1'b0, probability}) * v_mem[col][dim];
          end
        end
        expected[row][dim] = normalize_exact(accumulator, l_value,
                                              cfg.out_scale, last_event);
      end
    end
    golden_valid = 1;
  endfunction

  function automatic bit [7:0] expected_byte(int unsigned byte_address);
    int unsigned row;
    int unsigned dim;
    row = byte_address / `ATTN_HEAD_DIM;
    dim = byte_address % `ATTN_HEAD_DIM;
    return expected[row][dim];
  endfunction
endclass

`endif
