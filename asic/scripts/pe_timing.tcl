foreach required_variable {FA_ROOT FA_DC_WORK FA_STD_DB FA_SRAM_DB FA_CLOCK_PERIOD} {
  if {![info exists env($required_variable)]} {
    error "$required_variable is not set"
  }
}

set root_dir [file normalize $env(FA_ROOT)]
set work_dir [file normalize $env(FA_DC_WORK)]
set report_dir [file join $work_dir reports]
set result_dir [file join $work_dir results]
file mkdir $report_dir
file mkdir $result_dir

source [file join $root_dir asic scripts library_setup.tcl]
source [file join $root_dir asic constraints core_constraints.tcl]

if {[info exists env(FA_DC_CORES)]} {
  set_host_options -max_cores $env(FA_DC_CORES)
}

define_design_lib WORK -path [file join $work_dir work]
analyze -format verilog -define {SYNTHESIS ATTN_ASIC} \
  [file join $root_dir rtl compute fsa_fused_pe.v]
elaborate fsa_fused_pe
current_design fsa_fused_pe
if {![link]} {
  error "failed to link fsa_fused_pe"
}

fa_apply_core_constraints $env(FA_CLOCK_PERIOD)
set_fix_multiple_port_nets -all -buffer_constants
compile_ultra

set mac_start [add_to_collection [get_ports q_data_i] [get_ports k_data_i]]
set mac_end [get_pins -hierarchical "accum_q_reg*/D"]

redirect -file [file join $report_dir timing_all.rpt] {
  report_timing -delay_type max -path_type full_clock_expanded \
    -max_paths 20 -nworst 2 -significant_digits 4
}
redirect -file [file join $report_dir timing_mac.rpt] {
  report_timing -delay_type max -path_type full_clock_expanded \
    -from $mac_start -to $mac_end -max_paths 20 -nworst 4 \
    -significant_digits 4
}
redirect -file [file join $report_dir check_design.rpt] {check_design}
redirect -file [file join $report_dir check_timing.rpt] {check_timing}
redirect -file [file join $report_dir qor.rpt] {report_qor}
redirect -file [file join $report_dir area.rpt] {report_area -hierarchy}
redirect -file [file join $report_dir power.rpt] {report_power}
redirect -file [file join $report_dir resources.rpt] {report_resources}

change_names -rules verilog -hierarchy
write -format verilog -hierarchy \
  -output [file join $result_dir fsa_fused_pe_mapped.v]
write -format ddc -hierarchy -output [file join $result_dir fsa_fused_pe.ddc]
write_sdc -nosplit [file join $result_dir fsa_fused_pe.sdc]
write_sdf [file join $result_dir fsa_fused_pe.sdf]
exit
