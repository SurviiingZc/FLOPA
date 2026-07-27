proc fa_required_env {name} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    error "$name is not set"
  }
  return $::env($name)
}

proc fa_run_equivalence {} {
  set root_dir [file normalize [fa_required_env FA_ROOT]]
  set top_name [fa_required_env FA_FORMAL_TOP]
  set netlist [file normalize [fa_required_env FA_FORMAL_NETLIST]]
  set svf_file [file normalize [fa_required_env FA_FORMAL_SVF]]
  set report_dir [file normalize [fa_required_env FA_FORMAL_REPORT_DIR]]
  set std_db [file normalize [fa_required_env FA_STD_DB]]
  set sram_db [file normalize [fa_required_env FA_SRAM_DB]]
  set dw_root [file normalize [fa_required_env FA_DW_ROOT]]

  file mkdir $report_dir
  foreach required_file [list $netlist $svf_file $std_db $sram_db] {
    if {![file isfile $required_file]} {
      error "required Formality input does not exist: $required_file"
    }
  }

  set synopsys_auto_setup true
  set_app_var hdlin_dwroot $dw_root
  set_app_var hdlin_interface_only "uhdsp_256x8m4s"
  set_app_var search_path [concat [get_app_var search_path] [list \
      [file join $root_dir rtl common] \
      [file dirname $std_db] [file dirname $sram_db]]]
  set_svf $svf_file

  # Do not rely on synopsys_auto_setup to enable this from SVF guidance.
  # With -no_init in FM V-2023.12-SP5 it can remain false, leaving each
  # inserted ICG latch as additional implementation state and causing false
  # failures on otherwise equivalent gated register banks.
  set_app_var verification_clock_gate_reverse_gating true
  puts "FORMALITY_CONFIG: verification_clock_gate_reverse_gating=[get_app_var verification_clock_gate_reverse_gating]"

  read_db -technology_library $std_db
  read_db -technology_library $sram_db

  source [file join $root_dir asic scripts rtl_sources.tcl]
  read_verilog -r -libname WORK -define {SYNTHESIS ATTN_ASIC} $fa_rtl_files
  set_top r:/WORK/$top_name

  read_verilog -i -libname WORK -netlist -01 $netlist
  set_top i:/WORK/$top_name

  match
  redirect -file [file join $report_dir unmatched_points.rpt] {
    report_unmatched_points
  }

  set equivalent [verify]
  redirect -file [file join $report_dir verification.rpt] {
    report_status
  }
  if {!$equivalent} {
    redirect -file [file join $report_dir failing_points.rpt] {
      report_failing_points
    }
    error "RTL-to-gate Formality verification failed"
  }
}

set status_file [file join [fa_required_env FA_FORMAL_REPORT_DIR] status.rpt]
if {[catch {fa_run_equivalence} failure]} {
  set status_fp [open $status_file w]
  puts $status_fp "verification_status=FAIL"
  puts $status_fp "reason=$failure"
  close $status_fp
  puts stderr "FORMALITY_FAIL: $failure"
  exit 1
}

set status_fp [open $status_file w]
puts $status_fp "verification_status=PASS"
close $status_fp
puts "FORMALITY_PASS: RTL is equivalent to the mapped netlist"
exit
