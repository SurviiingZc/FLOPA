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
DC_CORES="${DC_CORES:-4}"
EXPECTED_TOP_SRAM_MACROS="${EXPECTED_TOP_SRAM_MACROS:-480}"
EXPECTED_TOP_RTL_ICGS="${EXPECTED_TOP_RTL_ICGS:-22}"
if [[ ! "$CLOCK_PERIOD" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "CLOCK_PERIOD must be a positive number" >&2
  exit 2
fi
if [[ ! "$DC_CORES" =~ ^[1-9][0-9]*$ ]]; then
  echo "DC_CORES must be a positive integer" >&2
  exit 2
fi
if [[ ! "$EXPECTED_TOP_SRAM_MACROS" =~ ^[0-9]+$ ]]; then
  echo "EXPECTED_TOP_SRAM_MACROS must be a non-negative integer" >&2
  exit 2
fi
if [[ ! "$EXPECTED_TOP_RTL_ICGS" =~ ^[1-9][0-9]*$ ]]; then
  echo "EXPECTED_TOP_RTL_ICGS must be a positive integer" >&2
  exit 2
fi

# shellcheck source=library_paths.sh
source "$ROOT_DIR/asic/scripts/library_paths.sh"
fa_select_libraries "$ROOT_DIR" "$CORNER"

RUN_DIR="$ROOT_DIR/asic/dc/work/synth/$CORNER/$GROUP"
LOG_DIR="$ROOT_DIR/asic/dc/logs"
LOG_FILE="$LOG_DIR/synth_${GROUP}_${CORNER}.log"
# Never run DC directly in the published result directory.  A killed or OOM
# synthesis otherwise deletes the netlist still needed by Formality and gate
# simulation before it has produced a replacement.
STAGE_DIR="${RUN_DIR}.inprogress.$$"
BACKUP_DIR="${RUN_DIR}.previous.$$"

test -s "$FA_STD_DB"
if [ ! -s "$FA_SRAM_DB" ]; then
  "$ROOT_DIR/asic/scripts/prepare_sram_lib.sh" "$CORNER"
fi
test -s "$FA_SRAM_DB"

case "$RUN_DIR" in
  "$ROOT_DIR"/asic/dc/work/synth/*) ;;
  *) echo "refusing unsafe synthesis path: $RUN_DIR" >&2; exit 2 ;;
esac
for guarded_dir in "$STAGE_DIR" "$BACKUP_DIR"; do
  case "$guarded_dir" in
    "$ROOT_DIR"/asic/dc/work/synth/*) ;;
    *) echo "refusing unsafe synthesis staging path: $guarded_dir" >&2; exit 2 ;;
  esac
done

if [ -e "$STAGE_DIR" ] || [ -e "$BACKUP_DIR" ]; then
  echo "synthesis staging path already exists; remove only the confirmed stale path: $STAGE_DIR or $BACKUP_DIR" >&2
  exit 2
fi
mkdir -p "$(dirname "$RUN_DIR")" "$LOG_DIR"
mkdir "$STAGE_DIR"

export FA_ROOT="$ROOT_DIR"
export FA_DC_WORK="$STAGE_DIR"
export FA_SYNTH_TOPS="${TOPS[*]}"
export FA_CLOCK_PERIOD="$CLOCK_PERIOD"
export FA_CORNER="$CORNER"
export FA_DC_CORES="$DC_CORES"
export FA_EXPECTED_TOP_SRAM_MACROS="$EXPECTED_TOP_SRAM_MACROS"
export FA_EXPECTED_TOP_RTL_ICGS="$EXPECTED_TOP_RTL_ICGS"
export FA_PHYSICAL_AWARE="${FA_PHYSICAL_AWARE:-0}"
export FA_WRITE_ARTIFACTS="${FA_WRITE_ARTIFACTS:-1}"
export FA_LOGICAL_HOLD_REPAIR="${FA_LOGICAL_HOLD_REPAIR:-0}"
export FA_GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
export FA_GIT_STATUS_HASH="$(git -C "$ROOT_DIR" status --porcelain=v1 | sha256sum | awk '{print $1}')"
export FA_RTL_HASH="$(find "$ROOT_DIR/rtl" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
export FA_STD_DB_HASH="$(sha256sum "$FA_STD_DB" | awk '{print $1}')"
export FA_SRAM_DB_HASH="$(sha256sum "$FA_SRAM_DB" | awk '{print $1}')"

cd "$STAGE_DIR"
DC_ARGS=(-64bit)
if [ "$FA_PHYSICAL_AWARE" = "1" ]; then
  DC_ARGS+=(-topographical_mode)
fi
dc_shell "${DC_ARGS[@]}" -f "$ROOT_DIR/asic/scripts/synth_group.tcl" \
  2>&1 | tee "$LOG_FILE"

# Synopsys license tracing can leave flexNNN.log in the DC working directory.
# It is not a design artifact and must not be published with a successful run.
rm -f "$STAGE_DIR"/flex*.log

if grep -Eq '(^|[[:space:]])(Error:|ERROR:)' "$LOG_FILE"; then
  echo "DC reported an error; see $LOG_FILE" >&2
  exit 1
fi

for top in "${TOPS[@]}"; do
  REPORT_DIR="$STAGE_DIR/$top/reports"
  RESULT_DIR="$STAGE_DIR/$top/results"
  test -s "$REPORT_DIR/qor.rpt"
  test -s "$REPORT_DIR/timing.rpt"
  test -s "$REPORT_DIR/area.rpt"
  test -s "$REPORT_DIR/power.rpt"
  test -s "$REPORT_DIR/check_design.rpt"
  test -s "$REPORT_DIR/check_timing.rpt"
  test -s "$REPORT_DIR/timing_status.rpt"
  test -s "$REPORT_DIR/run_config.rpt"
  test -s "$REPORT_DIR/clock_gating.rpt"
  if [ "$FA_LOGICAL_HOLD_REPAIR" = "1" ]; then
    test -s "$REPORT_DIR/qor_pre_hold.rpt"
    test -s "$REPORT_DIR/timing_min_pre_hold.rpt"
  fi
  if [ "$FA_WRITE_ARTIFACTS" = "1" ]; then
    test -s "$RESULT_DIR/${top}_mapped.v"
    test -s "$RESULT_DIR/${top}.ddc"
    test -s "$RESULT_DIR/${top}.sdc"
    test -s "$RESULT_DIR/${top}.sdf"
    if grep -Eq '\*\*SEQGEN\*\*|GTECH_' "$RESULT_DIR/${top}_mapped.v"; then
      echo "$top mapped netlist still contains generic SEQGEN/GTECH cells" >&2
      exit 1
    fi
  fi
  if grep -qi 'unmapped logic' "$REPORT_DIR/area.rpt"; then
    echo "$top contains unmapped logic" >&2
    exit 1
  fi
  if ! grep -qx 'setup_violating_paths=0' "$REPORT_DIR/timing_status.rpt"; then
    echo "$top synthesis left setup timing violations" >&2
    exit 1
  fi
  if [ "$FA_LOGICAL_HOLD_REPAIR" = "1" ]; then
    if ! grep -qx 'hold_violating_paths=0' "$REPORT_DIR/timing_status.rpt"; then
      echo "$top logical hold repair left minimum-delay violations" >&2
      exit 1
    fi
  fi
  if [ "$top" = "attention_accel_top" ]; then
    wrapper_count=$(awk -F= '$1 == "multiplier_wrapper_count" {print $2}' \
      "$REPORT_DIR/run_config.rpt")
    dw_count=$(awk -F= '$1 == "linked_dw02_mult_count" {print $2}' \
      "$REPORT_DIR/run_config.rpt")
    if [[ ! "$wrapper_count" =~ ^[1-9][0-9]*$ ]] ||
       [[ ! "$dw_count" =~ ^[1-9][0-9]*$ ]] ||
       [ "$wrapper_count" -ne "$dw_count" ]; then
      echo "$top DesignWare binding mismatch: wrappers=$wrapper_count DW02_mult=$dw_count" >&2
      exit 1
    fi
  fi
  if [ "$top" = "attention_accel_top" ]; then
    gating_count=$(awk -F'|' '/Number of Clock gating elements/ {
      value=$3; gsub(/[[:space:]]/, "", value); print value; exit
    }' "$REPORT_DIR/clock_gating.rpt")
    if [[ ! "$gating_count" =~ ^[1-9][0-9]*$ ]]; then
      echo "$top contains no recognized ICG elements" >&2
      exit 1
    fi
    rtl_gating_count=$(awk -F'|' '/Number of pre-existing clock gating elements/ {
      value=$3; sub(/\(.*/, "", value); gsub(/[[:space:]]/, "", value);
      print value; exit
    }' "$REPORT_DIR/clock_gating.rpt")
    automatic_gating_count=$(awk -F'|' '/Number of tool-inserted clock gating elements/ {
      value=$3; sub(/\(.*/, "", value); gsub(/[[:space:]]/, "", value);
      print value; exit
    }' "$REPORT_DIR/clock_gating.rpt")
    if [[ ! "$rtl_gating_count" =~ ^[0-9]+$ ]] ||
       [ "$rtl_gating_count" -ne "$EXPECTED_TOP_RTL_ICGS" ]; then
      echo "$top expected $EXPECTED_TOP_RTL_ICGS RTL ICGs, report has ${rtl_gating_count:-missing}" >&2
      exit 1
    fi
    if [[ ! "$automatic_gating_count" =~ ^[0-9]+$ ]]; then
      echo "$top automatic ICG count is missing from clock_gating.rpt" >&2
      exit 1
    fi
    if [ "$automatic_gating_count" -ne 0 ]; then
      echo "$top contains $automatic_gating_count tool-inserted ICGs; only explicit RTL domains are allowed" >&2
      exit 1
    fi
    snps_gate_defs=$(rg -c '^module SNPS_CLOCK_GATE_HIGH_' \
      "$RESULT_DIR/${top}_mapped.v" || true)
    snps_gate_defs=${snps_gate_defs:-0}
    if [ "$FA_WRITE_ARTIFACTS" = "1" ] && [ "$snps_gate_defs" -ne 0 ]; then
      echo "$top contains a rejected SNPS automatic clock-gate wrapper" >&2
      exit 1
    fi
  fi
done

# Publish only a fully checked implementation. Keep an old published result
# until the staged directory has replaced it, so a filesystem error cannot
# leave downstream Formality/SAIF targets without their prior artifacts.
if [ -e "$RUN_DIR" ]; then
  mv "$RUN_DIR" "$BACKUP_DIR"
fi
if ! mv "$STAGE_DIR" "$RUN_DIR"; then
  echo "failed to publish checked synthesis result: $STAGE_DIR" >&2
  if [ -e "$BACKUP_DIR" ]; then
    mv "$BACKUP_DIR" "$RUN_DIR" || \
      echo "failed to restore prior synthesis result from $BACKUP_DIR" >&2
  fi
  exit 1
fi
if [ -e "$BACKUP_DIR" ]; then
  rm -rf "$BACKUP_DIR"
fi

echo "Synthesis completed: group=$GROUP corner=$CORNER tops=${TOPS[*]}"
