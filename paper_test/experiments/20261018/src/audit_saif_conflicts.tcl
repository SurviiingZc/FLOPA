set task_root /data/workspaces/zhangcheng/flash_attention
set task_run [file join $task_root paper_test experiments 20261018]
set task_design [file join $task_root asic dc work synth tt diffusion_runtime_d \
    attention_accel_top results attention_accel_top.ddc]
set env(FA_ROOT) $task_root
set task_std /data/public/STD/tcbn28hpcplusbwp12t30p140_190a
set env(FA_STD_DB) [file join $task_std tcbn28hpcplusbwp12t30p140_180a_ccs TSMCHOME \
    digital Front_End timing_power_noise CCS tcbn28hpcplusbwp12t30p140_180a \
    tcbn28hpcplusbwp12t30p140tt0p9v25c_ccs.db]
set env(FA_SRAM_DB) [file join $task_root asic dc work lib uhdsp_256x8m4s_tt0p9v25c.db]
source [file join $task_root asic scripts library_setup.tcl]
read_ddc $task_design
current_design attention_accel_top
if {![link]} {
    error "DDC link failed"
}
identify_clock_gating
# Distinguish stale DDC annotations from contradictory aliases within this SAIF.
reset_switching_activity
unsuppress_message PWR-18
set_message_info -id PWR-18 -limit 30
set task_saif [file join $task_run results gate_pilot_d72_n32.saif]
set task_exact [info exists env(FA_EXACT_SAIF_NAMES)]
if {$task_exact} {
    set task_read [read_saif -input $task_saif -instance_name tb_paper_replay/dut]
} else {
    set task_read [read_saif -input $task_saif -instance_name tb_paper_replay/dut \
        -auto_map_names]
}
if {!$task_read} {
    error "SAIF annotation failed"
}
set task_reports [file join $task_run saif_conflict_audit]
if {$task_exact} {
    set task_reports [file join $task_run saif_exact_name_audit]
}
file mkdir $task_reports
redirect -file [file join $task_reports coverage_after_reset.rpt] {
    report_saif -hierarchy
}
redirect -file [file join $task_reports power_after_reset.rpt] {
    report_power
}
exit
