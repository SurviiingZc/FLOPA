if {![info exists env(FA_ROOT)] || ![info exists env(FA_DC_WORK)]} {
  error "FA_ROOT and FA_DC_WORK must be set"
}

set root_dir [file normalize $env(FA_ROOT)]
set work_dir [file normalize $env(FA_DC_WORK)]
set report_dir [file join $work_dir reports]
file mkdir $report_dir

if {[info exists env(FA_STD_DB)]} {
  set std_db [file normalize $env(FA_STD_DB)]
} else {
  set std_db "/data/public/STD/tcbn28hpcplusbwp12t30p140_190a/tcbn28hpcplusbwp12t30p140_180a_ccs/TSMCHOME/digital/Front_End/timing_power_noise/CCS/tcbn28hpcplusbwp12t30p140_180a/tcbn28hpcplusbwp12t30p140tt0p9v25c_ccs.db"
}
if {![file exists $std_db]} {
  error "TT standard-cell DB not found: $std_db"
}

set_app_var search_path [concat [get_app_var search_path] [list \
  [file join $root_dir rtl common] [file dirname $std_db]]]
set_app_var target_library [list $std_db]
set_app_var synthetic_library [list dw_foundation.sldb]
set_app_var link_library [list "*" $std_db dw_foundation.sldb]

define_design_lib WORK -path [file join $work_dir work]
analyze -format verilog [file join $root_dir rtl compute os_fsa_pe.v]
elaborate os_fsa_pe
current_design os_fsa_pe
link

create_clock -name core_clk -period 3.200 [get_ports clk]
set_clock_uncertainty 0.100 [get_clocks core_clk]
set_clock_transition 0.050 [get_clocks core_clk]
set_input_delay 0.200 -clock core_clk \
  [remove_from_collection [all_inputs] [get_ports {clk rst_n}]]
set_output_delay 0.200 -clock core_clk [all_outputs]
set_false_path -from [get_ports rst_n]
set_max_transition 0.300 [current_design]
set_max_fanout 16 [current_design]

compile_ultra

set mac_start [add_to_collection [get_pins -hierarchical "a_q_reg*/Q"] \
                                  [get_pins -hierarchical "b_q_reg*/Q"]]
set mac_end [get_pins -hierarchical "acc_o_reg*/D"]

redirect -file [file join $report_dir timing_all.rpt] {
  report_timing -delay_type max -path_type full_clock_expanded \
    -max_paths 20 -nworst 2 -significant_digits 4
}
redirect -file [file join $report_dir timing_mac.rpt] {
  report_timing -delay_type max -path_type full_clock_expanded \
    -from $mac_start -to $mac_end -max_paths 20 -nworst 4 -significant_digits 4
}
redirect -file [file join $report_dir qor.rpt] {report_qor}
redirect -file [file join $report_dir area.rpt] {report_area -hierarchy}
redirect -file [file join $report_dir power.rpt] {report_power}
write -format ddc -hierarchy -output [file join $work_dir os_fsa_pe_mapped.ddc]
exit
