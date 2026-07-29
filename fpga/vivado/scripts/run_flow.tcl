if {$argc < 1} {
    puts stderr "Usage: run_flow.tcl <project|synth|impl> ?jobs?"
    exit 2
}

proc worst_slack {delay_type} {
    set paths [get_timing_paths -quiet -delay_type $delay_type -max_paths 1]
    if {[llength $paths] == 0} {
        return "N/A"
    }
    return [get_property SLACK [lindex $paths 0]]
}

set action [lindex $argv 0]
set jobs 8
if {$argc >= 2} {
    set jobs [lindex $argv 1]
}
if {$action ni {project synth impl}} {
    puts stderr "Unknown action: $action"
    exit 2
}

set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_dir]
set build_dir [file join $vivado_dir build]
set report_dir [file join $build_dir reports]
set output_dir [file join $build_dir output]
set summary_file [file join $report_dir flow_summary.txt]
set synth_min_wns 0.0
if {[info exists ::env(SYNTH_MIN_WNS)]} {
    set synth_min_wns $::env(SYNTH_MIN_WNS)
}
file mkdir $report_dir
file mkdir $output_dir
foreach stale_output [glob -nocomplain \
    [file join $output_dir *.pdi] [file join $output_dir *.xsa]] {
    file delete -force $stale_output
}

source [file join $script_dir create_project.tcl]
if {$action eq "project"} {
    exit 0
}

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match "*Complete*" $synth_status]} {
    puts stderr "Synthesis failed: $synth_status"
    exit 1
}
open_run synth_1
report_utilization -file [file join $report_dir post_synth_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 200 -nworst 20 \
    -file [file join $report_dir post_synth_timing.rpt]
report_timing -delay_type max -slack_lesser_than 0.0 \
    -max_paths 2000 -nworst 20 \
    -file [file join $report_dir post_synth_setup_violations.rpt]
report_timing -delay_type min -slack_lesser_than 0.0 \
    -max_paths 2000 -nworst 20 \
    -file [file join $report_dir post_synth_hold_violations.rpt]
report_methodology -file [file join $report_dir post_synth_methodology.rpt]

set synth_setup_wns [worst_slack max]
set synth_hold_whs [worst_slack min]
set dsp_used [llength [get_cells -quiet -hierarchical -filter {REF_NAME == DSP58}]]
set dsp_available [llength \
    [get_sites -quiet -filter {SITE_TYPE == DSP58_PRIMARY}]]
set summary [open $summary_file w]
puts $summary "requested_pl_freq_mhz=$pl_freq_mhz"
puts $summary "synth_setup_wns_ns=$synth_setup_wns"
puts $summary "synth_hold_whs_ns=$synth_hold_whs"
puts $summary "synth_min_wns_ns=$synth_min_wns"
puts $summary "dsp58_used=$dsp_used"
puts $summary "dsp58_available=$dsp_available"
close $summary

if {$synth_setup_wns eq "N/A"} {
    puts stderr "Synthesis produced no setup timing paths"
    exit 1
}
if {$synth_setup_wns < $synth_min_wns} {
    puts stderr "Synthesis setup WNS $synth_setup_wns ns is below the gate"
    puts stderr "Required synthesis WNS: $synth_min_wns ns"
    exit 1
}
if {$dsp_available > 0 && $dsp_used > $dsp_available} {
    puts stderr "DSP58 usage $dsp_used exceeds device capacity $dsp_available"
    exit 1
}
if {$action eq "synth"} {
    exit 0
}

launch_runs impl_1 -jobs $jobs -to_step write_device_image
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
if {![string match "*Complete*" $impl_status]} {
    puts stderr "Implementation failed: $impl_status"
    exit 1
}
open_run impl_1
report_utilization -hierarchical \
    -file [file join $report_dir post_route_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 20 \
    -file [file join $report_dir post_route_timing.rpt]
report_clock_utilization -file [file join $report_dir clock_utilization.rpt]
report_drc -file [file join $report_dir post_route_drc.rpt]
report_methodology -file [file join $report_dir post_route_methodology.rpt]
set route_setup_wns [worst_slack max]
set route_hold_whs [worst_slack min]
set summary [open $summary_file a]
puts $summary "route_setup_wns_ns=$route_setup_wns"
puts $summary "route_hold_whs_ns=$route_hold_whs"
close $summary

if {$route_setup_wns eq "N/A" || $route_hold_whs eq "N/A"} {
    puts stderr "Implementation produced incomplete timing results"
    exit 1
}
if {$route_setup_wns < 0.0 || $route_hold_whs < 0.0} {
    puts stderr "Post-route timing failed"
    puts stderr "Setup WNS: $route_setup_wns ns; hold WHS: $route_hold_whs ns"
    exit 1
}

set pdi_files [glob -nocomplain \
    [file join $build_dir project *.runs impl_1 *.pdi]]
if {[llength $pdi_files] == 0} {
    puts stderr "Implementation completed without producing a PDI"
    exit 1
}
foreach pdi $pdi_files {
    file copy -force $pdi [file join $output_dir [file tail $pdi]]
}
write_hw_platform -fixed -include_bit -force \
    -file [file join $output_dir dit_fa_vck190.xsa]
