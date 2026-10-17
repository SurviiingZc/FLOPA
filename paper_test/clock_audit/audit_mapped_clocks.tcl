# Read-only mapped-DDC clock-coverage audit for Synopsys DC V-2023.12-SP5.
# This script never compiles, optimizes, creates clocks, or writes design artifacts.

set audit_summary [dict create]
set audit_rank 0
set audit_reasons [list]
set clock_trace_cache [dict create]
set sequential_names [dict create]

proc audit_value {key value} {
    global audit_summary
    dict set audit_summary $key $value
}

proc audit_issue {status key detail} {
    global audit_rank audit_reasons
    audit_value $key $status
    audit_value ${key}_detail $detail
    lappend audit_reasons "$status: $key: $detail"
    if {$status eq "FAIL"} {
        set audit_rank 2
    } elseif {$audit_rank == 0} {
        set audit_rank 1
    }
}

proc audit_check {key condition detail} {
    if {$condition} {
        audit_value $key PASS
    } else {
        audit_issue FAIL $key $detail
    }
}

proc audit_json_escape {text} {
    return [string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $text]
}

proc audit_finish {} {
    global audit_summary audit_rank audit_reasons report_dir
    set status PASS
    if {$audit_rank == 1} {
        set status UNKNOWN
    } elseif {$audit_rank == 2} {
        set status FAIL
    }
    audit_value overall_status $status
    audit_value reasons [join $audit_reasons "\n"]
    set fp [open [file join $report_dir summary.json] w]
    puts $fp "\{"
    set keys [lsort [dict keys $audit_summary]]
    set index 0
    foreach key $keys {
        incr index
        set comma [expr {$index < [llength $keys] ? "," : ""}]
        set value [audit_json_escape [dict get $audit_summary $key]]
        puts $fp "    \"[audit_json_escape $key]\": \"${value}\"${comma}"
    }
    puts $fp "\}"
    close $fp
    puts "CLOCK_AUDIT_STATUS=$status"
    return $status
}

proc audit_report {name body} {
    global report_dir
    set target [file join $report_dir $name]
    if {[catch {uplevel 1 [list redirect -file $target $body]} message]} {
        audit_issue UNKNOWN report_$name $message
        return ""
    }
    set fp [open $target r]
    set text [read $fp]
    close $fp
    if {[regexp {(^|\n)[ \t]*Error:} $text]} {
        audit_issue UNKNOWN report_$name "DC reported an error; inspect $name"
    }
    return $text
}

proc audit_names {name objects} {
    global report_dir
    set fp [open [file join $report_dir $name] w]
    foreach object_name [lsort [get_object_name $objects]] {
        puts $fp $object_name
    }
    close $fp
}

proc audit_sha256 {path} {
    return [lindex [exec sha256sum $path] 0]
}

proc audit_config {path} {
    set fp [open $path r]
    set text [read $fp]
    close $fp
    set values [dict create]
    foreach line [split $text "\n"] {
        if {[regexp {^([^=]+)=(.*)$} $line -> key value]} {
            if {[dict exists $values $key]} {
                error "duplicate run_config key: $key"
            }
            dict set values $key $value
        }
    }
    return $values
}

# Structural tracing is separate from timing-clock ownership. It accepts the
# known ICG CP->Q connection and single-input combinational buffers/inverters.
# Other drivers are UNKNOWN, never silently treated as valid clock paths.
proc audit_trace_clock {sink_name visited} {
    global clock_trace_cache sequential_names
    if {[dict exists $clock_trace_cache $sink_name]} {
        return [dict get $clock_trace_cache $sink_name]
    }
    if {[lsearch -exact $visited $sink_name] >= 0} {
        return [dict create status FAIL detail "clock-driver cycle at $sink_name"]
    }
    lappend visited $sink_name
    set sink [get_pins -quiet -exact $sink_name]
    if {[sizeof_collection $sink] != 1} {
        return [dict create status UNKNOWN detail "missing/ambiguous pin $sink_name"]
    }
    set nets [get_nets -quiet -segments -of_objects $sink]
    set ports [get_ports -quiet -of_objects $nets -filter "direction == in"]
    set drivers [get_pins -quiet -of_objects $nets -leaf -filter "direction == out"]
    set count [expr {[sizeof_collection $ports] + [sizeof_collection $drivers]}]
    if {$count != 1} {
        return [dict create status UNKNOWN detail "$count drivers of $sink_name"]
    }
    if {[sizeof_collection $ports] == 1} {
        set source [get_object_name $ports]
        if {$source eq "clk"} {
            set result [dict create status PASS detail "clk -> $sink_name"]
        } else {
            set result [dict create status FAIL detail "unexpected clock source $source"]
        }
    } else {
        set driver_name [get_object_name $drivers]
        set cell [get_cells -quiet -of_objects $drivers]
        if {[sizeof_collection $cell] != 1} {
            return [dict create status UNKNOWN detail "ambiguous cell for $driver_name"]
        }
        set cell_name [get_object_name $cell]
        set reference [get_attribute $cell ref_name]
        if {[string match CKLNQD*BWP12T30P140 $reference] &&
            [file tail $driver_name] eq "Q"} {
            set next_pin "${cell_name}/CP"
        } elseif {![dict exists $sequential_names $cell_name]} {
            set inputs [get_pins -of_objects $cell -filter "direction == in"]
            set outputs [get_pins -of_objects $cell -filter "direction == out"]
            if {[sizeof_collection $inputs] != 1 || [sizeof_collection $outputs] != 1} {
                return [dict create status UNKNOWN detail "unsupported driver $reference"]
            }
            set next_pin [get_object_name $inputs]
        } else {
            return [dict create status FAIL detail "clock driven by $cell_name/$reference"]
        }
        set result [audit_trace_clock $next_pin $visited]
        dict set result detail "[dict get $result detail] -> $driver_name -> $sink_name"
    }
    dict set clock_trace_cache $sink_name $result
    return $result
}

