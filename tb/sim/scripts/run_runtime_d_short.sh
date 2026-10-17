#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
sim_dir="$root_dir/tb/sim"
out_dir="${RUNTIME_D_OUT_DIR:-$sim_dir/build/runtime_d}"
mkdir -p "$out_dir/tmp"
export TMPDIR="$out_dir/tmp"
cd "$sim_dir"

# One executable is compiled once and reused for all dimensions and jobs.
# No SAIF, waveform, debug database or duplicated simulation build is created.
if [[ ${RUNTIME_D_SKIP_COMPILE:-0} != 1 ]]; then
    python3 "$root_dir/tb/sim/scripts/runtime_d_manifest.py" before "$root_dir" "$out_dir"
    vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
        +define+ATTN_ASIC -f filelists/asic_models.f \
        -f filelists/rtl.f -f filelists/uvm.f -top tb_top \
        -Mdir="$out_dir/csrc" -o "$out_dir/simv" \
        -l "$out_dir/compile.log" >"$out_dir/compile_console.log" 2>&1
    vcs -full64 -sverilog -timescale=1ns/1ps +define+ATTN_ASIC \
        -f filelists/asic_models.f -f filelists/rtl.f \
        ../module_tb/compute/tb_runtime_arithmetic.sv -top tb_runtime_arithmetic \
        -Mdir="$out_dir/arithmetic_csrc" -o "$out_dir/arithmetic_simv" \
        -l "$out_dir/arithmetic_compile.log" >"$out_dir/arithmetic_compile.console.log" 2>&1
    python3 "$root_dir/tb/sim/scripts/runtime_d_manifest.py" after "$root_dir" "$out_dir"
else
    python3 "$root_dir/tb/sim/scripts/runtime_d_manifest.py" check "$root_dir" "$out_dir"
fi
test -x "$out_dir/simv"

tests=${RUNTIME_D_TESTS:-"fa_runtime_d_smoke_test fa_runtime_d_range_test \
fa_runtime_d_boundary_test fa_runtime_d_multihead_test \
fa_runtime_d_control_test fa_runtime_d_arith_test"}
read -r -a test_names <<< "$tests"
printf '%s\n' "${test_names[@]}" >"$out_dir/selected_tests.txt"
failed=0
for test_name in "${test_names[@]}"; do
    if [[ ! $test_name =~ ^[A-Za-z_][A-Za-z_0-9]*$ ]]; then
        echo "Invalid test name: $test_name" >&2
        exit 2
    fi
    echo "RUN $test_name"
    "$out_dir/simv" +UVM_TESTNAME="$test_name" +ntb_random_seed=301 \
        +UVM_MAX_QUIT_COUNT=16 +no_notifier +notimingcheck \
        -l "$out_dir/$test_name.log" >"$out_dir/$test_name.console.log" 2>&1 || failed=1
done
python3 "$root_dir/tb/sim/scripts/summarize_runtime_d.py" "$out_dir" || failed=1
"$out_dir/arithmetic_simv" +no_notifier +notimingcheck \
    -l "$out_dir/arithmetic_module.log" >"$out_dir/arithmetic_module.console.log" 2>&1 || failed=1
python3 "$root_dir/tb/sim/scripts/runtime_d_manifest.py" module "$root_dir" "$out_dir" || failed=1
exit "$failed"
