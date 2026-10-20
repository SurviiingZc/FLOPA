# Gate SAIF and DDC originate from the same mapped write; no heuristic RTL name mapping.
foreach task_variable {
    FA_ROOT FA_DC_WORK FA_STD_DB FA_SRAM_DB FA_CLOCK_PERIOD FA_DDC_FILE
    FA_SAIF_FILE FA_SAIF_STRIP_PATH FA_SAIF_INSTANCE FA_POWER_REPORT_DIR
} {
    if {![info exists env($task_variable)]} {
        error "Missing $task_variable"
    }
}
source [file join $env(FA_ROOT) asic scripts library_setup.tcl]
file mkdir $env(FA_DC_WORK)
file mkdir $env(FA_POWER_REPORT_DIR)
read_ddc $env(FA_DDC_FILE)
current_design $env(FA_SAIF_INSTANCE)
if {![link]} {
    error "Mapped DDC link failed"
}
if {[info exists env(FA_ACTUAL_PIN_LOAD)] && $env(FA_ACTUAL_PIN_LOAD) == "1"} {
    # Official DC variable reference: threshold=0 disables the synthetic high-fanout model.
    set_app_var high_fanout_net_threshold 0
}
identify_clock_gating
reset_switching_activity
unsuppress_message PWR-18
set_message_info -id PWR-18 -limit 30
if {![read_saif -input $env(FA_SAIF_FILE) -instance_name $env(FA_SAIF_STRIP_PATH)]} {
    error "Exact-name SAIF matched no objects"
}
set task_output $env(FA_POWER_REPORT_DIR)
redirect -file [file join $task_output saif_coverage.rpt] {report_saif -hierarchy}
redirect -file [file join $task_output clocks.rpt] {report_clocks}
redirect -file [file join $task_output clock_gating.rpt] {
    report_clock_gating -multi_stage -verbose
}
redirect -file [file join $task_output power_summary.rpt] {report_power}
redirect -file [file join $task_output power_hierarchy.rpt] {
    report_power -hierarchy -levels 4
}
set task_macros [get_cells -hierarchical -filter "ref_name =~ uhdsp*"]
if {[sizeof_collection $task_macros] != 480} {
    error "Unexpected SRAM macro count in F0"
}
set task_config [open [file join $task_output run_config.rpt] w]
foreach task_variable {
    FA_DDC_FILE FA_DDC_SHA256 FA_SAIF_FILE FA_SAIF_SHA256 FA_STD_DB FA_SRAM_DB
    FA_CLOCK_PERIOD FA_RTL_HASH FA_SAIF_STRIP_PATH
} {
    puts $task_config "$task_variable=$env($task_variable)"
}
puts $task_config "saif_name_policy=exact mapped names; auto_map_names disabled"
puts $task_config "sram_macros=[sizeof_collection $task_macros]"
puts $task_config "high_fanout_net_threshold=[get_app_var high_fanout_net_threshold]"
puts $task_config "high_fanout_net_pin_capacitance=[get_app_var high_fanout_net_pin_capacitance]"
close $task_config
exit
