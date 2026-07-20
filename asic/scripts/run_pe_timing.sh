#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CORNER="${CORNER:-${1:-tt}}"
CLOCK_PERIOD="${CLOCK_PERIOD:-3.2}"
DC_CORES="${DC_CORES:-4}"

# shellcheck source=library_paths.sh
source "$ROOT_DIR/asic/scripts/library_paths.sh"
fa_select_libraries "$ROOT_DIR" "$CORNER"

if [[ ! "$CLOCK_PERIOD" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "CLOCK_PERIOD must be a positive number" >&2
  exit 2
fi
if [[ ! "$DC_CORES" =~ ^[1-9][0-9]*$ ]]; then
  echo "DC_CORES must be a positive integer" >&2
  exit 2
fi

RUN_DIR="$ROOT_DIR/asic/dc/work/pe_timing/$CORNER"
LOG_DIR="$ROOT_DIR/asic/dc/logs"

case "$RUN_DIR" in
  "$ROOT_DIR"/asic/dc/work/pe_timing/*) ;;
  *) echo "refusing unsafe PE-timing path: $RUN_DIR" >&2; exit 2 ;;
esac
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR" "$LOG_DIR"

export FA_ROOT="$ROOT_DIR"
export FA_DC_WORK="$RUN_DIR"
export FA_CLOCK_PERIOD="$CLOCK_PERIOD"
export FA_CORNER="$CORNER"
export FA_DC_CORES="$DC_CORES"

if [ ! -s "$FA_SRAM_DB" ]; then
  "$ROOT_DIR/asic/scripts/prepare_sram_lib.sh" "$CORNER"
fi
test -s "$FA_STD_DB"
test -s "$FA_SRAM_DB"

cd "$RUN_DIR"
dc_shell -64bit -f "$ROOT_DIR/asic/scripts/pe_timing.tcl" \
  2>&1 | tee "$LOG_DIR/pe_timing_${CORNER}.log"

if grep -Eq '(^|[[:space:]])(Error:|ERROR:)' "$LOG_DIR/pe_timing_${CORNER}.log"; then
  echo "PE timing synthesis reported a DC error" >&2
  exit 1
fi
if grep -qi 'unmapped logic' "$RUN_DIR/reports/area.rpt"; then
  echo "PE timing synthesis contains unmapped logic" >&2
  exit 1
fi
test -s "$RUN_DIR/reports/timing_mac.rpt"
test -s "$RUN_DIR/reports/qor.rpt"
test -s "$RUN_DIR/results/fsa_fused_pe_mapped.v"
test -s "$RUN_DIR/results/fsa_fused_pe.ddc"
