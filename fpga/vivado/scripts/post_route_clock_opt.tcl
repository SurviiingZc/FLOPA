proc worst_setup_slack {} {
    set paths [get_timing_paths -quiet -delay_type max -max_paths 1]
    if {[llength $paths] == 0} {
        return "N/A"
    }
    return [get_property SLACK [lindex $paths 0]]
}

set clock_opt_wns_before [worst_setup_slack]
phys_opt_design -clock_opt
set clock_opt_wns_after [worst_setup_slack]
puts "POST_ROUTE_CLOCK_OPT: WNS before=$clock_opt_wns_before after=$clock_opt_wns_after"
