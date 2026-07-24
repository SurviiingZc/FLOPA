`ifndef ATTENTION_SCOREBOARD_SVH
`define ATTENTION_SCOREBOARD_SVH

class attention_scoreboard extends uvm_component;
  `uvm_component_utils(attention_scoreboard)
  uvm_tlm_analysis_fifo #(fa_axil_item)      axil_fifo;
  uvm_tlm_analysis_fifo #(fa_tile_item)      tile_fifo;
  uvm_tlm_analysis_fifo #(fa_axi_write_item) write_fifo;
  uvm_analysis_port #(fa_model_event) model_ap;
  attention_ref_model ref_model;
  fa_test_cfg cfg;
  int unsigned output_beats;
  int unsigned output_bytes;
  int unsigned v_load_words;
  int unsigned q_load_words;
  int unsigned k_load_words;
  int unsigned invalid_output_bytes;
  bit [31:0] status_q;
  bit start_seen;
  bit model_reported;
  bit address_error_reported;
  bit output_seen [int unsigned];

  function new(string name = "attention_scoreboard", uvm_component parent = null);
    super.new(name, parent);
    model_ap = new("model_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    axil_fifo = new("axil_fifo", this);
    tile_fifo = new("tile_fifo", this);
    write_fifo = new("write_fifo", this);
    ref_model = attention_ref_model::type_id::create("ref_model");
    if (!uvm_config_db#(fa_test_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "attention_scoreboard requires fa_test_cfg")
  endfunction

  function void maybe_calculate_golden();
    if (cfg.enable_reference_model && start_seen && !ref_model.golden_valid &&
        ref_model.q_loaded && ref_model.k_loaded && ref_model.v_loaded) begin
      ref_model.calculate(cfg);
      if (ref_model.golden_valid && !model_reported) begin
        model_ap.write(ref_model.last_event);
        model_reported = 1;
      end
    end
  endfunction

  function int unsigned expected_q_load_words();
    int unsigned q_tiles;
    q_tiles = cfg.decode_en ? 1 : ((cfg.seq_q + `ATTN_TILE_Q - 1) / `ATTN_TILE_Q);
    return q_tiles * cfg.head_dim;
  endfunction

  function int unsigned expected_kv_load_words();
    int unsigned q_tiles;
    int unsigned kv_tiles;
    q_tiles = cfg.decode_en ? 1 : ((cfg.seq_q + `ATTN_TILE_Q - 1) / `ATTN_TILE_Q);
    kv_tiles = (cfg.seq_kv + `ATTN_TILE_K - 1) / `ATTN_TILE_K;
    return q_tiles * kv_tiles * cfg.head_dim;
  endfunction

  function void check_q_load_payload(fa_tile_item tr);
    int unsigned logical_tile;
    int unsigned logical_row;
    byte signed expected_value;
    byte signed actual_value;
    // Q tiles are issued in logical order.  This check guards the UVM-side
    // bank-reuse schedule independently of end-to-end output comparison.
    logical_tile = q_load_words / cfg.head_dim;
    if (logical_tile >= expected_q_load_words() / cfg.head_dim)
      return;
    for (int unsigned lane = 0; lane < `ATTN_ARRAY_ROWS; lane++) begin
      logical_row = logical_tile * `ATTN_ARRAY_ROWS + lane;
      expected_value = cfg.tensor.q[logical_row][tr.addr];
      actual_value = $signed(tr.data[lane*8 +: 8]);
      if (actual_value !== expected_value) begin
        `uvm_error("SB_Q_LOAD", $sformatf(
          "Q cache payload mismatch tile=%0d row=%0d dim=%0d expected=%0d actual=%0d",
          logical_tile, logical_row, tr.addr, expected_value, actual_value))
        return;
      end
    end
  endfunction

  task consume_axil();
    fa_axil_item tr;
    forever begin
      axil_fifo.get(tr);
      if (!tr.is_read && tr.resp != 2'b00 && !cfg.allow_axil_error_response)
        `uvm_error("SB_AXIL", $sformatf("write response %0h at %08h", tr.resp, tr.addr))
      if (tr.is_read && tr.addr == `ATTN_REG_STATUS)
        status_q = tr.rdata;
      if (!tr.is_read && tr.addr == `ATTN_REG_CONTROL && tr.data[0] && tr.resp == 2'b00) begin
        start_seen = 1;
        maybe_calculate_golden();
      end
    end
  endtask

  task consume_tile();
    fa_tile_item tr;
    forever begin
      tile_fifo.get(tr);
      if (!tr.is_commit) begin
        case (tr.kind)
          FA_TILE_Q: begin
            check_q_load_payload(tr);
            q_load_words++;
          end
          FA_TILE_K: k_load_words++;
          FA_TILE_V: v_load_words++;
        endcase
        ref_model.load_word(tr);
        maybe_calculate_golden();
      end
    end
  endtask

  task compare_write_beat(fa_axi_write_item tr);
    bit [7:0] expected;
    bit [7:0] actual;
    bit [7:0] previous_expected;
    bit [7:0] next_expected;
    bit [7:0] previous_q_tile_expected;
    int unsigned byte_address;
    int unsigned row;
    int unsigned dim;
    int signed matching_feature;
    for (int unsigned lane = 0; lane < 16; lane++) begin
      if (tr.strb[lane]) begin
        if (tr.addr < cfg.o_base) begin
          invalid_output_bytes++;
          if (!address_error_reported) begin
            `uvm_error("SB_ADDR", $sformatf("write address %08h precedes O base %08h",
              tr.addr, cfg.o_base))
            address_error_reported = 1;
          end
          continue;
        end
        byte_address = tr.addr - cfg.o_base + lane;
        if (byte_address >= (cfg.decode_en ? `ATTN_HEAD_DIM : cfg.seq_q * `ATTN_HEAD_DIM)) begin
          invalid_output_bytes++;
          if (!address_error_reported) begin
            `uvm_error("SB_ADDR", $sformatf("first invalid write byte address %0d; expected range is [0:%0d]",
              byte_address, (cfg.decode_en ? `ATTN_HEAD_DIM : cfg.seq_q * `ATTN_HEAD_DIM) - 1))
            address_error_reported = 1;
          end
        end else begin
          row = byte_address / `ATTN_HEAD_DIM;
          dim = byte_address % `ATTN_HEAD_DIM;
          if (output_seen.exists(byte_address))
            `uvm_error("SB_DUP", $sformatf("duplicate write byte address %0d", byte_address))
          output_seen[byte_address] = 1;
          expected = ref_model.expected_byte(byte_address);
          actual = tr.data[lane*8 +: 8];
          if (actual !== expected) begin
            matching_feature = -1;
            for (int unsigned feature = 0; feature < `ATTN_HEAD_DIM; feature++)
              if (ref_model.expected[row][feature] === actual && matching_feature == -1)
                matching_feature = feature;
            previous_expected = (dim == 0) ? '0 : ref_model.expected[row][dim - 1];
            next_expected = (dim + 1 == `ATTN_HEAD_DIM) ? '0 : ref_model.expected[row][dim + 1];
            previous_q_tile_expected = (row < `ATTN_TILE_Q) ? '0 :
                                       ref_model.expected[row - `ATTN_TILE_Q][dim];
            `uvm_error("SB_DATA", $sformatf("mismatch addr=%04h row=%0d dim=%0d expected=%0d(0x%02h) actual=%0d(0x%02h) prev_dim=%0d next_dim=%0d prev_q_tile=%0d matching_feature=%0d",
              byte_address, byte_address / `ATTN_HEAD_DIM, byte_address % `ATTN_HEAD_DIM,
              $signed(expected), expected, $signed(actual), actual,
              $signed(previous_expected), $signed(next_expected),
              $signed(previous_q_tile_expected), matching_feature))
          end
        end
        output_bytes++;
      end
    end
  endtask

  task consume_write();
    fa_axi_write_item tr;
    forever begin
      write_fifo.get(tr);
      output_beats++;
      if (tr.size != 3'd4 || tr.burst != 2'b01)
        `uvm_error("SB_AXI", $sformatf("unexpected AXI write shape size=%0d burst=%0h", tr.size, tr.burst))
      if (cfg.enable_data_check) begin
        if (!ref_model.golden_valid)
          `uvm_error("SB_MODEL", "DUT write arrived before the reference result was available")
        else
          compare_write_beat(tr);
      end
    end
  endtask

  task run_phase(uvm_phase phase);
    fork
      consume_axil();
      consume_tile();
      consume_write();
    join
  endtask

  function void report_phase(uvm_phase phase);
    int unsigned expected_bytes;
    int unsigned missing_bytes;
    expected_bytes = cfg.decode_en ? `ATTN_HEAD_DIM : cfg.seq_q * `ATTN_HEAD_DIM;
    if (cfg.enable_data_check && output_beats == 0)
      `uvm_error("SB_DATA", "No AXI write beats observed in data-checking test")
    if (cfg.enable_data_check && output_bytes != expected_bytes)
      `uvm_error("SB_BYTES", $sformatf("output bytes=%0d expected=%0d", output_bytes,
                 expected_bytes))
    if (cfg.enable_data_check && invalid_output_bytes != 0)
      `uvm_error("SB_ADDR_SUMMARY", $sformatf("invalid output bytes=%0d", invalid_output_bytes))
    if (cfg.enable_data_check) begin
      for (int unsigned byte_address = 0; byte_address < expected_bytes; byte_address++)
        if (!output_seen.exists(byte_address))
          missing_bytes++;
      if (missing_bytes != 0)
        `uvm_error("SB_MISSING", $sformatf("missing expected output bytes=%0d", missing_bytes))
    end
    if (cfg.enable_data_check && q_load_words != expected_q_load_words())
      `uvm_error("SB_LOAD_Q", $sformatf("Q load words=%0d expected=%0d",
        q_load_words, expected_q_load_words()))
    if (cfg.enable_data_check && k_load_words != expected_kv_load_words())
      `uvm_error("SB_LOAD_K", $sformatf("K load words=%0d expected=%0d",
        k_load_words, expected_kv_load_words()))
    if (cfg.enable_data_check && v_load_words != expected_kv_load_words())
      `uvm_error("SB_LOAD_V", $sformatf("V load words=%0d expected=%0d",
        v_load_words, expected_kv_load_words()))
    `uvm_info("SB_SUMMARY", $sformatf("q/k/v load words=%0d/%0d/%0d, output beats=%0d bytes=%0d", q_load_words, k_load_words, v_load_words, output_beats, output_bytes), UVM_LOW)
  endfunction
endclass

`endif
