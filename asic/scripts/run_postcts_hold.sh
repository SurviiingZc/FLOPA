#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
: "${POSTCTS_NETLIST:?POSTCTS_NETLIST is required}"
: "${POSTCTS_SDC:?POSTCTS_SDC is required}"
: "${POSTCTS_SPEF:?POSTCTS_SPEF is required}"

TOP="${POSTCTS_TOP:-attention_accel_top}"
for input_file in "$POSTCTS_NETLIST" "$POSTCTS_SDC" "$POSTCTS_SPEF"; do
  test -s "$input_file"
done
if [[ ! "$TOP" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "invalid POSTCTS_TOP: $TOP" >&2
  exit 2
fi

# shellcheck source=library_paths.sh
source "$ROOT_DIR/asic/scripts/library_paths.sh"
fa_select_libraries "$ROOT_DIR" ff
if [ ! -s "$FA_SRAM_DB" ]; then
  "$ROOT_DIR/asic/scripts/prepare_sram_lib.sh" ff
fi

RUN_DIR="$ROOT_DIR/asic/pt/work/hold/ff/$TOP"
LOG_DIR="$ROOT_DIR/asic/pt/logs"
mkdir -p "$RUN_DIR/reports" "$LOG_DIR"

export FA_ROOT="$ROOT_DIR"
export FA_POSTCTS_TOP="$TOP"
export FA_POSTCTS_NETLIST="$(readlink -f "$POSTCTS_NETLIST")"
export FA_POSTCTS_SDC="$(readlink -f "$POSTCTS_SDC")"
export FA_POSTCTS_SPEF="$(readlink -f "$POSTCTS_SPEF")"
export FA_POSTCTS_WORK="$RUN_DIR"

cd "$RUN_DIR"
set +e
pt_shell -f "$ROOT_DIR/asic/scripts/postcts_hold.tcl" \
  2>&1 | tee "$LOG_DIR/postcts_hold_${TOP}_ff.log"
PT_STATUS=${PIPESTATUS[0]}
set -e
if [ "$PT_STATUS" -ne 0 ]; then
  echo "Post-CTS hold signoff failed; inspect $RUN_DIR/reports" >&2
  exit "$PT_STATUS"
fi
echo "Post-CTS FF/SPEF hold signoff passed: $RUN_DIR/reports"
