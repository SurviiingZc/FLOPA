`ifndef ATTENTION_ENV_SVH
`define ATTENTION_ENV_SVH

class fa_virtual_sequencer extends uvm_sequencer #(uvm_sequence_item);
  `uvm_component_utils(fa_virtual_sequencer)
  fa_axil_sequencer axil_sqr;
  fa_tile_sequencer tile_sqr;

  function new(string name = "fa_virtual_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass

class attention_env extends uvm_env;
  `uvm_component_utils(attention_env)
  fa_axil_agent       axil_agent;
  fa_tile_agent       tile_agent;
  fa_axi_write_agent  write_agent;
  fa_virtual_sequencer vseqr;
  attention_scoreboard scoreboard;
  fa_axil_coverage    axil_cov;
  fa_tile_coverage    tile_cov;
  fa_axi_write_coverage write_cov;
  fa_phase_coverage   phase_cov;
  fa_math_coverage    math_cov;

  function new(string name = "attention_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    axil_agent = fa_axil_agent::type_id::create("axil_agent", this);
    tile_agent = fa_tile_agent::type_id::create("tile_agent", this);
    write_agent = fa_axi_write_agent::type_id::create("write_agent", this);
    vseqr = fa_virtual_sequencer::type_id::create("vseqr", this);
    scoreboard = attention_scoreboard::type_id::create("scoreboard", this);
    axil_cov = fa_axil_coverage::type_id::create("axil_cov", this);
    tile_cov = fa_tile_coverage::type_id::create("tile_cov", this);
    write_cov = fa_axi_write_coverage::type_id::create("write_cov", this);
    phase_cov = fa_phase_coverage::type_id::create("phase_cov", this);
    math_cov = fa_math_coverage::type_id::create("math_cov", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    vseqr.axil_sqr = axil_agent.sqr;
    vseqr.tile_sqr = tile_agent.sqr;
    axil_agent.mon.ap.connect(scoreboard.axil_fifo.analysis_export);
    tile_agent.mon.ap.connect(scoreboard.tile_fifo.analysis_export);
    write_agent.mon.ap.connect(scoreboard.write_fifo.analysis_export);
    axil_agent.mon.ap.connect(axil_cov.analysis_export);
    tile_agent.mon.ap.connect(tile_cov.analysis_export);
    write_agent.mon.ap.connect(write_cov.analysis_export);
    scoreboard.model_ap.connect(math_cov.analysis_export);
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("FCOV_SUMMARY", $sformatf("axil=%0.2f%% tile=%0.2f%% write=%0.2f%% phase=%0.2f%% math=%0.2f%%",
      axil_cov.cg.get_inst_coverage(), tile_cov.cg.get_inst_coverage(),
      write_cov.cg.get_inst_coverage(), phase_cov.cg.get_inst_coverage(),
      math_cov.cg.get_inst_coverage()), UVM_LOW)
  endfunction
endclass

`endif
