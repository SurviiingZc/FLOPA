#!/usr/bin/env bash
set -euo pipefail

SIM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT_DIR="$SIM_ROOT/build/asic_sram"
SRAM_MODEL="/data/public/SRAM/uhdsp_256x8m4s/VERILOG/uhdsp_256x8m4s_tt0p9v25c.v"

mkdir -p "$OUT_DIR" "$OUT_DIR/csrc"
cd "$SIM_ROOT"

cleanup_transients() {
  rm -f "$SIM_ROOT"/flex*.log "$SIM_ROOT/ucli.key"
  rm -rf "$SIM_ROOT/csrc"
}
trap cleanup_transients EXIT

vcs -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb \
  +incdir+../../tb/module_tb/common \
  +define+ATTN_ASIC +define+UNIT_DELAY +define+no_warning \
  +define+NO_INPUT_FLOATING_CHECK \
  -Mdir="$OUT_DIR/csrc" \
  -top tb_asic_sram_backend \
  -l "$OUT_DIR/compile.log" \
  -o "$OUT_DIR/simv" \
  "$SRAM_MODEL" \
  ../../rtl/memory/asic_sram_1024x16.v \
  ../../rtl/memory/asic_sram_256xwide.v \
  ../../rtl/memory/banked_sram.v \
  ../../tb/module_tb/memory/tb_asic_sram_backend.sv

(
  cd "$OUT_DIR"
  ./simv +fsdb+autoflush -l run.log
)

if grep -Eq '\[FAIL\]|\[TIMEOUT\]' "$OUT_DIR/run.log"; then
  echo "ASIC SRAM test failed (see $OUT_DIR/run.log)" >&2
  exit 1
fi
if ! grep -Fq "[PASS] tb_asic_sram_backend" "$OUT_DIR/run.log"; then
  echo "ASIC SRAM test did not report PASS (see $OUT_DIR/run.log)" >&2
  exit 1
fi
