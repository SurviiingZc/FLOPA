set jobs 2
if {$argc >= 1} {
    set jobs [lindex $argv 0]
}

proc check_linux_cips {} {
    set bd_file [get_files -quiet system.bd]
    if {[llength $bd_file] != 1} {
        error "Expected exactly one system.bd"
    }
    open_bd_design $bd_file
    set cips [get_bd_cells -quiet versal_cips_0]
    if {[llength $cips] != 1} {
        error "Versal CIPS instance not found"
    }
    set config [get_property CONFIG.PS_PMC_CONFIG $cips]
    for {set index 0} {$index < 7} {incr index} {
        set enable_key PS_GEN_IPI${index}_ENABLE
        set master_key PS_GEN_IPI${index}_MASTER
        if {![dict exists $config $enable_key] ||
            [dict get $config $enable_key] != 1 ||
            ![dict exists $config $master_key] ||
            [dict get $config $master_key] ne "A72"} {
            close_bd_design [get_bd_designs system]
            error "CIPS A72 IPI channel $index is not Linux-ready; rebuild the project"
        }
    }
    close_bd_design [get_bd_designs system]
}

set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_dir]
set build_dir [file join $vivado_dir build]
set project_file [file join $build_dir project dit_fa_vck190.xpr]
set output_dir [file join $build_dir output]

if {![file exists $project_file]} {
    puts stderr "Vivado project not found: $project_file"
    exit 1
}

file mkdir $output_dir
open_project $project_file
check_linux_cips

set impl_run [get_runs impl_1]
set impl_status [get_property STATUS $impl_run]
puts "Current implementation status: $impl_status"

set pdi_files [glob -nocomplain \
    [file join $build_dir project dit_fa_vck190.runs impl_1 *.pdi]]
if {[llength $pdi_files] == 0} {
    launch_runs $impl_run -jobs $jobs -to_step write_device_image
    wait_on_run $impl_run
    set impl_status [get_property STATUS $impl_run]
    if {![string match "*Complete*" $impl_status]} {
        puts stderr "Device-image generation failed: $impl_status"
        close_project
        exit 1
    }
    set pdi_files [glob -nocomplain \
        [file join $build_dir project dit_fa_vck190.runs impl_1 *.pdi]]
}

if {[llength $pdi_files] == 0} {
    puts stderr "Implementation completed without producing a PDI"
    close_project
    exit 1
}

open_run $impl_run
set setup_wns [get_property SLACK \
    [lindex [get_timing_paths -quiet -delay_type max -max_paths 1] 0]]
set hold_whs [get_property SLACK \
    [lindex [get_timing_paths -quiet -delay_type min -max_paths 1] 0]]
if {$setup_wns < 0.0 || $hold_whs < 0.0} {
    puts stderr "Refusing hardware export: setup WNS=$setup_wns, hold WHS=$hold_whs"
    close_project
    exit 1
}

foreach pdi $pdi_files {
    file copy -force $pdi [file join $output_dir [file tail $pdi]]
}
write_hw_platform -fixed -include_bit -force \
    -file [file join $output_dir dit_fa_vck190.xsa]

puts "Hardware export complete: setup WNS=$setup_wns, hold WHS=$hold_whs"
close_project
