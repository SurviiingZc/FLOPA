#!/usr/bin/env bash
set -euo pipefail
task_root=/data/workspaces/zhangcheng/flash_attention
task_run="$task_root/paper_test/experiments/20261018"
source "$task_root/asic/scripts/library_paths.sh"
fa_select_libraries "$task_root" tt
export FA_ROOT="$task_root"
export FA_DC_WORK="$task_run/clock_load_audit_20261020/work"
export FA_DDC_FILE="$task_root/asic/dc/work/synth/tt/diffusion_runtime_d"
FA_DDC_FILE="$FA_DDC_FILE/attention_accel_top/results/attention_accel_top.ddc"
export FA_CLOCK_AUDIT_DIR="$task_run/clock_load_audit_20261020/reports"
mkdir -p "$FA_DC_WORK" "$FA_CLOCK_AUDIT_DIR"
cd "$FA_DC_WORK"
dc_shell -64bit -f "$task_run/src/clock_load_audit.tcl" > console.log 2>&1
