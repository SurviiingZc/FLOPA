#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CORNER="${CORNER:-tt}"
CLOCK_PERIOD="${CLOCK_PERIOD:-1.7}"
LIMITS="${FANOUT_SWEEP_LIMITS:-16 24 32}"
SUMMARY_DIR="$ROOT_DIR/asic/dc/work/fanout_sweep/$CORNER"
SUMMARY_FILE="$SUMMARY_DIR/summary.csv"

mkdir -p "$SUMMARY_DIR"
printf 'max_fanout,setup_wns_ns,setup_tns_ns,hold_wns_ns,max_transition_violations,max_fanout_violations,buf_inv_cells,cell_area,dynamic_power_mw,congestion_report\n' > "$SUMMARY_FILE"

for limit in $LIMITS; do
  if [[ ! "$limit" =~ ^[1-9][0-9]*$ ]]; then
    echo "invalid fanout limit: $limit" >&2
    exit 2
  fi
  group="fanout_${limit}"
  CORNER="$CORNER" CLOCK_PERIOD="$CLOCK_PERIOD" FA_MAX_FANOUT="$limit" \
    FA_WRITE_ARTIFACTS=0 FA_LOGICAL_HOLD_REPAIR=0 \
    "$ROOT_DIR/asic/scripts/run_synth.sh" "$group" attention_accel_top

  report_dir="$ROOT_DIR/asic/dc/work/synth/$CORNER/$group/attention_accel_top/reports"
  setup_wns=$(awk '/Critical Path Slack:/ {print $NF; exit}' "$report_dir/qor.rpt")
  setup_tns=$(awk '/Total Negative Slack:/ {print $NF; exit}' "$report_dir/qor.rpt")
  hold_wns=$(awk '/Worst Hold Violation:/ {print $NF; exit}' "$report_dir/qor.rpt")
  max_trans=$(awk '/Max Trans Violations:/ {print $NF; exit}' "$report_dir/qor.rpt")
  max_fanout=$(awk '/Max Fanout Violations:/ {print $NF; exit}' "$report_dir/qor.rpt")
  buf_inv=$(awk '/Buf\/Inv Cell Count:/ {print $NF; exit}' "$report_dir/qor.rpt")
  cell_area=$(awk '/Total cell area:/ {print $NF; exit}' "$report_dir/area.rpt")
  dynamic=$(awk '/Total Dynamic Power/ {print $(NF-2); exit}' "$report_dir/power.rpt")
  congestion="not_available"
  if [ -s "$report_dir/congestion.rpt" ]; then
    congestion="$report_dir/congestion.rpt"
  fi
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$limit" "$setup_wns" \
    "$setup_tns" "$hold_wns" "$max_trans" "$max_fanout" "$buf_inv" \
    "$cell_area" "$dynamic" "$congestion" >> "$SUMMARY_FILE"
done

echo "Fanout sweep summary: $SUMMARY_FILE"
echo "Keep MAX_FANOUT=16 until fanout=24 has no worse setup/transition/congestion QoR."
