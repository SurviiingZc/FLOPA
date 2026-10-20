# Read-only inspection of the frozen F0 DDC. No compile or write_ddc commands.
source [file join $env(FA_ROOT) asic scripts library_setup.tcl]
read_ddc $env(FA_DDC_FILE)
current_design attention_accel_top
if {![link]} { error "Frozen DDC link failed" }
set task_output $env(FA_CLOCK_AUDIT_DIR)
file mkdir $task_output
redirect -file [file join $task_output top_clock_net.rpt] {
    report_net [get_nets clk]
}
redirect -file [file join $task_output top_clock_port.rpt] {
    report_port -verbose [get_ports clk]
}
redirect -file [file join $task_output net_attributes.rpt] {
    list_attributes -application -class net
}
catch {redirect -file [file join $task_output units.rpt] {report_units}}
set task_handle [open [file join $task_output clock_pins.rpt] w]
puts $task_handle "register_clock_pins=[sizeof_collection [all_registers -clock_pins]]"
set task_nets [get_nets -of_objects [all_registers -clock_pins]]
puts $task_handle "register_clock_nets=[sizeof_collection $task_nets]"
set task_rows {}
foreach_in_collection task_net $task_nets {
    set task_cap [get_attribute -quiet $task_net total_capacitance_max]
    if {[string is double -strict $task_cap]} {
        lappend task_rows [list [get_object_name $task_net] $task_cap]
    }
}
puts $task_handle "Top clock-net capacitances (pF), per-net reported load:"
foreach task_row [lrange [lsort -real -decreasing -index 1 $task_rows] 0 39] {
    puts $task_handle $task_row
}
close $task_handle
exit
