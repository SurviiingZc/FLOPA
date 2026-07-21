foreach required_variable {
  FA_POSTCTS_TOP FA_POSTCTS_NETLIST FA_POSTCTS_SDC FA_POSTCTS_SPEF
  FA_POSTCTS_WORK FA_STD_DB FA_SRAM_DB
} {
  if {![info exists env($required_variable)]} {
    error "$required_variable is not set"
  }
}

set top_name $env(FA_POSTCTS_TOP)
set work_dir [file normalize $env(FA_POSTCTS_WORK)]
set report_dir [file join $work_dir reports]
file mkdir $report_dir

set_app_var search_path [concat [get_app_var search_path] [list \
  [file dirname $env(FA_STD_DB)] [file dirname $env(FA_SRAM_DB)]]]
set_app_var target_library [list $env(FA_STD_DB)]
set_app_var link_library [list "*" $env(FA_STD_DB) $env(FA_SRAM_DB)]

read_verilog $env(FA_POSTCTS_NETLIST)
current_design $top_name
link_design $top_name
read_sdc $env(FA_POSTCTS_SDC)
read_parasitics -format spef $env(FA_POSTCTS_SPEF)

# Hold is meaningful only after CTS clocks and routed parasitics are propagated.
set_propagated_clock [all_clocks]
update_timing -full

redirect -file [file join $report_dir check_timing.rpt] {check_timing}
redirect -file [file join $report_dir parasitic_coverage.rpt] {
  report_annotated_parasitics -check
}
redirect -file [file join $report_dir analysis_coverage.rpt] {
  report_analysis_coverage
}
redirect -file [file join $report_dir hold_constraints.rpt] {
  report_constraint -all_violators -min_delay
}
redirect -file [file join $report_dir hold_timing.rpt] {
  report_timing -delay_type min -path_type full_clock_expanded \
    -max_paths 100 -nworst 10 -significant_digits 4
}

set violating_paths [get_timing_paths -delay_type min \
    -slack_lesser_than 0.0 -max_paths 100000]
set violation_count [sizeof_collection $violating_paths]
set status_fp [open [file join $report_dir status.rpt] w]
puts $status_fp "corner=ffg0p99v0c"
puts $status_fp "clock_mode=propagated"
puts $status_fp "parasitics=$env(FA_POSTCTS_SPEF)"
puts $status_fp "hold_violating_paths=$violation_count"
close $status_fp

if {$violation_count != 0} {
  puts stderr "ERROR: post-CTS hold has $violation_count violating paths"
  exit 3
}
exit
