if {![info exists env(FA_ROOT)]} {
  error "FA_ROOT is not set"
}
if {![info exists env(FA_DC_WORK)]} {
  error "FA_DC_WORK is not set"
}
if {![info exists env(FA_DC_LIB)]} {
  error "FA_DC_LIB is not set"
}

set root_dir [file normalize $env(FA_ROOT)]
set work_dir [file normalize $env(FA_DC_WORK)]
set report_dir [file join $work_dir reports]
file mkdir $report_dir

set std_db "/data/public/STD/tcbn28hpcplusbwp12t30p140_190a/tcbn28hpcplusbwp12t30p140_180a_ccs/TSMCHOME/digital/Front_End/timing_power_noise/CCS/tcbn28hpcplusbwp12t30p140_180a/tcbn28hpcplusbwp12t30p140tt0p9v25c_ccs.db"
set sram_db [file join [file normalize $env(FA_DC_LIB)] uhdsp_256x8m4s_tt0p9v25c.db]

if {![file exists $std_db]} {
  puts stderr "ERROR: 28nm standard-cell DB not found: $std_db"
  exit 2
}
if {![file exists $sram_db]} {
  puts stderr "ERROR: SRAM DB not found: $sram_db"
  exit 2
}

set_app_var search_path [concat [get_app_var search_path] [list \
  [file join $root_dir rtl common] \
  [file dirname $std_db] \
  [file dirname $sram_db]]]
set_app_var target_library [list $std_db]
set_app_var synthetic_library [list dw_foundation.sldb]
set_app_var link_library [list "*" $std_db $sram_db dw_foundation.sldb]

set rtl_files [list \
  rtl/axi/axi4_slave_if.v \
  rtl/axi/axi4_master_write.v \
  rtl/control/accel_regfile.v \
  rtl/control/accel_scheduler.v \
  rtl/control/perf_counter.v \
  rtl/memory/asic_sram_1024x16.v \
  rtl/memory/asic_sram_256xwide.v \
  rtl/memory/banked_sram.v \
  rtl/memory/bram_buffer.v \
  rtl/memory/output_buffer.v \
  rtl/memory/pingpong_buffer.v \
  rtl/memory/qkv_tile_cache.v \
  rtl/memory/stream_fifo.v \
  rtl/memory/uram_bank.v \
  rtl/compute/scale_requant_unit.v \
  rtl/compute/fsa_delay_line.v \
  rtl/compute/fsa_fused_pe.v \
  rtl/compute/fsa_stripe.v \
  rtl/compute/fsa_fused_array.v \
  rtl/compute/fsa_controller.v \
  rtl/compute/fsa_qk_engine.v \
  rtl/compute/fsa_pv_engine.v \
  rtl/softmax/pwl_exp_unit.v \
  rtl/softmax/reciprocal_lut.v \
  rtl/softmax/online_normalizer.v \
  rtl/attention_accel_top.v]

set absolute_rtl_files {}
foreach rtl_file $rtl_files {
  lappend absolute_rtl_files [file join $root_dir $rtl_file]
}

define_design_lib WORK -path [file join $work_dir work]
analyze -format verilog -define {SYNTHESIS ATTN_ASIC} $absolute_rtl_files
elaborate attention_accel_top
current_design attention_accel_top
set link_ok [link]
if {!$link_ok} {
  puts stderr "ERROR: unresolved references remain after link"
  exit 2
}

set sram_cells [get_cells -hierarchical -filter "ref_name == uhdsp_256x8m4s"]
set sram_count [sizeof_collection $sram_cells]
if {$sram_count != 928} {
  puts stderr "ERROR: expected 928 uhdsp_256x8m4s instances, found $sram_count"
  exit 2
}
puts "INFO: resolved $sram_count uhdsp_256x8m4s instances"

create_clock -name core_clk -period 5.000 [get_ports clk]
set_clock_uncertainty 0.200 [get_clocks core_clk]
set_clock_transition 0.100 [get_clocks core_clk]
set_input_delay 0.500 -clock core_clk [remove_from_collection [all_inputs] [get_ports {clk rst_n}]]
set_output_delay 0.500 -clock core_clk [all_outputs]
set_false_path -from [get_ports rst_n]

redirect -file [file join $report_dir check_design.rpt] {check_design}
redirect -file [file join $report_dir design.rpt] {report_design}
redirect -file [file join $report_dir libraries.rpt] {list_libs}
exit
