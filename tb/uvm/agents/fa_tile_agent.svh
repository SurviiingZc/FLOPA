`ifndef FA_TILE_AGENT_SVH
`define FA_TILE_AGENT_SVH

class fa_tile_sequencer extends uvm_sequencer #(fa_tile_item);
  `uvm_component_utils(fa_tile_sequencer)
  function new(string name = "fa_tile_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass

class fa_tile_driver extends uvm_driver #(fa_tile_item);
  `uvm_component_utils(fa_tile_driver)
  virtual fa_tile_loader_if vif;

  function new(string name = "fa_tile_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual fa_tile_loader_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "fa_tile_driver requires virtual interface tile_vif")
  endfunction

  task reset_signals();
    vif.load_kind <= '0;
    vif.load_bank <= 1'b0;
    vif.load_addr <= '0;
    vif.load_half <= 1'b0;
    vif.load_data <= '0;
    vif.load_valid <= 1'b0;
    vif.commit_kind <= '0;
    vif.commit_bank <= 1'b0;
    vif.commit_valid <= 1'b0;
  endtask

  task drive_half(fa_tile_item tr, bit half);
    @(negedge vif.clk);
    vif.load_kind <= tr.kind;
    vif.load_bank <= tr.bank;
    vif.load_addr <= tr.addr;
    vif.load_half <= half;
    vif.load_data <= half ? tr.data[255:128] : tr.data[127:0];
    vif.load_valid <= 1'b1;
    do @(posedge vif.clk); while (!vif.load_ready);
    @(negedge vif.clk);
    vif.load_valid <= 1'b0;
  endtask

  task drive_item(fa_tile_item tr);
    if (tr.is_commit) begin
      @(negedge vif.clk);
      vif.commit_kind <= tr.kind;
      vif.commit_bank <= tr.bank;
      vif.commit_valid <= 1'b1;
      @(posedge vif.clk);
      @(negedge vif.clk);
      vif.commit_valid <= 1'b0;
    end else begin
      if (!tr.upper_half_only)
        drive_half(tr, 1'b0);
      if (!tr.lower_half_only)
        drive_half(tr, 1'b1);
    end
  endtask

  task run_phase(uvm_phase phase);
    fa_tile_item tr;
    reset_signals();
    wait (vif.rst_n === 1'b1);
    forever begin
      seq_item_port.get_next_item(tr);
      drive_item(tr);
      seq_item_port.item_done();
    end
  endtask
endclass

class fa_tile_monitor extends uvm_component;
  `uvm_component_utils(fa_tile_monitor)
  virtual fa_tile_loader_if vif;
  fa_test_cfg cfg;
  uvm_analysis_port #(fa_tile_item) ap;
  uvm_analysis_port #(fa_tile_item) protocol_ap;

  function new(string name = "fa_tile_monitor", uvm_component parent = null);
    super.new(name, parent);
    ap = new("ap", this);
    protocol_ap = new("protocol_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual fa_tile_loader_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "fa_tile_monitor requires virtual interface tile_vif")
    if (!uvm_config_db#(fa_test_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "fa_tile_monitor requires fa_test_cfg")
  endfunction

  task run_phase(uvm_phase phase);
    bit have_lo;
    fa_tile_item lo;
    fa_tile_item tr;
    have_lo = 0;
    forever begin
      @(posedge vif.clk);
      if (!vif.rst_n) begin
        have_lo = 0;
      end else begin
        if (vif.commit_valid) begin
          tr = fa_tile_item::type_id::create("observed_commit");
          tr.kind = fa_tile_kind_e'(vif.commit_kind);
          tr.bank = vif.commit_bank;
          tr.is_commit = 1;
          ap.write(tr);
        end
        if (vif.load_valid && vif.load_ready) begin
          if (!vif.load_half) begin
            lo = fa_tile_item::type_id::create("observed_load_lo");
            lo.kind = fa_tile_kind_e'(vif.load_kind);
            lo.bank = vif.load_bank;
            lo.addr = vif.load_addr;
            lo.data[127:0] = vif.load_data;
            lo.is_commit = 0;
            have_lo = 1;
          end else if (have_lo && lo.kind == fa_tile_kind_e'(vif.load_kind) &&
                       lo.bank == vif.load_bank && lo.addr == vif.load_addr) begin
            lo.data[255:128] = vif.load_data;
            ap.write(lo);
            have_lo = 0;
          end else begin
            tr = fa_tile_item::type_id::create("observed_protocol_error");
            tr.kind = fa_tile_kind_e'(vif.load_kind);
            tr.bank = vif.load_bank;
            tr.addr = vif.load_addr;
            tr.is_commit = 0;
            tr.protocol_error = !have_lo ? FA_TILE_PROTOCOL_MISSING_LOWER :
                                (lo.kind != fa_tile_kind_e'(vif.load_kind)) ?
                                  FA_TILE_PROTOCOL_KIND_MISMATCH :
                                (lo.bank != vif.load_bank) ?
                                  FA_TILE_PROTOCOL_BANK_MISMATCH :
                                  FA_TILE_PROTOCOL_ADDR_MISMATCH;
            protocol_ap.write(tr);
            have_lo = 0;
            if (cfg.allow_tile_protocol_error)
              `uvm_info("TILE_PROTOCOL_EXPECTED",
                        "Observed directed high cache half without matching low half", UVM_LOW)
            else
              `uvm_error("TILE_PROTOCOL", "High cache half arrived without matching low half")
          end
        end
      end
    end
  endtask
endclass

class fa_tile_agent extends uvm_agent;
  `uvm_component_utils(fa_tile_agent)
  fa_tile_sequencer sqr;
  fa_tile_driver    drv;
  fa_tile_monitor   mon;

  function new(string name = "fa_tile_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon = fa_tile_monitor::type_id::create("mon", this);
    if (is_active == UVM_ACTIVE) begin
      sqr = fa_tile_sequencer::type_id::create("sqr", this);
      drv = fa_tile_driver::type_id::create("drv", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (is_active == UVM_ACTIVE)
      drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

`endif
