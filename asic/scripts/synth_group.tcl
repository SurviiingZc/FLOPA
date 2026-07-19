if {![info exists env(FA_ROOT)] || ![info exists env(FA_DC_WORK)] ||
    ![info exists env(FA_STD_DB)] || ![info exists env(FA_SRAM_DB)] ||
    ![info exists env(FA_SYNTH_TOPS)] || ![info exists env(FA_CLOCK_PERIOD)]} {
  error "required synthesis environment variables are not set"
}

set root_dir [file normalize $env(FA_ROOT)]
set work_dir [file normalize $env(FA_DC_WORK)]
set std_db [file normalize $env(FA_STD_DB)]
set sram_db [file normalize $env(FA_SRAM_DB)]
set top_list [split $env(FA_SYNTH_TOPS)]
set clock_period $env(FA_CLOCK_PERIOD)

foreach required_file [list $std_db $sram_db] {
  if {![file exists $required_file]} {
    error "required library does not exist: $required_file"
  }
}

set_app_var search_path [concat [get_app_var search_path] [list \
  [file join $root_dir rtl common] [file dirname $std_db] [file dirname $sram_db]]]
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
  rtl/compute/os_fsa_delay_line.v \
  rtl/compute/os_fsa_fused_pe.v \
  rtl/compute/os_fsa_stripe.v \
  rtl/compute/os_fsa_fused_array.v \
  rtl/compute/os_fsa_controller.v \
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

  analyze -format verilog -define {SYNTHESIS ATTN_ASIC} $absolute_rtl_files
  elaborate $top_name
  current_design $top_name
  if {![link]} {
    error "failed to link $top_name"
  }
  uniquify

  # Preserve the physical 8-row stripe boundaries for placement and CTS.
  # PE logic inside a stripe remains available for normal optimization.
  set stripe_cells [get_cells -quiet -hierarchical -filter "ref_name =~ os_fsa_stripe*"]
  if {[sizeof_collection $stripe_cells] > 0} {
    set_ungroup $stripe_cells false
  }

  set macro_cells [get_cells -quiet -hierarchical -filter "ref_name == uhdsp_256x8m4s"]
  set macro_count [sizeof_collection $macro_cells]
  if {$top_name eq "attention_accel_top" && $macro_count != 928} {
    error "attention_accel_top expected 928 SRAM macros, found $macro_count"
  }
  if {[sizeof_collection $macro_cells] > 0} {
    set_dont_touch $macro_cells
  }

  set clk_ports [get_ports -quiet clk]
  if {[sizeof_collection $clk_ports] > 0} {
    create_clock -name core_clk -period $clock_period $clk_ports
  } else {
    create_clock -name core_clk -period $clock_period
  }
  set_clock_uncertainty 0.100 [get_clocks core_clk]
  set_clock_transition 0.050 [get_clocks core_clk]

  set data_inputs [all_inputs]
  if {[sizeof_collection $clk_ports] > 0} {
    set data_inputs [remove_from_collection $data_inputs $clk_ports]
  }
  set reset_ports [get_ports -quiet rst_n]
  if {[sizeof_collection $reset_ports] > 0} {
    set data_inputs [remove_from_collection $data_inputs $reset_ports]
    set_false_path -from $reset_ports
  }
  if {[sizeof_collection $data_inputs] > 0} {
    set_input_delay 0.200 -clock core_clk $data_inputs
  }
  if {[sizeof_collection [all_outputs]] > 0} {
    set_output_delay 0.200 -clock core_clk [all_outputs]
    set_load 0.020 [all_outputs]
  }

  set_max_transition 0.300 [current_design]
  set_max_fanout 16 [current_design]
  set_fix_multiple_port_nets -all -buffer_constants
  set_svf [file join $result_dir ${top_name}.svf]
  compile_ultra

  redirect -file [file join $report_dir check_design.rpt] {check_design}
  redirect -file [file join $report_dir check_timing.rpt] {check_timing}
  redirect -file [file join $report_dir constraints.rpt] {report_constraint -all_violators}
  redirect -file [file join $report_dir timing.rpt] {
    report_timing -delay_type max -path_type full_clock_expanded \
      -max_paths 20 -nworst 4 -significant_digits 4
  }
  redirect -file [file join $report_dir qor.rpt] {report_qor}
  redirect -file [file join $report_dir area.rpt] {report_area -hierarchy}
  redirect -file [file join $report_dir power.rpt] {report_power}
  redirect -file [file join $report_dir references.rpt] {report_reference}
  redirect -file [file join $report_dir resources.rpt] {report_resources}
  redirect -file [file join $report_dir design.rpt] {report_design}
  redirect -file [file join $report_dir libraries.rpt] {list_libs}

  set config_fp [open [file join $report_dir run_config.rpt] w]
  puts $config_fp "top=$top_name"
  puts $config_fp "clock_period_ns=$clock_period"
  puts $config_fp "standard_cell_db=$std_db"
  puts $config_fp "sram_db=$sram_db"
  puts $config_fp "sram_macro_count=$macro_count"
  close $config_fp

  change_names -rules verilog -hierarchy
  write -format verilog -hierarchy -output [file join $result_dir ${top_name}_mapped.v]
  write -format ddc -hierarchy -output [file join $result_dir ${top_name}.ddc]
  write_sdc -nosplit [file join $result_dir ${top_name}.sdc]
  write_sdf [file join $result_dir ${top_name}.sdf]
  set_svf -off
}

exit
