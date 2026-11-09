#!/usr/bin/env bash
set -euo pipefail

task_root=/data/workspaces/zhangcheng/flash_attention
task_dir="$task_root/paper_test/experiments/20261018"
task_netlist="$task_root/asic/dc/work/synth/tt/diffusion_runtime_d/attention_accel_top"
task_build="$task_dir/gate_pilot_build"
mkdir -p "$task_build"
df -Pk "$task_dir" > "$task_build/disk_before.txt"
task_free=$(df -Pk "$task_dir" | awk 'NR==2 {print $4}')
if ((task_free < 8 * 1024 * 1024)); then
    echo 'Less than 8 GiB free; gate compile stopped' >&2
    exit 2
fi
sha256sum "$task_netlist/results/attention_accel_top_mapped.v" \
    "$task_netlist/results/attention_accel_top.ddc" \
    "$task_dir/src/tb_paper_replay.sv" > "$task_build/input_sha256.txt"
cd "$task_root/tb/sim"
vcs -full64 -sverilog -timescale=1ns/1ps -debug_access+all \
    +incdir+../../rtl/common -f filelists/asic_models.f \
    "$task_netlist/results/attention_accel_top_mapped.v" \
    "$task_dir/src/tb_paper_replay.sv" -top tb_paper_replay \
    -Mdir="$task_build/csrc" -o "$task_build/simv" \
    -l "$task_build/compile.log" > "$task_build/compile_console.log" 2>&1
cd "$task_build"
./simv +VECTOR_DIR="$task_dir/replay_smoke/d72_q32_kv32_h1" \
    +RESULT="$task_dir/results/gate_pilot_d72_n32.csv" \
    +NQ=32 +NKV=32 +HEADS=1 +DIM=72 \
    +SCORE_SCALE=00080001 +OUT_SCALE=000f0001 +CLK_PERIOD_NS=1.6 \
    +SAIF_ENABLE +SAIF_FILE="$task_dir/results/gate_pilot_d72_n32.saif" \
    +no_notifier +notimingcheck -l "$task_dir/results/gate_pilot_d72_n32.log"
grep -Fq '[PASS] tb_paper_replay' "$task_dir/results/gate_pilot_d72_n32.log"
sha256sum "$task_dir/results/gate_pilot_d72_n32.saif" \
    "$task_dir/results/gate_pilot_d72_n32.csv" > "$task_build/output_sha256.txt"
echo 'GATE_PILOT_COMPLETE (synthetic flow qualification, not model power result)'
