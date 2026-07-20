foreach required_variable {
  FA_ROOT FA_DC_WORK FA_STD_DB FA_SRAM_DB FA_SYNTH_TOPS FA_CLOCK_PERIOD
} {
  if {![info exists env($required_variable)]} {
    error "$required_variable is not set"
  }
}

set root_dir [file normalize $env(FA_ROOT)]
set work_dir [file normalize $env(FA_DC_WORK)]
set top_list [split $env(FA_SYNTH_TOPS)]
set clock_period $env(FA_CLOCK_PERIOD)
set corner [expr {[info exists env(FA_CORNER)] ? $env(FA_CORNER) : "unknown"}]
set expected_top_macros [expr {
  [info exists env(FA_EXPECTED_TOP_SRAM_MACROS)] ?
  $env(FA_EXPECTED_TOP_SRAM_MACROS) : 480
}]
set physical_aware [expr {
  [info exists env(FA_PHYSICAL_AWARE)] && $env(FA_PHYSICAL_AWARE) eq "1"
}]
set write_artifacts [expr {
  ![info exists env(FA_WRITE_ARTIFACTS)] || $env(FA_WRITE_ARTIFACTS) ne "0"
}]

source [file join $root_dir asic scripts library_setup.tcl]
source [file join $root_dir asic scripts rtl_sources.tcl]
source [file join $root_dir asic constraints core_constraints.tcl]

if {$physical_aware} {
  if {![info exists env(FA_MW_LIB)] || ![file isdirectory $env(FA_MW_LIB)]} {
    error "FA_MW_LIB must name a prepared Milkyway design library"
  }
  open_mw_lib $env(FA_MW_LIB)
  if {[info exists env(FA_TLUPLUS_MAX)]} {
    set tlu_args [list -max_tluplus $env(FA_TLUPLUS_MAX)]
    if {[info exists env(FA_TLUPLUS_MIN)]} {
      lappend tlu_args -min_tluplus $env(FA_TLUPLUS_MIN)
    }
    if {[info exists env(FA_TLUPLUS_MAP)]} {
      lappend tlu_args -tech2itf_map $env(FA_TLUPLUS_MAP)
    }
    eval set_tlu_plus_files $tlu_args
    check_tlu_plus_files
  }
}

if {[info exists env(FA_DC_CORES)]} {
  set_host_options -max_cores $env(FA_DC_CORES)
}

define_design_lib WORK -path [file join $work_dir work]
set first_design 1

foreach top_name $top_list {
  if {!$first_design} {
    remove_design -all
  }
  set first_design 0

  set top_dir [file join $work_dir $top_name]
  set report_dir [file join $top_dir reports]
  set result_dir [file join $top_dir results]
  file mkdir $report_dir
  file mkdir $result_dir

  puts "INFO: analyzing $top_name"
  analyze -format verilog -define {SYNTHESIS ATTN_ASIC} $fa_rtl_files
  elaborate $top_name
  current_design $top_name
  if {![link]} {
    error "failed to link $top_name"
  }
  uniquify

  # Keep placement-relevant stripe and O-bank hierarchy visible in top reports.
  set stripe_cells [get_cells -quiet -hierarchical -filter "ref_name =~ fsa_stripe*"]
  if {[sizeof_collection $stripe_cells] > 0} {
    set_ungroup $stripe_cells false
  }
  set o_bank_cells [get_cells -quiet -hierarchical -filter "ref_name =~ o_accumulator_bank*"]
  if {[sizeof_collection $o_bank_cells] > 0} {
    set_ungroup $o_bank_cells false
  }

  # SRAM macros are link-library cells and must never be absorbed into logic.
  set macro_cells [get_cells -quiet -hierarchical \
      -filter "ref_name == uhdsp_256x8m4s"]
  set macro_count [sizeof_collection $macro_cells]
  if {$top_name eq "attention_accel_top" &&
      $macro_count != $expected_top_macros} {
    error "attention_accel_top expected $expected_top_macros SRAM macros, found $macro_count"
  }
  if {$macro_count > 0} {
    set_dont_touch $macro_cells
  }

  fa_apply_core_constraints $clock_period
  fa_apply_sram_hold_constraints $macro_cells
  set_fix_multiple_port_nets -all -buffer_constants

  if {$physical_aware && [info exists env(FA_FLOORPLAN_FILE)]} {
    read_floorplan $env(FA_FLOORPLAN_FILE)
  }

  set_svf [file join $result_dir ${top_name}.svf]
  if {$physical_aware} {
    compile_ultra -spg
  } else {
    compile_ultra
  }

  redirect -file [file join $report_dir check_design.rpt] {check_design}
  redirect -file [file join $report_dir check_timing.rpt] {check_timing}
  redirect -file [file join $report_dir constraints.rpt] {
    report_constraint -all_violators
  }
  redirect -file [file join $report_dir timing.rpt] {
    report_timing -delay_type max -path_type full_clock_expanded \
      -max_paths 20 -nworst 4 -significant_digits 4
  }
  redirect -file [file join $report_dir timing_min.rpt] {
    report_timing -delay_type min -path_type full_clock_expanded \
      -max_paths 10 -nworst 2 -significant_digits 4
  }
  redirect -file [file join $report_dir qor.rpt] {report_qor}
  redirect -file [file join $report_dir area.rpt] {report_area -hierarchy}
  redirect -file [file join $report_dir power.rpt] {report_power}
  redirect -file [file join $report_dir references.rpt] {report_reference}
  redirect -file [file join $report_dir resources.rpt] {report_resources}
  redirect -file [file join $report_dir design.rpt] {report_design}
  redirect -file [file join $report_dir libraries.rpt] {list_libs}
  if {$physical_aware && [llength [info commands report_congestion]] > 0} {
    redirect -file [file join $report_dir congestion.rpt] {report_congestion}
  }

  set config_fp [open [file join $report_dir run_config.rpt] w]
  puts $config_fp "top=$top_name"
  puts $config_fp "corner=$corner"
  puts $config_fp "clock_period_ns=$clock_period"
  puts $config_fp "standard_cell_db=$std_db"
  puts $config_fp "sram_db=$sram_db"
  puts $config_fp "sram_macro_count=$macro_count"
  puts $config_fp "expected_top_sram_macros=$expected_top_macros"
  puts $config_fp "physical_aware=$physical_aware"
  puts $config_fp "write_artifacts=$write_artifacts"
  foreach constraint_var {
    FA_SETUP_UNCERTAINTY FA_HOLD_UNCERTAINTY FA_CLOCK_TRANSITION
    FA_INPUT_DELAY FA_OUTPUT_DELAY FA_SRAM_INPUT_MIN_DELAY
    FA_INPUT_TRANSITION FA_OUTPUT_LOAD FA_MAX_TRANSITION FA_MAX_FANOUT
  } {
    if {[info exists env($constraint_var)]} {
      puts $config_fp "$constraint_var=$env($constraint_var)"
    }
  }
  close $config_fp

  if {$write_artifacts} {
    change_names -rules verilog -hierarchy
    write -format verilog -hierarchy \
      -output [file join $result_dir ${top_name}_mapped.v]
    write -format ddc -hierarchy -output [file join $result_dir ${top_name}.ddc]
    write_sdc -nosplit [file join $result_dir ${top_name}.sdc]
    write_sdf [file join $result_dir ${top_name}.sdf]
  }
  set_svf -off
}

exit
