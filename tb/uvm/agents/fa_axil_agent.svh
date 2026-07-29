`ifndef FA_AXIL_AGENT_SVH
`define FA_AXIL_AGENT_SVH

class fa_axil_sequencer extends uvm_sequencer #(fa_axil_item);
  `uvm_component_utils(fa_axil_sequencer)
  function new(string name = "fa_axil_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass

class fa_axil_driver extends uvm_driver #(fa_axil_item);
  `uvm_component_utils(fa_axil_driver)
  virtual fa_axil_if vif;

  function new(string name = "fa_axil_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual fa_axil_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "fa_axil_driver requires virtual interface axil_vif")
  endfunction

  task reset_signals();
    vif.awaddr  <= '0;
    vif.awvalid <= 1'b0;
    vif.wdata   <= '0;
    vif.wstrb   <= '0;
    vif.wvalid  <= 1'b0;
    vif.bready  <= 1'b0;
    vif.araddr  <= '0;
    vif.arvalid <= 1'b0;
    vif.rready  <= 1'b0;
  endtask

  task drive_write(fa_axil_item tr);
    @(negedge vif.clk);
    fork
      begin
        repeat (tr.aw_delay_cycles) @(negedge vif.clk);
        vif.awaddr <= tr.addr;
        vif.awvalid <= 1'b1;
        do @(posedge vif.clk); while (!(vif.awvalid && vif.awready));
        @(negedge vif.clk);
        vif.awvalid <= 1'b0;
      end
      begin
        repeat (tr.w_delay_cycles) @(negedge vif.clk);
        vif.wdata <= tr.data;
        vif.wstrb <= tr.strb;
        vif.wvalid <= 1'b1;
        do @(posedge vif.clk); while (!(vif.wvalid && vif.wready));
        @(negedge vif.clk);
        vif.wvalid <= 1'b0;
      end
    join
    repeat (tr.bready_delay_cycles) @(negedge vif.clk);
    vif.bready <= 1'b1;
    do @(posedge vif.clk); while (!vif.bvalid);
    tr.resp = vif.bresp;
    @(negedge vif.clk);
    vif.bready <= 1'b0;
  endtask

  task drive_read(fa_axil_item tr);
    @(negedge vif.clk);
    repeat (tr.ar_delay_cycles) @(negedge vif.clk);
    vif.araddr  <= tr.addr;
    vif.arvalid <= 1'b1;
    do @(posedge vif.clk); while (!vif.arready);
    @(negedge vif.clk);
    vif.arvalid <= 1'b0;
    repeat (tr.rready_delay_cycles) @(negedge vif.clk);
    vif.rready  <= 1'b1;
    do @(posedge vif.clk); while (!vif.rvalid);
    tr.rdata = vif.rdata;
    tr.resp  = vif.rresp;
    @(negedge vif.clk);
    vif.rready <= 1'b0;
  endtask

  task run_phase(uvm_phase phase);
    fa_axil_item tr;
    reset_signals();
    wait (vif.rst_n === 1'b1);
    forever begin
      seq_item_port.get_next_item(tr);
      if (tr.is_read)
        drive_read(tr);
      else
        drive_write(tr);
      if (tr.resp != 2'b00)
        `uvm_info("AXIL_RESP", $sformatf("AXI-Lite response %0h at %08h", tr.resp, tr.addr), UVM_MEDIUM)
      seq_item_port.item_done();
    end
  endtask
endclass

class fa_axil_monitor extends uvm_component;
  `uvm_component_utils(fa_axil_monitor)
  virtual fa_axil_if vif;
  uvm_analysis_port #(fa_axil_item) ap;

  function new(string name = "fa_axil_monitor", uvm_component parent = null);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual fa_axil_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "fa_axil_monitor requires virtual interface axil_vif")
  endfunction

  task run_phase(uvm_phase phase);
    bit have_aw;
    bit have_w;
    bit have_ar;
    bit [31:0] awaddr;
    bit [31:0] wdata;
    bit [3:0]  wstrb;
    bit [31:0] araddr;
    fa_axil_item tr;
    have_aw = 0;
    have_w = 0;
    have_ar = 0;
    forever begin
      @(posedge vif.clk);
      if (!vif.rst_n) begin
        have_aw = 0;
        have_w = 0;
        have_ar = 0;
      end else begin
        if (vif.awvalid && vif.awready) begin
          awaddr = vif.awaddr;
          have_aw = 1;
        end
        if (vif.wvalid && vif.wready) begin
          wdata = vif.wdata;
          wstrb = vif.wstrb;
          have_w = 1;
        end
        if (vif.bvalid && vif.bready && have_aw && have_w) begin
          tr = fa_axil_item::type_id::create("observed_write");
          tr.is_read = 0;
          tr.addr = awaddr;
          tr.data = wdata;
          tr.strb = wstrb;
          tr.resp = vif.bresp;
          ap.write(tr);
          have_aw = 0;
          have_w = 0;
        end
        if (vif.arvalid && vif.arready) begin
          araddr = vif.araddr;
          have_ar = 1;
        end
        if (vif.rvalid && vif.rready && have_ar) begin
          tr = fa_axil_item::type_id::create("observed_read");
          tr.is_read = 1;
          tr.addr = araddr;
          tr.rdata = vif.rdata;
          tr.resp = vif.rresp;
          ap.write(tr);
          have_ar = 0;
        end
      end
    end
  endtask
endclass

class fa_axil_agent extends uvm_agent;
  `uvm_component_utils(fa_axil_agent)
  fa_axil_sequencer sqr;
  fa_axil_driver    drv;
  fa_axil_monitor   mon;

  function new(string name = "fa_axil_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon = fa_axil_monitor::type_id::create("mon", this);
    if (is_active == UVM_ACTIVE) begin
      sqr = fa_axil_sequencer::type_id::create("sqr", this);
      drv = fa_axil_driver::type_id::create("drv", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (is_active == UVM_ACTIVE)
      drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

`endif
