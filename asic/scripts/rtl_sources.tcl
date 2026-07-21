if {![info exists root_dir]} {
  error "root_dir must be defined before sourcing rtl_sources.tcl"
}

# Keep this list in dependency order. Headers are found through search_path.
set fa_rtl_relative_files [list \
  rtl/common/fa_clock_gate.v \
  rtl/common/fa_signed_mult_pipe2.v \
  rtl/axi/axi4_slave_if.v \
  rtl/axi/axi4_master_write.v \
  rtl/control/accel_regfile.v \
  rtl/control/accel_scheduler.v \
  rtl/control/perf_counter.v \
  rtl/memory/asic_sram_1024x16.v \
  rtl/memory/asic_sram_256xwide.v \
  rtl/memory/banked_sram.v \
  rtl/memory/bram_buffer.v \
  rtl/memory/o_accumulator_bank.v \
  rtl/memory/output_buffer.v \
  rtl/memory/pingpong_buffer.v \
  rtl/memory/qkv_tile_cache.v \
  rtl/memory/stream_fifo.v \
  rtl/memory/uram_bank.v \
  rtl/compute/scale_requant_unit.v \
  rtl/compute/fsa_delay_line.v \
  rtl/compute/fsa_fused_pe.v \
  rtl/compute/fsa_stripe.v \
  rtl/compute/fsa_fused_array.v \
  rtl/compute/fsa_controller.v \
  rtl/compute/fsa_qk_engine.v \
  rtl/compute/fsa_pv_engine.v \
  rtl/softmax/pwl_exp_unit.v \
  rtl/softmax/reciprocal_lut.v \
  rtl/softmax/online_normalizer.v \
  rtl/attention_accel_top.v]

set fa_rtl_files {}
foreach relative_file $fa_rtl_relative_files {
  set absolute_file [file normalize [file join $root_dir $relative_file]]
  if {![file isfile $absolute_file]} {
    error "RTL source does not exist: $absolute_file"
  }
  lappend fa_rtl_files $absolute_file
}
