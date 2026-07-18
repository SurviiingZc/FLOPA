#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CORNER="${1:-tt}"
LIB_ROOT="/data/public/STD/tcbn28hpcplusbwp12t30p140_190a/tcbn28hpcplusbwp12t30p140_180a_ccs/TSMCHOME/digital/Front_End/timing_power_noise/CCS/tcbn28hpcplusbwp12t30p140_180a"
case "$CORNER" in
  tt) STD_DB="$LIB_ROOT/tcbn28hpcplusbwp12t30p140tt0p9v25c_ccs.db" ;;
  ss) STD_DB="$LIB_ROOT/tcbn28hpcplusbwp12t30p140ssg0p9v125c_ccs.db" ;;
  *) echo "usage: $0 [tt|ss]" >&2; exit 2 ;;
esac

RUN_DIR="$ROOT_DIR/asic/dc/work/pe_timing/$CORNER"
LOG_DIR="$ROOT_DIR/asic/dc/logs"

rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR" "$LOG_DIR"

export FA_ROOT="$ROOT_DIR"
export FA_DC_WORK="$RUN_DIR"
export FA_STD_DB="$STD_DB"

cd "$RUN_DIR"
dc_shell -64bit -f "$ROOT_DIR/asic/scripts/pe_timing.tcl" \
  2>&1 | tee "$LOG_DIR/pe_timing_${CORNER}.log"

if grep -q '^Error:' "$LOG_DIR/pe_timing_${CORNER}.log"; then
  echo "PE timing synthesis reported a DC error" >&2
  exit 1
fi
if grep -q 'unmapped logic' "$RUN_DIR/reports/area.rpt"; then
  echo "PE timing synthesis contains unmapped logic" >&2
  exit 1
fi
