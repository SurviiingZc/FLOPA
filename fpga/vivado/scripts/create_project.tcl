set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_dir]
set fpga_dir [file dirname $vivado_dir]
set repo_dir [file dirname $fpga_dir]
set build_dir [file join $vivado_dir build]
set project_dir [file join $build_dir project]
set project_name dit_fa_vck190

set part_name xcvc1902-vsva2197-2MP-e-S
set board_part xilinx.com:vck190:part0:3.2
set pl_freq_mhz 170
if {[info exists ::env(FREQ_MHZ)]} {
    set pl_freq_mhz $::env(FREQ_MHZ)
}

file mkdir $build_dir
create_project -force $project_name $project_dir -part $part_name
set_property board_part $board_part [current_project]
set_property source_mgmt_mode All [current_project]
set_property target_language Verilog [current_project]
set_property default_lib xil_defaultlib [current_project]

set rtl_files [list]
foreach rtl_subdir {axi common control memory compute softmax} {
    set pattern [file join $repo_dir rtl $rtl_subdir *.v]
    set rtl_files [concat $rtl_files [glob -nocomplain $pattern]]
}
lappend rtl_files [file join $repo_dir rtl attention_accel_top.v]
set rtl_files [concat $rtl_files [glob [file join $fpga_dir rtl *.v]]]
set header_files [glob [file join $repo_dir rtl common *.vh]]

add_files -norecurse [lsort $rtl_files]
add_files -norecurse [lsort $header_files]
set_property include_dirs [list [file join $repo_dir rtl common]] [current_fileset]
update_compile_order -fileset sources_1

source [file join $script_dir create_system_bd.tcl]
create_system_bd $pl_freq_mhz
assign_bd_address -export_to_file [file join $build_dir address_map.csv] -force

set bd_file [get_files system.bd]
generate_target all $bd_file
export_ip_user_files -of_objects $bd_file -no_script -sync -force -quiet
set wrapper [make_wrapper -files $bd_file -top]
add_files -norecurse $wrapper
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property strategy Performance_ExploreWithRemap [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE \
    AggressiveExplore [get_runs impl_1]
set clock_opt_script [file join $script_dir post_route_clock_opt.tcl]
if {![file readable $clock_opt_script]} {
    error "Post-route clock optimization script is not readable: $clock_opt_script"
}
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.TCL.POST \
    $clock_opt_script [get_runs impl_1]

set manifest [open [file join $build_dir project_manifest.txt] w]
puts $manifest "project=$project_name"
puts $manifest "part=$part_name"
puts $manifest "board_part=$board_part"
puts $manifest "requested_pl_freq_mhz=$pl_freq_mhz"
puts $manifest "place_design_directive=Explore"
puts $manifest "route_design_directive=AggressiveExplore"
puts $manifest "post_route_phys_opt_directive=AggressiveExplore"
puts $manifest "post_route_clock_opt=1"
set actual_freq [get_property CONFIG.FREQ_HZ \
    [get_bd_pins /pl_clock_wizard/clk_out1]]
puts $manifest "actual_pl_freq_hz=$actual_freq"
puts $manifest "vivado=[version -short]"
close $manifest
