`ifndef FA_AXI_WRITE_AGENT_SVH
`define FA_AXI_WRITE_AGENT_SVH

class fa_axi_write_responder extends uvm_component;
  `uvm_component_utils(fa_axi_write_responder)
  virtual fa_axi_write_if vif;
  fa_test_cfg cfg;
  bit bresp_error_sent;

  function new(string name = "fa_axi_write_responder", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual fa_axi_write_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "fa_axi_write_responder requires virtual interface write_vif")
    if (!uvm_config_db#(fa_test_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "fa_axi_write_responder requires fa_test_cfg")
  endfunction

  function bit ready_now();
    return ($urandom_range(0, 99) >= cfg.ready_low_pct);
  endfunction

  task run_phase(uvm_phase phase);
    vif.awready <= 1'b0;
    vif.wready <= 1'b0;
    vif.bvalid <= 1'b0;
    vif.bresp <= 2'b00;
    bresp_error_sent = 0;
    forever begin
      @(posedge vif.clk);
      if (!vif.rst_n) begin
        vif.awready <= 1'b0;
        vif.wready <= 1'b0;
        vif.bvalid <= 1'b0;
        vif.bresp <= 2'b00;
        bresp_error_sent = 0;
      end else begin
        vif.awready <= ready_now();
        vif.wready <= ready_now();
        if (vif.bvalid && vif.bready)
          vif.bvalid <= 1'b0;
        if (vif.wvalid && vif.wready && vif.wlast && !vif.bvalid) begin
          vif.bvalid <= 1'b1;
          if (cfg.inject_axi_bresp_error && !bresp_error_sent) begin
            vif.bresp <= 2'b10;
            bresp_error_sent = 1;
          end else begin
            vif.bresp <= 2'b00;
          end
        end
      end
    end
  endtask
endclass

class fa_axi_write_monitor extends uvm_component;
  `uvm_component_utils(fa_axi_write_monitor)
  virtual fa_axi_write_if vif;
  uvm_analysis_port #(fa_axi_write_item) ap;

  function new(string name = "fa_axi_write_monitor", uvm_component parent = null);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual fa_axi_write_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "fa_axi_write_monitor requires virtual interface write_vif")
  endfunction

  task run_phase(uvm_phase phase);
    bit have_aw;
    bit [31:0] burst_addr;
    bit [7:0] burst_len;
    bit [2:0] burst_size;
    bit [1:0] burst_type;
    int unsigned beat_index;
    fa_axi_write_item tr;
    have_aw = 0;
    beat_index = 0;
    forever begin
      @(posedge vif.clk);
      if (!vif.rst_n) begin
        have_aw = 0;
        beat_index = 0;
      end else begin
        if (vif.awvalid && vif.awready) begin
          if (have_aw)
            `uvm_error("AXI_WRITE", "Overlapping AW transactions are unsupported by this single-ID DUT")
          burst_addr = vif.awaddr;
          burst_len = vif.awlen;
          burst_size = vif.awsize;
          burst_type = vif.awburst;
          beat_index = 0;
          have_aw = 1;
        end
        if (vif.wvalid && vif.wready) begin
          if (!have_aw) begin
            `uvm_error("AXI_WRITE", "W beat observed before AW handshake")
          end else begin
            tr = fa_axi_write_item::type_id::create("observed_wbeat");
            tr.addr = burst_addr + (beat_index << burst_size);
            tr.burst_len = burst_len;
            tr.size = burst_size;
            tr.burst = burst_type;
            tr.data = vif.wdata;
            tr.strb = vif.wstrb;
            tr.last = vif.wlast;
            tr.resp = 2'b00;
            ap.write(tr);
            if (vif.wlast) begin
              if (beat_index != burst_len)
                `uvm_error("AXI_WRITE", $sformatf("WLAST at beat %0d, expected %0d", beat_index, burst_len))
              have_aw = 0;
            end
            beat_index++;
          end
        end
      end
    end
  endtask
endclass

class fa_axi_write_agent extends uvm_agent;
  `uvm_component_utils(fa_axi_write_agent)
  fa_axi_write_responder rsp;
  fa_axi_write_monitor mon;

  function new(string name = "fa_axi_write_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    rsp = fa_axi_write_responder::type_id::create("rsp", this);
    mon = fa_axi_write_monitor::type_id::create("mon", this);
  endfunction
endclass

`endif
