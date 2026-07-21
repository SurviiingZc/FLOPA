proc fa_env_or_default {name default_value} {
  if {[info exists ::env($name)]} {
    return $::env($name)
  }
  return $default_value
}

proc fa_apply_core_constraints {clock_period} {
  set setup_uncertainty [fa_env_or_default FA_SETUP_UNCERTAINTY 0.100]
  set hold_uncertainty [fa_env_or_default FA_HOLD_UNCERTAINTY 0.020]
  set clock_transition [fa_env_or_default FA_CLOCK_TRANSITION 0.050]
  set input_delay [fa_env_or_default FA_INPUT_DELAY 0.200]
  set output_delay [fa_env_or_default FA_OUTPUT_DELAY 0.200]
  set input_transition [fa_env_or_default FA_INPUT_TRANSITION 0.050]
  set output_load [fa_env_or_default FA_OUTPUT_LOAD 0.020]
  set max_transition [fa_env_or_default FA_MAX_TRANSITION 0.300]
  set max_fanout [fa_env_or_default FA_MAX_FANOUT 16]

  set clock_ports [get_ports -quiet clk]
  if {[sizeof_collection $clock_ports] == 0} {
    error "current design has no clk port"
  }
  create_clock -name core_clk -period $clock_period $clock_ports
  set_clock_uncertainty -setup $setup_uncertainty [get_clocks core_clk]
  set_clock_uncertainty -hold $hold_uncertainty [get_clocks core_clk]
  set_clock_transition $clock_transition [get_clocks core_clk]
  set_fix_hold [get_clocks core_clk]

  set data_inputs [remove_from_collection [all_inputs] $clock_ports]
  set reset_ports [get_ports -quiet rst_n]
  if {[sizeof_collection $reset_ports] > 0} {
    set data_inputs [remove_from_collection $data_inputs $reset_ports]
    set_false_path -from $reset_ports
    set_ideal_network $reset_ports
  }
  if {[sizeof_collection $data_inputs] > 0} {
    set_input_delay $input_delay -clock core_clk $data_inputs
    set_input_transition $input_transition $data_inputs
  }

  set data_outputs [all_outputs]
  if {[sizeof_collection $data_outputs] > 0} {
    set_output_delay $output_delay -clock core_clk $data_outputs
    set_load $output_load $data_outputs
  }

  set_max_transition $max_transition [current_design]
  set_max_fanout $max_fanout [current_design]
}

# Optional explicit minimum-data-path requirement for SRAM inputs. The default is
# zero because Liberty hold plus hold uncertainty already models the requirement;
# a nonzero value is reserved for a separately justified physical constraint.
proc fa_apply_sram_hold_constraints {macro_cells} {
  if {[sizeof_collection $macro_cells] == 0} {
    return
  }
  set min_delay [fa_env_or_default FA_SRAM_INPUT_MIN_DELAY 0.000]
  set macro_inputs [get_pins -quiet -of_objects $macro_cells \
      -filter "direction == in"]
  set macro_clocks [filter_collection $macro_inputs "full_name =~ */CLK"]
  set macro_data_inputs [remove_from_collection $macro_inputs $macro_clocks]
  if {$min_delay > 0.0 && [sizeof_collection $macro_data_inputs] > 0} {
    set_min_delay $min_delay -to $macro_data_inputs
  }
}
