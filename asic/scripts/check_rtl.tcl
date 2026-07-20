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
close $config_fp

exit
