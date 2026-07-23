`ifndef ATTENTION_UVM_IF_SV
`define ATTENTION_UVM_IF_SV

`include "attention_defines.vh"

interface fa_axil_if(input logic clk, input logic rst_n);
  logic [31:0] awaddr;
  logic        awvalid;
  logic        awready;
  logic [31:0] wdata;
  logic [3:0]  wstrb;
  logic        wvalid;
  logic        wready;
  logic [1:0]  bresp;
  logic        bvalid;
  logic        bready;
  logic [31:0] araddr;
  logic        arvalid;
  logic        arready;
  logic [31:0] rdata;
  logic [1:0]  rresp;
  logic        rvalid;
  logic        rready;

  // AXI-Lite payloads must stay stable until their handshake completes.
  property p_aw_stable;
    @(posedge clk) disable iff (!rst_n)
      awvalid && !awready |=> awvalid && $stable(awaddr);
  endproperty
  property p_w_stable;
    @(posedge clk) disable iff (!rst_n)
      wvalid && !wready |=> wvalid && $stable(wdata) && $stable(wstrb);
  endproperty
  property p_ar_stable;
    @(posedge clk) disable iff (!rst_n)
      arvalid && !arready |=> arvalid && $stable(araddr);
  endproperty
  assert property (p_aw_stable);
  assert property (p_w_stable);
  assert property (p_ar_stable);
endinterface

interface fa_tile_loader_if #(
  parameter int ADDR_W = `ATTN_CACHE_ADDR_W
)(input logic clk, input logic rst_n);
  logic [1:0]          load_kind;
  logic                load_bank;
  logic [ADDR_W-1:0]   load_addr;
  logic                load_half;
  logic [127:0]        load_data;
  logic                load_valid;
  logic                load_ready;
  logic [1:0]          commit_kind;
  logic                commit_bank;
  logic                commit_valid;

  property p_load_stable;
    @(posedge clk) disable iff (!rst_n)
      load_valid && !load_ready |=> load_valid && $stable(load_kind) &&
      $stable(load_bank) && $stable(load_addr) && $stable(load_half) &&
      $stable(load_data);
  endproperty
  assert property (p_load_stable);
endinterface

interface fa_axi_write_if(input logic clk, input logic rst_n);
  logic [31:0]  awaddr;
  logic [7:0]   awlen;
  logic [2:0]   awsize;
  logic [1:0]   awburst;
  logic         awvalid;
  logic         awready;
  logic [127:0] wdata;
  logic [15:0]  wstrb;
  logic         wlast;
  logic         wvalid;
  logic         wready;
  logic [1:0]   bresp;
  logic         bvalid;
  logic         bready;

  property p_aw_stable;
    @(posedge clk) disable iff (!rst_n)
      awvalid && !awready |=> awvalid && $stable(awaddr) && $stable(awlen) &&
      $stable(awsize) && $stable(awburst);
  endproperty
  property p_w_stable;
    @(posedge clk) disable iff (!rst_n)
      wvalid && !wready |=> wvalid && $stable(wdata) && $stable(wstrb) &&
      $stable(wlast);
  endproperty
  assert property (p_aw_stable);
  assert property (p_w_stable);
endinterface

interface fa_status_if(input logic clk, input logic rst_n);
  logic       irq;
  logic [3:0] debug_state;
endinterface

// A test-owned, clock-synchronous request channel for DUT-only SAIF capture.
// The test raises requests on a falling edge; tb_top consumes them on the
// following rising edge, so toggle-system tasks never race AXI transactions.
interface fa_saif_control_if(input logic clk);
  logic            enabled;
  logic            capture_active;
  logic            start_req;
  logic            stop_req;
  longint unsigned start_cycle;
  longint unsigned stop_cycle;

  initial begin
    enabled = 1'b0;
    capture_active = 1'b0;
    start_req = 1'b0;
    stop_req = 1'b0;
    start_cycle = '0;
    stop_cycle = '0;
  end

  task automatic start_capture();
    if (enabled) begin
      @(negedge clk);
      start_req <= 1'b1;
      @(negedge clk);
      start_req <= 1'b0;
    end
  endtask

  task automatic stop_capture();
    if (enabled) begin
      @(negedge clk);
      stop_req <= 1'b1;
      @(negedge clk);
      stop_req <= 1'b0;
    end
  endtask
endinterface

`endif
