if {$argc != 2} {
    puts stderr "Usage: package_rtl_kernel.tcl <output.xo> <build_dir>"
    exit 2
}

set output_xo [file normalize [lindex $argv 0]]
set build_dir [file normalize [lindex $argv 1]]
set script_dir [file dirname [file normalize [info script]]]
set vitis_dir [file dirname $script_dir]
set fpga_dir [file dirname $vitis_dir]
set repo_dir [file dirname $fpga_dir]
set project_dir [file join $build_dir rtl_kernel_project]
set ip_dir [file join $build_dir ip_repo dit_fa]
set kernel_xml [file join $vitis_dir kernel.xml]

file delete -force $project_dir $ip_dir $output_xo
file mkdir [file dirname $output_xo]
file mkdir [file dirname $ip_dir]

create_project -force dit_fa_rtl_kernel $project_dir \
    -part xcvc1902-vsva2197-2MP-e-S
set_property target_language Verilog [current_project]
set_property default_lib xil_defaultlib [current_project]

set rtl_files [list]
foreach rtl_subdir {axi common control memory compute softmax} {
    set pattern [file join $repo_dir rtl $rtl_subdir *.v]
    set rtl_files [concat $rtl_files [glob -nocomplain $pattern]]
}
lappend rtl_files [file join $repo_dir rtl attention_accel_top.v]
lappend rtl_files [file join $fpga_dir rtl attention_fpga_top.v]
lappend rtl_files [file join $fpga_dir rtl axis_tile_loader.v]
set rtl_files [concat $rtl_files [glob [file join $vitis_dir rtl *.v]]]
set header_files [glob [file join $repo_dir rtl common *.vh]]

add_files -norecurse [lsort $rtl_files]
add_files -norecurse [lsort $header_files]
set_property include_dirs [list [file join $repo_dir rtl common]] \
    [current_fileset]
set_property top dit_fa_kernel [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $ip_dir -vendor surviiingzc.com \
    -library kernel -taxonomy /KernelIP -import_files -set_current true
set core [ipx::current_core]
set_property name dit_fa $core
set_property display_name {DIT-FA Vitis RTL Kernel} $core
set_property description {DIT-FA attention accelerator for VCK190 XRT} $core
set_property version 1.0 $core
set_property core_revision 1 $core
set_property sdx_kernel true $core
set_property sdx_kernel_type rtl $core

foreach busif {s_axi_control m_axi_gmem s_axis_tile} {
    ipx::associate_bus_interfaces -busif $busif -clock ap_clk $core
}

ipx::check_integrity -quiet $core
ipx::save_core $core
package_xo -force -xo_path $output_xo -kernel_name dit_fa \
    -ip_directory $ip_dir -kernel_xml $kernel_xml
close_project

puts "RTL kernel XO: $output_xo"
