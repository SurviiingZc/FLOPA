if {$argc != 1} {
    puts stderr "Usage: analyze_pe_floorplan.tcl <routed_checkpoint>"
    exit 2
}

set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_dir]
set report_dir [file join $vivado_dir build reports]
set report_file [file join $report_dir pe_floorplan_baseline.csv]
set device_file [file join $report_dir pe_floorplan_device.csv]

file mkdir $report_dir
open_checkpoint [lindex $argv 0]

set output [open $report_file w]
puts $output "stripe,row,col,dsp_loc,dsp_clock_region"

foreach dsp [get_cells -hierarchical -filter {REF_NAME == DSP58}] {
    set name [get_property NAME $dsp]
    if {![regexp {g_stripe\[([0-9]+)\]\.u_stripe/g_pe_row\[([0-9]+)\]\.g_pe_col\[([0-9]+)\]\.u_pe} \
              $name -> stripe row col]} {
        continue
    }

    set loc [get_property LOC $dsp]
    set site [get_sites -quiet $loc]
    set clock_region ""
    if {[llength $site] != 0} {
        set clock_region [get_property CLOCK_REGION $site]
    }
    puts $output "$stripe,$row,$col,$loc,$clock_region"
}
close $output

set output [open $device_file w]
puts $output "site,site_type,clock_region"
foreach site [get_sites -quiet -filter {SITE_TYPE == DSP58_PRIMARY}] {
    puts $output "[get_property NAME $site],DSP58_PRIMARY,[get_property CLOCK_REGION $site]"
}
close $output

close_design
