#!/usr/bin/env bash
set -euo pipefail

# Compile once against the ASIC implementation, retain one log per seed, and
# merge RTL code plus UVM functional coverage with VCS.  The characterized SRAM
# model is always linked so RTL regression exercises the same storage backend as
# synthesis.  Its specify checks are disabled at runtime because this is a
# zero-delay RTL functional run, not an SRAM timing-signoff run.
# A VCS simulation may return zero even when UVM reports an error, so the
# post-run summary check is the regression pass/fail criterion.
SIM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT_DIR="${OUT_DIR:-$SIM_ROOT/build/uvm_regression}"
VCS_BIN="${VCS:-vcs}"
COV_DIR="$OUT_DIR/coverage.vdb"

tests=(
  "smoke|fa_smoke_test|1|"
  "axi_backpressure|fa_axi_backpressure_test|19|"
  "random_1x1|fa_random_qkv_test|101|+FA_SEQ_Q=32 +FA_SEQ_KV=32"
  "prefill_causal_1x1|fa_random_qkv_test|102|+FA_SEQ_Q=32 +FA_SEQ_KV=32 +FA_CAUSAL_EN=1"
  "prefill_2x2|fa_random_qkv_test|103|+FA_SEQ_Q=64 +FA_SEQ_KV=64"
  "prefill_kv_tail|fa_random_qkv_test|104|+FA_SEQ_Q=64 +FA_SEQ_KV=65"
  "prefill_long|fa_random_qkv_test|401|+FA_SEQ_Q=512 +FA_SEQ_KV=512 +FA_CAUSAL_EN=1 +FA_READY_LOW_PCT=25"
  "prefill_tail_causal|fa_random_qkv_test|105|+FA_SEQ_Q=65 +FA_SEQ_KV=65 +FA_CAUSAL_EN=1 +FA_READY_LOW_PCT=50"
  "random_decode_long|fa_random_qkv_test|203|+FA_DECODE_EN=1 +FA_SEQ_KV=256 +FA_CAUSAL_EN=1 +FA_READY_LOW_PCT=25"
  "random_decode_noncausal|fa_random_qkv_test|205|+FA_DECODE_EN=1 +FA_SEQ_KV=256 +FA_CAUSAL_EN=0"
  "axi_4k_boundary|fa_random_qkv_test|206|+FA_SEQ_Q=32 +FA_SEQ_KV=32 +FA_O_BASE=ff0"
  "pwl_corner|fa_pwl_corner_test|106|"
  "arith_rounding|fa_arith_rounding_test|107|"
  "positive_saturation|fa_positive_saturation_test|108|"
  "negative_saturation|fa_negative_saturation_test|109|"
  "decode_smoke|fa_decode_smoke_test|201|"
  "decode_illegal|fa_decode_illegal_config_test|204|"
  "illegal_config|fa_illegal_config_test|7|"
  "register_access|fa_register_access_test|8|"
  "axi_bresp_error|fa_axi_bresp_error_test|9|"
)

# A regression VDB is authoritative only when it contains this invocation's
# tests. Remove this script-owned output tree before compiling so re-used
# -cm_name directories cannot retain historical coverage.
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR" "$OUT_DIR/csrc" "$COV_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
COV_DIR=$(cd "$COV_DIR" && pwd)
cd "$SIM_ROOT"

cleanup_transients() {
  rm -f "$SIM_ROOT"/flex*.log "$SIM_ROOT"/ucli.key
  rm -f "$OUT_DIR"/flex*.log "$OUT_DIR"/ucli.key
  rm -rf "$SIM_ROOT/csrc"
}
trap cleanup_transients EXIT

"$VCS_BIN" -full64 -sverilog -ntb_opts uvm -timescale=1ns/1ps \
  -debug_access+all -kdb -lca -Mdir="$OUT_DIR/csrc" \
  -cm line+cond+tgl+branch -cm_dir "$COV_DIR" \
  +define+ATTN_ASIC -f filelists/asic_models.f -f filelists/rtl.f \
  -f filelists/uvm.f -top tb_top \
  -l "$OUT_DIR/compile.log" -o "$OUT_DIR/simv"

failures=0
for entry in "${tests[@]}"; do
  IFS='|' read -r run_name test_name seed plusargs <<< "$entry"
  read -r -a plusarg_array <<< "$plusargs"
  log="$OUT_DIR/${run_name}.log"

  "$OUT_DIR/simv" +UVM_TESTNAME="$test_name" +ntb_random_seed="$seed" "${plusarg_array[@]}" \
    +no_notifier +notimingcheck \
    -cm line+cond+tgl+branch -cm_dir "$COV_DIR" -cm_name "$run_name" \
    -l "$log" || failures=$((failures + 1))

  if ! grep -Eq 'UVM_ERROR :[[:space:]]*0' "$log" || \
     ! grep -Eq 'UVM_FATAL :[[:space:]]*0' "$log"; then
    echo "FAIL $run_name test=$test_name seed=$seed (see $log)" >&2
    failures=$((failures + 1))
  else
    echo "PASS $run_name test=$test_name seed=$seed"
  fi
  grep -E '\[FCOV_MATH\]|\[FCOV_SUMMARY\]' "$log" || true
done

urg -dir "$COV_DIR" -report "$OUT_DIR/urg" -format both

if (( failures != 0 )); then
  echo "UVM regression completed with $failures failing test(s); coverage is in $OUT_DIR/urg" >&2
  exit 1
fi

echo "UVM regression passed; coverage is in $OUT_DIR/urg"
