#!/usr/bin/env bash
set -euo pipefail

# Compile once, retain one log per seed, and merge UVM covergroups with VCS.
# A VCS simulation may return zero even when UVM reports an error, so the
# post-run summary check is the regression pass/fail criterion.
SIM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT_DIR="${OUT_DIR:-$SIM_ROOT/build/uvm_regression}"
VCS_BIN="${VCS:-vcs}"
COV_DIR="$OUT_DIR/coverage.vdb"

tests=(
  "fa_smoke_test:1"
  "fa_axi_backpressure_test:19"
  "fa_random_qkv_test:101"
  "fa_pwl_corner_test:102"
  "fa_arith_rounding_test:106"
  "fa_positive_saturation_test:103"
  "fa_negative_saturation_test:104"
  "fa_causal_random_test:105"
  "fa_illegal_config_test:7"
)

mkdir -p "$OUT_DIR" "$OUT_DIR/csrc" "$COV_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
COV_DIR=$(cd "$COV_DIR" && pwd)
cd "$SIM_ROOT"

cleanup_transients() {
  rm -f "$SIM_ROOT"/flex*.log "$SIM_ROOT"/ucli.key
  rm -rf "$SIM_ROOT/csrc"
}
trap cleanup_transients EXIT

"$VCS_BIN" -full64 -sverilog -ntb_opts uvm -timescale=1ns/1ps \
  -debug_access+all -kdb -lca -Mdir="$OUT_DIR/csrc" \
  -cm line+cond+tgl+branch -cm_dir "$COV_DIR" \
  -f filelists/rtl.f -f filelists/uvm.f -top tb_top \
  -l "$OUT_DIR/compile.log" -o "$OUT_DIR/simv"

failures=0
for entry in "${tests[@]}"; do
  test_name=${entry%%:*}
  seed=${entry##*:}
  log="$OUT_DIR/${test_name}.log"

  "$OUT_DIR/simv" +UVM_TESTNAME="$test_name" +ntb_random_seed="$seed" \
    -cm_name "$test_name" -l "$log" || failures=$((failures + 1))

  if ! grep -Eq 'UVM_ERROR :[[:space:]]*0' "$log" || \
     ! grep -Eq 'UVM_FATAL :[[:space:]]*0' "$log"; then
    echo "FAIL $test_name seed=$seed (see $log)" >&2
    failures=$((failures + 1))
  else
    echo "PASS $test_name seed=$seed"
  fi
  grep -E '\[FCOV_MATH\]|\[FCOV_SUMMARY\]' "$log" || true
done

urg -dir "$COV_DIR" -report "$OUT_DIR/urg" -format both

if (( failures != 0 )); then
  echo "UVM regression completed with $failures failing test(s); coverage is in $OUT_DIR/urg" >&2
  exit 1
fi

echo "UVM regression passed; coverage is in $OUT_DIR/urg"
