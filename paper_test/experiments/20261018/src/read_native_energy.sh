#!/usr/bin/env bash
set -euo pipefail

task_root=/data/workspaces/zhangcheng/flash_attention
task_run="$task_root/paper_test/experiments/20261018"
task_mapped="$task_root/asic/dc/work/synth/tt/diffusion_runtime_d/attention_accel_top"
task_job="$1"
[[ "$task_job" =~ ^power_native_(pixart|wan)_n(1024|2304|4096|9216|16384)_s301$ ]]
source "$task_root/asic/scripts/library_paths.sh"
fa_select_libraries "$task_root" tt
export FA_ACTUAL_PIN_LOAD="${FA_ACTUAL_PIN_LOAD:-1}"
export FA_ROOT="$task_root"
export FA_DC_WORK="$task_run/jobs/$task_job/power_work"
export FA_CLOCK_PERIOD=1.6
export FA_DDC_FILE="$task_mapped/results/attention_accel_top.ddc"
export FA_SAIF_FILE="$task_run/jobs/$task_job/activity.saif"
export FA_SAIF_STRIP_PATH=tb_paper_replay/dut
export FA_SAIF_INSTANCE=attention_accel_top
export FA_POWER_REPORT_DIR="$task_run/jobs/$task_job/power_reports"
if [[ "${FA_ACTUAL_PIN_LOAD:-0}" == 1 ]]; then
    export FA_DC_WORK="$task_run/jobs/$task_job/power_work_actual_pin_load"
    export FA_POWER_REPORT_DIR="$task_run/jobs/$task_job/power_reports_actual_pin_load"
fi
export FA_RTL_HASH
FA_RTL_HASH=$(awk -F= '$1=="FA_RTL_HASH" {print $2}' "$task_mapped/reports/run_config.rpt")
export FA_DDC_SHA256
FA_DDC_SHA256=$(sha256sum "$FA_DDC_FILE" | awk '{print $1}')
export FA_SAIF_SHA256
FA_SAIF_SHA256=$(sha256sum "$FA_SAIF_FILE" | awk '{print $1}')
mkdir -p "$FA_DC_WORK" "$FA_POWER_REPORT_DIR"
cd "$FA_DC_WORK"
dc_shell -64bit -f "$task_run/src/saif_power_exact.tcl" > console.log 2>&1
if grep -Eq '^\s*(Error:|ERROR:)' console.log; then
    exit 2
fi
if grep -Eq '\(PWR-18\)|\(PWR-19\)' \
        console.log "$FA_POWER_REPORT_DIR/saif_coverage.rpt"; then
    exit 2
fi
