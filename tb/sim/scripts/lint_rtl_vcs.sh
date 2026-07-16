#!/usr/bin/env bash
set -euo pipefail

SIM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT_DIR="$SIM_ROOT/build/lint_rtl"

mkdir -p "$OUT_DIR" "$OUT_DIR/csrc"
cd "$SIM_ROOT"

cleanup_transients() {
  rm -f "$SIM_ROOT"/flex*.log "$SIM_ROOT/ucli.key"
  rm -rf "$SIM_ROOT/csrc"
}
trap cleanup_transients EXIT

vcs -full64 +v2k +lint=all -timescale=1ns/1ps \
  -Mdir="$OUT_DIR/csrc" \
  -top attention_accel_top \
  -l "$OUT_DIR/compile.log" \
  -o "$OUT_DIR/simv" \
  -f "$SIM_ROOT/filelists/rtl.f"
