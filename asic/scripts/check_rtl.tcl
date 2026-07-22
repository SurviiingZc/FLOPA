foreach required_variable {FA_ROOT FA_DC_WORK FA_STD_DB FA_SRAM_DB FA_CLOCK_PERIOD} {
  if {![info exists env($required_variable)]} {
    error "$required_variable is not set"
  }
}

set root_dir [file normalize $env(FA_ROOT)]
set work_dir [file normalize $env(FA_DC_WORK)]
set report_dir [file join $work_dir reports]
set expected_top_macros [expr {
  [info exists env(FA_EXPECTED_TOP_SRAM_MACROS)] ?
  $env(FA_EXPECTED_TOP_SRAM_MACROS) : 480
}]
file mkdir $report_dir

source [file join $root_dir asic scripts library_setup.tcl]
source [file join $root_dir asic scripts rtl_sources.tcl]
source [file join $root_dir asic constraints core_constraints.tcl]

define_design_lib WORK -path [file join $work_dir work]
analyze -format verilog -define {SYNTHESIS ATTN_ASIC} $fa_rtl_files
elaborate attention_accel_top
current_design attention_accel_top
if {![link]} {
  error "unresolved references remain after link"
}
uniquify

set sram_cells [get_cells -quiet -hierarchical \
    -filter "ref_name == uhdsp_256x8m4s"]
set sram_count [sizeof_collection $sram_cells]
if {$sram_count != $expected_top_macros} {
  error "expected $expected_top_macros uhdsp_256x8m4s instances, found $sram_count"
}
puts "INFO: resolved $sram_count uhdsp_256x8m4s instances"

# Each portable multiplier wrapper must bind to the explicit ASIC DW02_mult
# branch. Check this before synthesis can flatten or rename resource cells.
set signed_mult_wrapper_cells [get_cells -quiet -hierarchical \
    -filter "ref_name =~ fa_signed_mult_comb*"]
set unsigned_mult_wrapper_cells [get_cells -quiet -hierarchical \
    -filter "ref_name =~ fa_unsigned_mult_comb*"]
set dw_multiplier_cells [get_cells -quiet -hierarchical \
    -filter "ref_name =~ DW02_mult*"]
set mult_wrapper_count [expr {
  [sizeof_collection $signed_mult_wrapper_cells] +
  [sizeof_collection $unsigned_mult_wrapper_cells]
}]
set dw_multiplier_count [sizeof_collection $dw_multiplier_cells]
if {$mult_wrapper_count == 0 || $dw_multiplier_count != $mult_wrapper_count} {
  error "linked $mult_wrapper_count multiplier wrappers but $dw_multiplier_count DW02_mult instances"
}
puts "INFO: resolved $dw_multiplier_count DW02_mult instances for $mult_wrapper_count wrappers"

fa_apply_core_constraints $env(FA_CLOCK_PERIOD)
fa_apply_sram_hold_constraints $sram_cells

redirect -file [file join $report_dir check_design.rpt] {check_design}
redirect -file [file join $report_dir check_timing.rpt] {check_timing}
redirect -file [file join $report_dir constraints.rpt] {
  report_constraint -all_violators
}
redirect -file [file join $report_dir design.rpt] {report_design}
redirect -file [file join $report_dir references.rpt] {report_reference}
redirect -file [file join $report_dir libraries.rpt] {list_libs}

set config_fp [open [file join $report_dir run_config.rpt] w]
puts $config_fp "top=attention_accel_top"
puts $config_fp "corner=[expr {[info exists env(FA_CORNER)] ? $env(FA_CORNER) : "unknown"}]"
puts $config_fp "clock_period_ns=$env(FA_CLOCK_PERIOD)"
puts $config_fp "standard_cell_db=$std_db"
puts $config_fp "sram_db=$sram_db"
puts $config_fp "sram_macro_count=$sram_count"
puts $config_fp "multiplier_wrapper_count=$mult_wrapper_count"
puts $config_fp "linked_dw02_mult_count=$dw_multiplier_count"
close $config_fp

exit
