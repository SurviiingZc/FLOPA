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
  bit [31:0] status_q;
  bit start_seen;
  bit model_reported;

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
          FA_TILE_Q: q_load_words++;
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
    int unsigned byte_address;
    for (int unsigned lane = 0; lane < 16; lane++) begin
      if (tr.strb[lane]) begin
        byte_address = tr.addr + lane;
        if (byte_address >= `ATTN_ARRAY_ROWS * `ATTN_HEAD_DIM) begin
          `uvm_error("SB_ADDR", $sformatf("write byte address %0d exceeds one-tile output", byte_address))
        end else begin
          expected = ref_model.expected_byte(byte_address);
          actual = tr.data[lane*8 +: 8];
          if (actual !== expected)
            `uvm_error("SB_DATA", $sformatf("mismatch addr=%04h row=%0d dim=%0d expected=%0d(0x%02h) actual=%0d(0x%02h)",
              byte_address, byte_address / `ATTN_HEAD_DIM, byte_address % `ATTN_HEAD_DIM,
              $signed(expected), expected, $signed(actual), actual))
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
    if (cfg.enable_data_check && output_beats == 0)
      `uvm_error("SB_DATA", "No AXI write beats observed in data-checking test")
    if (cfg.enable_data_check && output_bytes != `ATTN_ARRAY_ROWS * `ATTN_HEAD_DIM)
      `uvm_error("SB_BYTES", $sformatf("output bytes=%0d expected=%0d", output_bytes,
                 `ATTN_ARRAY_ROWS * `ATTN_HEAD_DIM))
    `uvm_info("SB_SUMMARY", $sformatf("q/k/v load words=%0d/%0d/%0d, output beats=%0d bytes=%0d", q_load_words, k_load_words, v_load_words, output_beats, output_bytes), UVM_LOW)
  endfunction
endclass

`endif
