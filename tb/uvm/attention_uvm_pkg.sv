`ifndef ATTENTION_UVM_PKG_SV
`define ATTENTION_UVM_PKG_SV

package attention_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "attention_defines.vh"

  `include "fa_uvm_types.svh"
  `include "agents/fa_axil_agent.svh"
  `include "agents/fa_tile_agent.svh"
  `include "agents/fa_axi_write_agent.svh"
  `include "ref_model/attention_ref_model.svh"
  `include "scoreboard/attention_scoreboard.svh"
  `include "coverage/attention_coverage.svh"
  `include "env/attention_env.svh"
  `include "sequences/attention_sequences.svh"
  `include "tests/attention_tests.svh"
endpackage

`endif
