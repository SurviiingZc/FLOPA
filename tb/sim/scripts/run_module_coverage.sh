#!/usr/bin/env bash
set -euo pipefail

# Collect direct RTL coverage from module TBs. Each module testbench has a
# different hierarchy and may use reduced parameters, so its VDB is reported
# independently rather than being automatically merged into the integration
# hierarchy. This prevents URG from silently dropping shape-mismatched data.
SIM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT_DIR="${OUT_DIR:-$SIM_ROOT/build/module_coverage}"
VCS_BIN="${VCS:-vcs}"

default_tops=(
  tb_fa_clear_replica
  tb_accel_regfile tb_accel_scheduler tb_perf_counter
  tb_axi4_slave_if tb_axi4_master_write
  tb_fsa_fused_array tb_fa_signed_mult_pipe2 tb_fa_unsigned_mult_pipe2
  tb_fsa_fused_pe tb_fsa_stripe tb_fsa_controller tb_score_scale_pipe tb_fsa_pv_engine
  tb_banked_sram tb_output_buffer tb_o_accumulator_bank tb_pingpong_buffer tb_qkv_tile_cache
  tb_online_normalizer tb_pwl_exp_unit tb_reciprocal_lut
  tb_attention_accel_top
)

if (($#)); then
  tops=("$@")
else
  tops=("${default_tops[@]}")
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
cd "$SIM_ROOT"

cleanup_transients() {
  rm -f "$SIM_ROOT"/flex*.log "$SIM_ROOT"/ucli.key
  rm -rf "$SIM_ROOT/csrc"
}
trap cleanup_transients EXIT

summary="$OUT_DIR/summary.txt"
printf '%-32s %s\n' "TEST" "SCORE LINE COND TOGGLE BRANCH" > "$summary"
for top in "${tops[@]}"; do
  test_dir="$OUT_DIR/$top"
  cov_dir="$test_dir/coverage.vdb"
  mkdir -p "$test_dir/csrc" "$cov_dir"

  "$VCS_BIN" -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb \
    +define+ATTN_ASIC -f filelists/asic_models.f \
    -Mdir="$test_dir/csrc" -cm line+cond+tgl+branch -cm_dir "$cov_dir" \
    -top "$top" -f filelists/rtl.f -f filelists/module_tb.f \
    -l "$test_dir/compile.log" -o "$test_dir/simv"

  (
    cd "$test_dir"
    ./simv +fsdb+autoflush +no_notifier +notimingcheck \
      "+FSDB_FILE=$test_dir/$top.fsdb" \
      -cm line+cond+tgl+branch -cm_dir "$cov_dir" -cm_name "$top" \
      -l "$test_dir/run.log"
  )

  if grep -Eq '\[FAIL\]|\[TIMEOUT\]' "$test_dir/run.log" || \
     ! grep -Fq "[PASS] $top" "$test_dir/run.log"; then
    echo "module coverage test failed: $top (see $test_dir/run.log)" >&2
    exit 1
  fi
  urg -dir "$cov_dir" -report "$test_dir/urg" -format text >/dev/null
  score=$(awk '/Total Coverage Summary/{getline; getline; print; exit}' \
    "$test_dir/urg/dashboard.txt")
  printf '%-32s %s\n' "$top" "$score" >> "$summary"
done

echo "module coverage summary: $summary"
echo "integration coverage remains: $SIM_ROOT/build/uvm_regression/coverage.vdb"
