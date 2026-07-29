`ifndef ATTENTION_REF_MODEL_SVH
`define ATTENTION_REF_MODEL_SVH

// Bit-accurate model for up to 512 Q/K/V tokens and single-token MHA decode.
// It mirrors score_scale_pipe, pwl_exp_unit, reciprocal_lut, and the final
// normalizer result across the complete configured KV context.
class attention_ref_model extends uvm_object;
  `uvm_object_utils(attention_ref_model)

  byte signed q_mem [0:FA_MAX_SEQ-1][0:`ATTN_HEAD_DIM-1];
  byte signed k_mem [0:FA_MAX_SEQ-1][0:`ATTN_HEAD_DIM-1];
  byte signed v_mem [0:FA_MAX_SEQ-1][0:`ATTN_HEAD_DIM-1];
  byte signed expected [0:FA_MAX_SEQ-1][0:`ATTN_HEAD_DIM-1];
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

  function automatic longint unsigned reciprocal_exact(
    longint unsigned value, ref fa_model_event model_ev);
    int signed msb;
    longint unsigned normalized;
    longint unsigned seed;
    if (value == 0) return 0;
    msb = 31;
    while (msb > 0 && !value[msb]) msb--;
    if (msb >= 15) normalized = value >> (msb - 15);
    else normalized = value << (15 - msb);
    model_ev.reciprocal_seed_mask[normalized[14:11]] = 1'b1;
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

  function automatic bit normalizer_negative_half_tie(
    longint signed value, int unsigned shift);
    bit [63:0] bits;
    bit sticky_bit;
    bits = value;
    sticky_bit = 0;
    if (shift == 0 || !bits[63] || !bits[shift-1]) return 0;
    for (int unsigned bit_index = 0; bit_index < shift-1; bit_index++)
      sticky_bit |= bits[bit_index];
    return !sticky_bit;
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
    reciprocal = reciprocal_exact(l_value, model_ev);
    normalized = (accumulator * $signed({1'b0, reciprocal[29:0]})) >>> 15;
    scale_product = normalized * $signed(out_scale[15:0]);
    shift = out_scale[21:16];
    shifted = scale_product >>> shift;
    rounded = shifted + normalizer_round_increment(scale_product, shift);
    if (normalizer_round_increment(scale_product, shift))
      model_ev.saw_normalizer_round_increment = 1;
    if (normalizer_negative_half_tie(scale_product, shift))
      model_ev.saw_normalizer_negative_tie = 1;
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

  function automatic longint signed wrap_signed_width(
    longint signed value, int unsigned width);
    longint unsigned mask;
    longint unsigned raw;
    if (width >= 64)
      return value;
    mask = (64'h1 << width) - 1;
    raw = $unsigned(value) & mask;
    if (raw & (64'h1 << (width - 1)))
      return $signed(raw | ~mask);
    return $signed(raw);
  endfunction

  function automatic longint unsigned saturate_unsigned_width(
    longint unsigned value, int unsigned width);
    longint unsigned max_value;
    if (width >= 64)
      return value;
    max_value = (64'h1 << width) - 1;
    return (value > max_value) ? max_value : value;
  endfunction

  function void load_word(fa_tile_item tr);
    if (tr.is_commit || tr.addr >= `ATTN_HEAD_DIM)
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
    longint signed score [0:FA_MAX_SEQ-1][0:FA_MAX_SEQ-1];
    longint signed raw_dot;
    longint signed block_max;
    longint signed next_m;
    longint signed alpha;
    longint signed accumulator;
    longint signed m_state [0:FA_MAX_SEQ-1];
    longint signed acc_state [0:FA_MAX_SEQ-1][0:`ATTN_HEAD_DIM-1];
    longint unsigned l_state [0:FA_MAX_SEQ-1];
    longint unsigned block_sum;
    bit [15:0] probability;
    bit valid_lane;
    bit row_state_valid [0:FA_MAX_SEQ-1];
    bit have_block_max;
    int unsigned rows_to_process;
    int unsigned cols_to_process;
    golden_valid = 0;
    last_event = fa_model_event::type_id::create("model_event");
    last_event.stimulus = cfg.stimulus;
    last_event.num_heads = cfg.num_q_heads;
    last_event.decode_en = cfg.decode_en;
    last_event.causal_en = cfg.causal_en;
    last_event.multi_q_tile = (cfg.seq_q > `ATTN_ARRAY_ROWS);
    last_event.multi_kv_tile = (cfg.seq_kv > `ATTN_ARRAY_COLS);
    last_event.q_tile_count = (cfg.seq_q + `ATTN_TILE_Q - 1) / `ATTN_TILE_Q;
    last_event.kv_tile_count = (cfg.seq_kv + `ATTN_TILE_K - 1) / `ATTN_TILE_K;
    last_event.q_tail_tile = (cfg.seq_q % `ATTN_TILE_Q) != 0;
    last_event.kv_tail_tile = (cfg.seq_kv % `ATTN_TILE_K) != 0;
    last_event.write_backpressured = cfg.ready_low_pct != 0;
    last_event.score_scale = cfg.score_scale;
    last_event.out_scale = cfg.out_scale;
    if (!(q_loaded && k_loaded && v_loaded)) begin
      `uvm_error("REF_INPUT", "Reference model started before all Q/K/V words were observed")
      return;
    end
    if (cfg.head_dim != `ATTN_HEAD_DIM || cfg.seq_kv == 0 ||
        cfg.seq_kv > FA_MAX_SEQ || cfg.seq_q == 0 ||
        cfg.seq_q > FA_MAX_SEQ || (cfg.decode_en && cfg.seq_q != 1)) begin
      `uvm_error("REF_SCOPE", "Bit-exact model supports up to 512 tokens or single-token decode")
      return;
    end
    for (int unsigned row = 0; row < cfg.seq_q; row++)
      for (int unsigned dim = 0; dim < `ATTN_HEAD_DIM; dim++) begin
        if (cfg.tensor.q[row][dim] < 0) last_event.saw_q_negative = 1;
        else if (cfg.tensor.q[row][dim] == 0) last_event.saw_q_zero = 1;
        else last_event.saw_q_positive = 1;
      end
    for (int unsigned row = 0; row < cfg.seq_kv; row++)
      for (int unsigned dim = 0; dim < `ATTN_HEAD_DIM; dim++) begin
        if (cfg.tensor.k[row][dim] < 0) last_event.saw_k_negative = 1;
        else if (cfg.tensor.k[row][dim] == 0) last_event.saw_k_zero = 1;
        else last_event.saw_k_positive = 1;
        if (cfg.tensor.v[row][dim] < 0) last_event.saw_v_negative = 1;
        else if (cfg.tensor.v[row][dim] == 0) last_event.saw_v_zero = 1;
        else last_event.saw_v_positive = 1;
      end
    for (int unsigned row = 0; row < cfg.seq_q; row++)
      for (int unsigned dim = 0; dim < `ATTN_HEAD_DIM; dim++)
        q_mem[row][dim] = cfg.tensor.q[row][dim];
    for (int unsigned col = 0; col < cfg.seq_kv; col++)
      for (int unsigned dim = 0; dim < `ATTN_HEAD_DIM; dim++) begin
        k_mem[col][dim] = cfg.tensor.k[col][dim];
        v_mem[col][dim] = cfg.tensor.v[col][dim];
      end
    rows_to_process = cfg.decode_en ? 1 : cfg.seq_q;
    cols_to_process = cfg.seq_kv;
    for (int unsigned row = 0; row < rows_to_process; row++) begin
      for (int unsigned col = 0; col < cols_to_process; col++) begin
        raw_dot = 0;
        for (int unsigned dim = 0; dim < `ATTN_HEAD_DIM; dim++)
          raw_dot += q_mem[row][dim] * k_mem[col][dim];
        score[row][col] = wrap_signed_width(raw_dot, `ATTN_ACC_W);
      end

      // Match the RTL's FlashAttention recurrence per physical KV tile. A
      // global softmax is not bit-equivalent because PWL(alpha) is applied to
      // the old O/L state at every tile boundary.
      row_state_valid[row] = 0;
      m_state[row] = 0;
      l_state[row] = 0;
      for (int unsigned dim = 0; dim < `ATTN_HEAD_DIM; dim++)
        acc_state[row][dim] = 0;
      for (int unsigned block_start = 0; block_start < cols_to_process;
           block_start += `ATTN_TILE_K) begin
        int unsigned block_end;
        block_end = ((block_start + `ATTN_TILE_K) < cols_to_process) ?
                    (block_start + `ATTN_TILE_K) : cols_to_process;
        block_max = 0;
        have_block_max = 0;
        for (int unsigned col = block_start; col < block_end; col++) begin
          valid_lane = cfg.decode_en || !cfg.causal_en || (col <= row);
          if (valid_lane && (!have_block_max || score[row][col] > block_max)) begin
            block_max = score[row][col];
            have_block_max = 1;
          end
        end

        if (have_block_max) begin
          next_m = (row_state_valid[row] && m_state[row] >= block_max) ?
                   m_state[row] : block_max;
          alpha = row_state_valid[row] ?
                  pwl_exp_exact(signed16(score_scale_exact(m_state[row] - next_m,
                                                            cfg.score_scale,
                                                            last_event)), last_event) : 0;
          block_sum = 0;
          for (int unsigned col = block_start; col < block_end; col++) begin
            valid_lane = cfg.decode_en || !cfg.causal_en || (col <= row);
            if (valid_lane) begin
              probability = pwl_exp_exact(
                  signed16(score_scale_exact(score[row][col] - next_m,
                                             cfg.score_scale, last_event)), last_event);
              block_sum += probability;
              last_event.valid_lanes++;
            end
          end
          l_state[row] = saturate_unsigned_width(
              ((l_state[row] * alpha) >> `ATTN_BETA_FRAC) + block_sum,
              `ATTN_LSE_W);

          for (int unsigned dim = 0; dim < `ATTN_HEAD_DIM; dim++) begin
            accumulator = row_state_valid[row] ?
                wrap_signed_width((acc_state[row][dim] * alpha) >>> `ATTN_BETA_FRAC,
                                  `ATTN_ACC_W) : 0;
            for (int unsigned col = block_start; col < block_end; col++) begin
              valid_lane = cfg.decode_en || !cfg.causal_en || (col <= row);
              if (valid_lane) begin
                probability = pwl_exp_exact(
                    signed16(score_scale_exact(score[row][col] - next_m,
                                               cfg.score_scale, last_event)), last_event);
                accumulator = wrap_signed_width(
                    accumulator + $signed({1'b0, probability}) * v_mem[col][dim],
                    `ATTN_ACC_W);
              end
            end
            acc_state[row][dim] = accumulator;
          end
          m_state[row] = next_m;
          row_state_valid[row] = 1;
        end
      end

      for (int unsigned dim = 0; dim < `ATTN_HEAD_DIM; dim++) begin
        accumulator = acc_state[row][dim];
        if (row_state_valid[row])
          expected[row][dim] = normalize_exact(accumulator, l_state[row],
                                                cfg.out_scale, last_event);
        else
          expected[row][dim] = 0;
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
