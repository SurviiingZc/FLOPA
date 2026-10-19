#!/usr/bin/env bash
set -euo pipefail

task_root=/data/workspaces/zhangcheng/flopa_eval_f2
task_f0=/data/workspaces/zhangcheng/flash_attention
task_source="$task_f0/paper_test/experiments/20261018"
task_run="$task_root/paper_test/f2_validation"
mkdir -p "$task_run/build" "$task_run/results"
cd "$task_root/tb/sim"
vcs -full64 -sverilog -timescale=1ns/1ps +define+ATTN_ASIC \
    -f filelists/asic_models.f -f filelists/rtl.f \
    "$task_source/src/tb_paper_replay.sv" -top tb_paper_replay \
    -Mdir="$task_run/build/csrc" -o "$task_run/build/simv" \
    -l "$task_run/build/compile.log" > "$task_run/build/compile_console.log" 2>&1
cd "$task_run/build"
for task_case in '64 3 5 2' '72 33 65 2' '128 31 32 2' '72 32 32 1'; do
    read -r task_d task_nq task_nkv task_h <<< "$task_case"
    task_name="d${task_d}_q${task_nq}_kv${task_nkv}_h${task_h}"
    ./simv +VECTOR_DIR="$task_source/replay_smoke/$task_name" \
        +RESULT="$task_run/results/$task_name.csv" +NQ="$task_nq" +NKV="$task_nkv" \
        +HEADS="$task_h" +DIM="$task_d" +SCORE_SCALE=00080001 +OUT_SCALE=000f0001 \
        +CLK_PERIOD_NS=1.6 +no_notifier +notimingcheck \
        -l "$task_run/results/$task_name.log" > "$task_run/results/$task_name.console" 2>&1
    grep -Fq '[PASS] tb_paper_replay' "$task_run/results/$task_name.log"
    cmp "$task_source/replay_smoke/$task_name/o.bin" \
        "$task_run/results/$task_name.csv.observed.bin"
done
git -C "$task_root" rev-parse HEAD > "$task_run/validated_commit.txt"
find "$task_run/results" -type f -print0 | sort -z | xargs -0 sha256sum \
    > "$task_run/results_sha256.txt"
echo F2_DIRECTED_REPLAY_PASS

# Keep synthesis gated behind the byte-exact smoke suite and use the same libraries.
mkdir -p "$task_root/asic/dc/work/lib"
cp -n "$task_f0/asic/dc/work/lib/uhdsp_256x8m4s_tt0p9v25c.db" \
    "$task_root/asic/dc/work/lib/"
export CLOCK_PERIOD=1.6
export DC_CORES=8
export CORNER=tt
export EXPECTED_TOP_SRAM_MACROS=480
export EXPECTED_TOP_RTL_ICGS=28
"$task_root/asic/scripts/run_synth.sh" evaluation_f2 attention_accel_top
echo F2_SYNTHESIS_COMPLETE
