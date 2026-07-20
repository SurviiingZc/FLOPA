#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CORNER="${CORNER:-${1:-tt}}"
CLOCK_PERIOD="${CLOCK_PERIOD:-3.2}"
EXPECTED_TOP_SRAM_MACROS="${EXPECTED_TOP_SRAM_MACROS:-480}"
RUN_DIR="$ROOT_DIR/asic/dc/work/rtl_check/$CORNER"
LIB_DIR="$ROOT_DIR/asic/dc/work/lib"
LOG_DIR="$ROOT_DIR/asic/dc/logs"

# shellcheck source=library_paths.sh
source "$ROOT_DIR/asic/scripts/library_paths.sh"
fa_select_libraries "$ROOT_DIR" "$CORNER"

if [[ ! "$CLOCK_PERIOD" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "CLOCK_PERIOD must be a positive number" >&2
  exit 2
fi
if [[ ! "$EXPECTED_TOP_SRAM_MACROS" =~ ^[0-9]+$ ]]; then
  echo "EXPECTED_TOP_SRAM_MACROS must be a non-negative integer" >&2
  exit 2
fi
case "$RUN_DIR" in
  "$ROOT_DIR"/asic/dc/work/rtl_check/*) ;;
  *) echo "refusing unsafe RTL-check path: $RUN_DIR" >&2; exit 2 ;;
esac

rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR" "$LIB_DIR" "$LOG_DIR"
cd "$RUN_DIR"

export FA_ROOT="$ROOT_DIR"
export FA_DC_WORK="$RUN_DIR"
export FA_CLOCK_PERIOD="$CLOCK_PERIOD"
export FA_CORNER="$CORNER"
export FA_EXPECTED_TOP_SRAM_MACROS="$EXPECTED_TOP_SRAM_MACROS"

if [ ! -s "$FA_SRAM_DB" ]; then
  "$ROOT_DIR/asic/scripts/prepare_sram_lib.sh" "$CORNER"
fi

test -s "$FA_STD_DB"
test -s "$FA_SRAM_DB"
rm -f "$RUN_DIR"/Synopsys_stack_trace_*.txt
rm -f "$RUN_DIR"/crte_*.txt
rm -f "$RUN_DIR"/flex*.log
rm -f "$RUN_DIR"/lc_command.log "$RUN_DIR"/lc_output.txt

dc_shell -64bit -f "$ROOT_DIR/asic/scripts/check_rtl.tcl" \
  2>&1 | tee "$LOG_DIR/rtl_check_${CORNER}.log"

if grep -Eq '(^|[[:space:]])(Error:|ERROR:)' "$LOG_DIR/rtl_check_${CORNER}.log"; then
  echo "RTL check reported a DC error" >&2
  exit 1
fi
test -s "$RUN_DIR/reports/check_design.rpt"
test -s "$RUN_DIR/reports/design.rpt"
test -s "$RUN_DIR/reports/run_config.rpt"
