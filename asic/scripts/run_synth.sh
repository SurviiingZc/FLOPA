#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 GROUP TOP [TOP ...]" >&2
  exit 2
fi

GROUP="$1"
shift
TOPS=("$@")

if [[ ! "$GROUP" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "invalid group name: $GROUP" >&2
  exit 2
fi
for top in "${TOPS[@]}"; do
  if [[ ! "$top" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "invalid top name: $top" >&2
    exit 2
  fi
done

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CORNER="${CORNER:-tt}"
CLOCK_PERIOD="${CLOCK_PERIOD:-3.2}"
if [[ ! "$CLOCK_PERIOD" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "CLOCK_PERIOD must be a positive number" >&2
  exit 2
fi
STD_ROOT="/data/public/STD/tcbn28hpcplusbwp12t30p140_190a/tcbn28hpcplusbwp12t30p140_180a_ccs/TSMCHOME/digital/Front_End/timing_power_noise/CCS/tcbn28hpcplusbwp12t30p140_180a"

case "$CORNER" in
  tt)
    STD_DB="$STD_ROOT/tcbn28hpcplusbwp12t30p140tt0p9v25c_ccs.db"
    SRAM_NAME="uhdsp_256x8m4s_tt0p9v25c"
    ;;
  ss)
    STD_DB="$STD_ROOT/tcbn28hpcplusbwp12t30p140ssg0p9v125c_ccs.db"
    SRAM_NAME="uhdsp_256x8m4s_ssg0p9v125c"
    ;;
  *) echo "CORNER must be tt or ss" >&2; exit 2 ;;
esac

RUN_DIR="$ROOT_DIR/asic/dc/work/synth/$CORNER/$GROUP"
LOG_DIR="$ROOT_DIR/asic/dc/logs"
SRAM_DB="$ROOT_DIR/asic/dc/work/lib/$SRAM_NAME.db"
LOG_FILE="$LOG_DIR/synth_${GROUP}_${CORNER}.log"

test -s "$STD_DB"
if [ ! -s "$SRAM_DB" ]; then
  "$ROOT_DIR/asic/scripts/prepare_sram_lib.sh" "$CORNER"
fi
test -s "$SRAM_DB"

case "$RUN_DIR" in
  "$ROOT_DIR"/asic/dc/work/synth/*) ;;
  *) echo "refusing unsafe synthesis path: $RUN_DIR" >&2; exit 2 ;;
esac

rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR" "$LOG_DIR"

export FA_ROOT="$ROOT_DIR"
export FA_DC_WORK="$RUN_DIR"
export FA_STD_DB="$STD_DB"
export FA_SRAM_DB="$SRAM_DB"
export FA_SYNTH_TOPS="${TOPS[*]}"
export FA_CLOCK_PERIOD="$CLOCK_PERIOD"

cd "$RUN_DIR"
dc_shell -64bit -f "$ROOT_DIR/asic/scripts/synth_group.tcl" \
  2>&1 | tee "$LOG_FILE"

if grep -q '^Error:' "$LOG_FILE"; then
  echo "DC reported an error; see $LOG_FILE" >&2
  exit 1
fi

for top in "${TOPS[@]}"; do
  REPORT_DIR="$RUN_DIR/$top/reports"
  RESULT_DIR="$RUN_DIR/$top/results"
  test -s "$REPORT_DIR/qor.rpt"
  test -s "$REPORT_DIR/timing.rpt"
  test -s "$RESULT_DIR/${top}_mapped.v"
  test -s "$RESULT_DIR/${top}.ddc"
  test -s "$RESULT_DIR/${top}.sdc"
  test -s "$RESULT_DIR/${top}.sdf"
  if grep -q 'unmapped logic' "$REPORT_DIR/area.rpt"; then
    echo "$top contains unmapped logic" >&2
    exit 1
  fi
done

echo "Synthesis completed: group=$GROUP corner=$CORNER tops=${TOPS[*]}"