proc audit_path_clock {path expected_pin} {
    set clock [get_attribute $path endpoint_clock]
    set clock_name [get_object_name $clock]
    set clock_pin [get_attribute $path endpoint_clock_pin]
    set clock_pin_name [get_object_name $clock_pin]
    if {$clock_name ne "core_clk" || $clock_pin_name ne $expected_pin} {
        return [dict create status FAIL clock $clock_name pin $clock_pin_name]
    }
    return [dict create status PASS clock $clock_name pin $clock_pin_name]
}

proc audit_main {} {
    global env report_dir sequential_names audit_rank
    foreach variable {FA_ROOT FA_DDC_FILE FA_RUN_CONFIG FA_CLOCK_AUDIT_DIR} {
        if {![info exists env($variable)]} {
            error "required environment variable missing: $variable"
        }
    }
    set root_dir [file normalize $env(FA_ROOT)]
    set ddc_file [file normalize $env(FA_DDC_FILE)]
    set config_file [file normalize $env(FA_RUN_CONFIG)]
    set config [audit_config $config_file]
    foreach key {top standard_cell_db sram_db clock_period_ns} {
        if {![dict exists $config $key]} {
            error "required run_config key missing: $key"
        }
    }
    set env(FA_STD_DB) [dict get $config standard_cell_db]
    set env(FA_SRAM_DB) [dict get $config sram_db]
    set before_hash [audit_sha256 $ddc_file]
    audit_value ddc $ddc_file
    audit_value ddc_sha256 $before_hash
    audit_value run_config $config_file
    audit_value run_config_sha256 [audit_sha256 $config_file]
    audit_value standard_cell_db $env(FA_STD_DB)
    audit_value sram_db $env(FA_SRAM_DB)
    foreach pair {{FA_STD_DB FA_STD_DB_HASH} {FA_SRAM_DB FA_SRAM_DB_HASH}} {
        set variable [lindex $pair 0]
        set key [lindex $pair 1]
        set actual [audit_sha256 $env($variable)]
        audit_value ${variable}_sha256 $actual
        if {![dict exists $config $key]} {
            audit_issue UNKNOWN library_$variable "run_config has no $key"
        } else {
            audit_check library_$variable [expr {$actual eq [dict get $config $key]}] \
                "library hash does not match run_config"
        }
    }
    source [file join $root_dir asic scripts library_setup.tcl]
    read_ddc $ddc_file
    set loaded_top [get_designs -quiet [dict get $config top]]
    if {[sizeof_collection $loaded_top] != 1} {
        error "read_ddc did not load exactly one requested top design"
    }
    current_design [dict get $config top]
    if {![link]} {
        error "mapped DDC could not link against run_config libraries"
    }
    audit_report check_design.rpt {check_design}
    audit_report clocks.rpt {report_clock -attributes -nosplit}
    audit_report clock_skew.rpt {report_clock -skew -nosplit}
    audit_report clock_gating_from_ddc.rpt {
        report_clock_gating -multi_stage -verbose
    }
    set pre_all_edge [all_registers -edge_triggered -cells]
    set pre_clocked_edge [all_registers -edge_triggered -clock core_clk -cells]
    audit_value preidentify_edge_registers_total [sizeof_collection $pre_all_edge]
    audit_value preidentify_edge_registers_core_clk [sizeof_collection $pre_clocked_edge]
    identify_clock_gating
    set post_all_edge [all_registers -edge_triggered -cells]
    set post_clocked_edge [all_registers -edge_triggered -clock core_clk -cells]
    audit_value postidentify_edge_registers_total [sizeof_collection $post_all_edge]
    audit_value postidentify_edge_registers_core_clk [sizeof_collection $post_clocked_edge]
    set lost_core [remove_from_collection $pre_clocked_edge $post_clocked_edge]
    set gained_core [remove_from_collection $post_clocked_edge $pre_clocked_edge]
    audit_names core_clk_members_lost_after_identify.txt $lost_core
    audit_names core_clk_members_gained_after_identify.txt $gained_core
    audit_value postidentify_core_clk_members_lost [sizeof_collection $lost_core]
    audit_value postidentify_core_clk_members_gained [sizeof_collection $gained_core]
    if {[sizeof_collection $pre_all_edge] != [sizeof_collection $post_all_edge] ||
        [sizeof_collection $lost_core] != 0 || [sizeof_collection $gained_core] != 0} {
        audit_issue UNKNOWN identify_clock_coverage \
            "edge-register count or core_clk membership changed; manual review required"
    } else {
        audit_value identify_clock_coverage PASS
    }
    set gating_text [audit_report clock_gating_identified.rpt {
        report_clock_gating -multi_stage -verbose
    }]
    audit_report power_clock_identified.rpt {report_power}
    audit_value power_clock_identified_scope \
        "vectorless/default-activity estimate after classification; no SAIF was read"
    foreach item {
        {preexisting {Number of pre-existing clock gating elements} 28}
        {automatic {Number of tool-inserted clock gating elements} 0}
    } {
        set label [lindex $item 0]
        set match_text [lindex $item 1]
        set expected [lindex $item 2]
        set reported ""
        foreach line [split $gating_text "\n"] {
            if {[string first $match_text $line] >= 0} {
                set field [string trim [lindex [split $line |] 2]]
                if {[regexp {^([0-9]+)} $field -> number]} {
                    set reported $number
                }
                break
            }
        }
        audit_value reported_${label}_icgs $reported
        if {$reported eq ""} {
            audit_issue UNKNOWN ${label}_icg_report "missing count in gating report"
        } else {
            audit_check ${label}_icg_report [expr {$reported == $expected}] \
                "unexpected clock-gating report count"
        }
    }
    audit_report design_attributes.rpt {report_attribute -design -nosplit}
    audit_report available_pin_attributes.rpt {list_attributes -application -class pin}
    audit_report available_net_attributes.rpt {list_attributes -application -class net}
    audit_report available_path_attributes.rpt {list_attributes -application -class timing_path}
    set detailed [audit_report check_timing_detailed.rpt {
        check_timing -include {generic gated_clock ideal_timing clock_no_period data_check_no_clock}
    }]
    set unconstrained [audit_report unconstrained_endpoints.rpt {
        check_timing -override_defaults {unconstrained_endpoints}
    }]
    if {$unconstrained eq ""} {
        audit_issue UNKNOWN unconstrained_endpoints "empty/failed check_timing report"
    } elseif {[regexp {(^|\n)[ \t]*(Warning:|Error:)} $unconstrained]} {
        audit_issue FAIL unconstrained_endpoints "inspect unconstrained_endpoints.rpt"
    } else {
        audit_value unconstrained_endpoints PASS
    }
    set core_clock [get_clocks -quiet core_clk]
    audit_check core_clock_present [expr {[sizeof_collection $core_clock] == 1}] \
        "exactly one core_clk object is required"
    audit_check single_clock [expr {[sizeof_collection [all_clocks]] == 1}] \
        "unexpected additional clock objects"
    if {[sizeof_collection $core_clock] != 1} {
        error "cannot continue clock ownership checks without core_clk"
    }
    set actual_period [get_attribute $core_clock period]
    audit_value core_clock_period_ns $actual_period
    set expected_period [dict get $config clock_period_ns]
    audit_check clock_period_match [expr {abs($actual_period - $expected_period) < 1e-9}] \
        "DDC clock period differs from run_config"

    set all_edge [all_registers -edge_triggered -cells]
    set clocked_edge [all_registers -edge_triggered -clock core_clk -cells]
    set missing_edge [remove_from_collection $all_edge $clocked_edge]
    audit_value edge_registers_total [sizeof_collection $all_edge]
    audit_value edge_registers_core_clk [sizeof_collection $clocked_edge]
    audit_value no_clock_edge_registers [sizeof_collection $missing_edge]
    audit_check no_clock_ff [expr {[sizeof_collection $missing_edge] == 0}] \
        "FFs missing core_clk membership; inspect no_clock_registers.txt"
    audit_check nonempty_registers [expr {[sizeof_collection $all_edge] > 0}] \
        "no edge-triggered registers found"
    audit_names no_clock_registers.txt $missing_edge
    set all_clock_pins [all_registers -clock core_clk -clock_pins -include_icg]
    set clock_pin_names [dict create]
    foreach pin_name [get_object_name $all_clock_pins] {
        dict set clock_pin_names $pin_name 1
    }
    foreach cell_name [get_object_name [all_registers -cells -include_icg]] {
        dict set sequential_names $cell_name 1
    }
    set gates [get_cells -quiet -hierarchical -filter "ref_name =~ CKLNQD*BWP12T30P140"]
    set macros [get_cells -quiet -hierarchical -filter "ref_name == uhdsp_256x8m4s"]
    audit_value mapped_icg_count [sizeof_collection $gates]
    audit_value mapped_sram_count [sizeof_collection $macros]
    audit_check icg_count [expr {[sizeof_collection $gates] == 28}] "expected 28 mapped ICGs"
    audit_check sram_count [expr {[sizeof_collection $macros] == 480}] "expected 480 SRAMs"
    audit_names mapped_icgs.txt $gates
    audit_names mapped_srams.txt $macros

    set fp [open [file join $report_dir sram_clock_ownership.tsv] w]
    puts $fp "macro\tCLK_in_core_register_collection\tstructural\tSTA_owner\tSTA_clock_pin"
    foreach_in_collection macro $macros {
        set name [get_object_name $macro]
        set clock_name "${name}/CLK"
        set trace [audit_trace_clock $clock_name [list]]
        set structural [dict get $trace status]
        set member [dict exists $clock_pin_names $clock_name]
        set owner UNKNOWN
        set owner_pin UNKNOWN
        if {$structural ne "PASS"} {
            audit_issue $structural sram_trace_$name [dict get $trace detail]
        }
        set pins [get_pins -of_objects $macro -filter "direction == in"]
        set clock_pin [get_pins -quiet -exact $clock_name]
        set data_pins [remove_from_collection $pins $clock_pin]
        if {[catch {
            set paths [get_timing_paths -to $data_pins -delay_type max -max_paths 1]
            if {[sizeof_collection $paths] == 0} {
                error "no timed SRAM input path found"
            }
            set proof [audit_path_clock [index_collection $paths 0] $clock_name]
            set owner [dict get $proof clock]
            set owner_pin [dict get $proof pin]
            if {[dict get $proof status] ne "PASS"} {
                audit_issue FAIL sram_sta_$name "wrong endpoint clock or clock pin"
            }
        } message]} {
            audit_issue UNKNOWN sram_sta_$name $message
        }
        puts $fp "$name\t$member\t$structural\t$owner\t$owner_pin"
    }
    close $fp

    set fp [open [file join $report_dir icg_enable_checks.tsv] w]
    puts $fp "gate\tCP_structural\tdelay_type\tpaths\tclock\tclock_pin\tslack_ns"
    foreach_in_collection gate $gates {
        set name [get_object_name $gate]
        set clock_name "${name}/CP"
        set trace [audit_trace_clock $clock_name [list]]
        if {[dict get $trace status] ne "PASS"} {
            audit_issue [dict get $trace status] icg_trace_$name [dict get $trace detail]
        }
        set enable [get_pins -quiet -exact "${name}/E"]
        if {[sizeof_collection $enable] != 1} {
            audit_issue UNKNOWN icg_enable_$name "missing/ambiguous E pin"
            continue
        }
        foreach delay_type {max min} {
            set count 0
            set owner UNKNOWN
            set owner_pin UNKNOWN
            set slack UNKNOWN
            if {[catch {
                set paths [get_timing_paths -to $enable -delay_type $delay_type -max_paths 1]
                set count [sizeof_collection $paths]
                if {$count == 0} {
                    error "no timed ICG enable path found"
                }
                set path [index_collection $paths 0]
                set proof [audit_path_clock $path $clock_name]
                set owner [dict get $proof clock]
                set owner_pin [dict get $proof pin]
                set slack [get_attribute $path slack]
                if {[dict get $proof status] ne "PASS"} {
                    audit_issue FAIL icg_sta_${delay_type}_$name "wrong enable clock ownership"
                }
                if {$slack < 0.0} {
                    audit_issue FAIL icg_slack_${delay_type}_$name "slack=$slack ns"
                }
                set safe_name [string map {/ __} $name]
                audit_report icg_${safe_name}_${delay_type}.rpt {
                    report_timing -to $enable -delay_type $delay_type -max_paths 1 \
                        -path_type full_clock_expanded -nets -transition_time -nosplit
                }
            } message]} {
                audit_issue UNKNOWN icg_sta_${delay_type}_$name $message
            }
            set structural [dict get $trace status]
            puts $fp "$name\t$structural\t$delay_type\t$count\t$owner\t$owner_pin\t$slack"
        }
    }
    close $fp
    audit_report timing_max.rpt {
        report_timing -delay_type max -path_type full_clock_expanded -max_paths 20 -nosplit
    }
    audit_report timing_min.rpt {
        report_timing -delay_type min -path_type full_clock_expanded -max_paths 20 -nosplit
    }
    audit_report constraints.rpt {report_constraint -all_violators}
    audit_report min_cap_constraints_highprec.rpt {
        report_constraint -min_capacitance -all_violators -significant_digits 8 -nosplit
    }
    foreach net_name {u_fused_array/n25936 u_fused_array/n113247} {
        set net [get_nets -quiet -exact $net_name]
        if {[sizeof_collection $net] != 1} {
            audit_issue UNKNOWN min_cap_net_$net_name "missing/ambiguous mapped net"
            continue
        }
        set safe_name [string map {/ __} $net_name]
        audit_report min_cap_${safe_name}_net.rpt {
            report_net -connections -verbose -min -significant_digits 8 -nosplit $net
        }
        audit_report min_cap_${safe_name}_attributes.rpt {
            report_attribute -nosplit $net
        }
        set drivers [get_pins -of_objects $net -leaf -filter "direction == out"]
        set driver_cells [get_cells -of_objects $drivers]
        audit_value min_cap_${safe_name}_drivers [get_object_name $drivers]
        if {[sizeof_collection $driver_cells] == 0} {
            audit_issue UNKNOWN min_cap_driver_$net_name "no mapped driver cell found"
        } else {
            audit_report min_cap_${safe_name}_driver_cells.rpt {
                report_cell -connections -verbose -significant_digits 8 -nosplit $driver_cells
            }
            set driver_lib_pins [get_lib_pins -of_objects $drivers]
            audit_report min_cap_${safe_name}_driver_lib_pins.rpt {
                report_attribute -nosplit $driver_lib_pins
            }
        }
    }
    set fp [open [file join $report_dir worst_hold_paths.tsv] w]
    puts $fp "startpoint\tendpoint\tmodule_class\tslack_ns\tclock\tclock_pin"
    set hold_paths [get_timing_paths -delay_type min -slack_lesser_than 0.0 \
        -max_paths 20 -nworst 1 -path_type full_clock_expanded]
    set worst_hold ""
    foreach_in_collection path $hold_paths {
        set start [get_object_name [get_attribute $path startpoint]]
        set end [get_object_name [get_attribute $path endpoint]]
        set slack [get_attribute $path slack]
        set owner [get_object_name [get_attribute $path endpoint_clock]]
        set owner_pin [get_object_name [get_attribute $path endpoint_clock_pin]]
        set module_class [lindex [split $end /] 0]
        if {$worst_hold eq "" || $slack < $worst_hold} {
            set worst_hold $slack
        }
        puts $fp "$start\t$end\t$module_class\t$slack\t$owner\t$owner_pin"
    }
    close $fp
    audit_value worst_hold_reported_paths [sizeof_collection $hold_paths]
    audit_value worst_hold_slack_ns $worst_hold
    audit_value worst_hold_scope \
        "up to20 worst violating paths; full violation count remains in synthesis qor.rpt"
    audit_value check_timing_no_clock_mode explicit_collection_difference_and_sram_STA_owner
    audit_value check_timing_no_clock_note \
        "DC check_timing has no documented no_clock keyword; explicit no-clock checks used"
    set after_hash [audit_sha256 $ddc_file]
    audit_value ddc_sha256_after $after_hash
    audit_check ddc_unchanged [expr {$before_hash eq $after_hash}] "DDC changed during audit"
}

if {![info exists env(FA_CLOCK_AUDIT_DIR)]} {
    error "FA_CLOCK_AUDIT_DIR is required"
}
set report_dir [file normalize $env(FA_CLOCK_AUDIT_DIR)]
file mkdir $report_dir
if {[catch {audit_main} message]} {
    audit_issue UNKNOWN fatal_audit_error $message
}
set audit_final_status [audit_finish]
if {$audit_final_status eq "PASS"} {
    exit 0
}
exit 2
