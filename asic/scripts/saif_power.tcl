foreach required_variable {
  FA_ROOT FA_DC_WORK FA_STD_DB FA_SRAM_DB FA_CLOCK_PERIOD FA_DDC_FILE
  FA_SAIF_FILE FA_SAIF_STRIP_PATH FA_SAIF_INSTANCE FA_POWER_REPORT_DIR
} {
  if {![info exists env($required_variable)]} {
    error "$required_variable is not set"
  }
}

set root_dir [file normalize $env(FA_ROOT)]
set work_dir [file normalize $env(FA_DC_WORK)]
set ddc_file [file normalize $env(FA_DDC_FILE)]
set saif_file [file normalize $env(FA_SAIF_FILE)]
set strip_path $env(FA_SAIF_STRIP_PATH)
set top_name $env(FA_SAIF_INSTANCE)
set report_dir [file normalize $env(FA_POWER_REPORT_DIR)]

if {![file isfile $ddc_file]} {
  error "mapped DDC does not exist: $ddc_file"
}
if {![file isfile $saif_file]} {
  error "SAIF does not exist: $saif_file"
}

source [file join $root_dir asic scripts library_setup.tcl]
file mkdir [file join $work_dir work]
file mkdir $report_dir
define_design_lib WORK -path [file join $work_dir work]

# The DDC carries synthesis constraints. Reading it preserves mapped hierarchy
# and clock-gating cells required for trustworthy activity annotation.
read_ddc $ddc_file
current_design $top_name
if {![link]} {
  error "failed to link $top_name from $ddc_file"
}

redirect -file [file join $report_dir check_design.rpt] {check_design}
redirect -file [file join $report_dir clocks.rpt] {report_clocks}

# Rebuild clock-gating attributes after DDC readback so explicit RTL ICGs and
# compile_ultra-inserted ICGs are both included in clock power reporting.
identify_clock_gating

# Power Compiler V-2023.12 does not accept -strip_path. The DDC top is the
# simulated DUT instance at tb_top/dut, so select that source hierarchy with
# the supported -instance_name option. Automatic name mapping reconciles
# compatible RTL-to-gate renaming; optimized logic still requires gate-level
# SAIF for sign-off coverage. read_saif returns 0 if nothing matched, which is
# always a fatal power-flow error.
if {![read_saif -input $saif_file -instance_name $strip_path -auto_map_names]} {
  error "SAIF annotation matched no objects under $strip_path"
}
redirect -file [file join $report_dir saif_coverage.rpt] {report_saif -hierarchy}
redirect -file [file join $report_dir clock_gating.rpt] {
  report_clock_gating -multi_stage -verbose
}
redirect -file [file join $report_dir power_hierarchy.rpt] {
  report_power -hierarchy -levels 4
}
redirect -file [file join $report_dir power_summary.rpt] {report_power}

set config_fp [open [file join $report_dir run_config.rpt] w]
puts $config_fp "top=$top_name"
puts $config_fp "corner=$env(FA_CORNER)"
puts $config_fp "clock_period_ns=$env(FA_CLOCK_PERIOD)"
puts $config_fp "ddc=$ddc_file"
puts $config_fp "ddc_sha256=$env(FA_DDC_SHA256)"
puts $config_fp "saif=$saif_file"
puts $config_fp "saif_sha256=$env(FA_SAIF_SHA256)"
puts $config_fp "saif_strip_path=$strip_path"
puts $config_fp "rtl_hash=$env(FA_RTL_HASH)"
puts $config_fp "standard_cell_db=$env(FA_STD_DB)"
puts $config_fp "sram_db=$env(FA_SRAM_DB)"
close $config_fp

exit
