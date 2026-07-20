#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CORNER="${CORNER:-tt}"
PERIODS="${FREQ_SWEEP_PERIODS:-3.2 2.8 2.5 2.3 2.1 1.9}"
SUMMARY_DIR="$ROOT_DIR/asic/dc/work/frequency_sweep/$CORNER"
SUMMARY_FILE="$SUMMARY_DIR/summary.csv"

mkdir -p "$SUMMARY_DIR"
printf 'period_ns,frequency_mhz,setup_wns_ns,setup_tns_ns,hold_wns_ns,cell_area\n' > "$SUMMARY_FILE"

for period in $PERIODS; do
  if [[ ! "$period" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "invalid sweep period: $period" >&2
    exit 2
  fi
  tag=${period//./p}
  group="frequency_${tag}ns"
  CLOCK_PERIOD="$period" CORNER="$CORNER" FA_WRITE_ARTIFACTS=0 \
    "$ROOT_DIR/asic/scripts/run_synth.sh" "$group" attention_accel_top

  report_dir="$ROOT_DIR/asic/dc/work/synth/$CORNER/$group/attention_accel_top/reports"
  frequency=$(awk -v p="$period" 'BEGIN {printf "%.3f", 1000.0/p}')
  setup_wns=$(awk '/Critical Path Slack:/ {print $NF; exit}' "$report_dir/qor.rpt")
  setup_tns=$(awk '/Total Negative Slack:/ {print $NF; exit}' "$report_dir/qor.rpt")
  hold_wns=$(awk '/Worst Hold Violation:/ {print $NF; exit}' "$report_dir/qor.rpt")
  cell_area=$(awk '/Total cell area:/ {print $NF; exit}' "$report_dir/area.rpt")
  printf '%s,%s,%s,%s,%s,%s\n' "$period" "$frequency" "$setup_wns" \
    "$setup_tns" "$hold_wns" "$cell_area" >> "$SUMMARY_FILE"
done

awk -F, 'NR > 1 && $3 + 0 >= 0 {if ($2 + 0 > best) {best=$2; line=$0}} \
  END {if (line != "") print line; else print "no_passing_point"}' \
  "$SUMMARY_FILE" > "$SUMMARY_DIR/best_passing.csv"

echo "Frequency sweep summary: $SUMMARY_FILE"
echo "Best passing point: $(cat "$SUMMARY_DIR/best_passing.csv")"
