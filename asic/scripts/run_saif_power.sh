#!/usr/bin/env bash
set -euo pipefail

# Back-annotate a passing DUT-only SAIF onto the mapped DDC produced from the
# same RTL hash. This never overwrites timing/area results or re-synthesizes.
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CORNER="${CORNER:-tt}"
CLOCK_PERIOD="${CLOCK_PERIOD:-1.6}"
SYNTH_GROUP="${SYNTH_GROUP:-system}"
TOP="${TOP:-attention_accel_top}"
SAIF_FILE="${SAIF_FILE:-}"
DDC_FILE="${DDC_FILE:-$ROOT_DIR/asic/dc/work/synth/$CORNER/$SYNTH_GROUP/$TOP/results/$TOP.ddc}"
SAIF_STRIP_PATH="${SAIF_STRIP_PATH:-tb_top/dut}"
PROFILE="${PROFILE:-}"
DC_POWER_BIN="${DC_POWER_BIN:-dc_shell}"

if [[ -z "$SAIF_FILE" ]]; then
  echo "SAIF_FILE=<absolute-path> is required" >&2
  exit 2
fi
if [[ ! "$CLOCK_PERIOD" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "CLOCK_PERIOD must be a positive number" >&2
  exit 2
fi
if ! awk -v period="$CLOCK_PERIOD" 'BEGIN { exit (period > 0.0) ? 0 : 1 }'; then
  echo "CLOCK_PERIOD must be greater than zero" >&2
  exit 2
fi
if [[ ! -s "$SAIF_FILE" ]]; then
  echo "SAIF file does not exist or is empty: $SAIF_FILE" >&2
  exit 2
fi
if [[ ! -s "$DDC_FILE" ]]; then
  echo "Mapped DDC does not exist or is empty: $DDC_FILE" >&2
  exit 2
fi

SAIF_FILE=$(readlink -f "$SAIF_FILE")
DDC_FILE=$(readlink -f "$DDC_FILE")
if [[ -z "$PROFILE" ]]; then
  PROFILE=$(basename "$SAIF_FILE" .saif)
fi
if [[ ! "$PROFILE" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "PROFILE may contain only letters, digits, dot, underscore, and dash" >&2
  exit 2
fi

# Activity rates in SAIF are time-based. Reject a mismatched analysis clock
# when the simulator sidecar is available instead of silently scaling power.
saif_metadata="${SAIF_FILE%.saif}.json"
if [[ -s "$saif_metadata" ]]; then
  saif_clock_period=$(awk -F': ' '$1 ~ /"clock_period_ns"/ {gsub(/,/, "", $2); print $2}' "$saif_metadata")
  if [[ -n "$saif_clock_period" ]] && ! awk -v a="$saif_clock_period" -v b="$CLOCK_PERIOD" \
      'BEGIN { exit ((a - b < 1.0e-9) && (b - a < 1.0e-9)) ? 0 : 1 }'; then
    echo "CLOCK_PERIOD=$CLOCK_PERIOD ns differs from SAIF clock_period_ns=$saif_clock_period ns" >&2
    exit 2
  fi
fi

rtl_hash=$(find "$ROOT_DIR/rtl" -type f -print0 | sort -z | \
  xargs -0 sha256sum | sha256sum | awk '{print $1}')
synth_config="$(dirname "$(dirname "$DDC_FILE")")/reports/run_config.rpt"
if [[ -s "$synth_config" ]]; then
  ddc_rtl_hash=$(awk -F= '$1 == "FA_RTL_HASH" {print $2}' "$synth_config")
  if [[ -n "$ddc_rtl_hash" && "$ddc_rtl_hash" != "$rtl_hash" && \
        "${ALLOW_STALE_DDC:-0}" != "1" ]]; then
    echo "DDC RTL hash does not match current RTL; rerun synthesis or set ALLOW_STALE_DDC=1" >&2
    exit 2
  fi
fi

# shellcheck source=library_paths.sh
source "$ROOT_DIR/asic/scripts/library_paths.sh"
fa_select_libraries "$ROOT_DIR" "$CORNER"
if [[ ! -s "$FA_SRAM_DB" ]]; then
  "$ROOT_DIR/asic/scripts/prepare_sram_lib.sh" "$CORNER"
fi
test -s "$FA_STD_DB"
test -s "$FA_SRAM_DB"

REPORT_DIR="$ROOT_DIR/asic/dc/work/power/reports/$rtl_hash/$PROFILE/$CORNER"
WORK_DIR="$ROOT_DIR/asic/dc/work/saif_power/$CORNER/$PROFILE"
LOG_DIR="$ROOT_DIR/asic/dc/logs"
mkdir -p "$REPORT_DIR" "$WORK_DIR" "$LOG_DIR"
REPORT_DIR=$(cd "$REPORT_DIR" && pwd)
WORK_DIR=$(cd "$WORK_DIR" && pwd)

export FA_ROOT="$ROOT_DIR"
export FA_DC_WORK="$WORK_DIR"
export FA_STD_DB FA_SRAM_DB
export FA_CLOCK_PERIOD="$CLOCK_PERIOD"
export FA_CORNER="$CORNER"
export FA_DDC_FILE="$DDC_FILE"
export FA_SAIF_FILE="$SAIF_FILE"
export FA_SAIF_STRIP_PATH="$SAIF_STRIP_PATH"
export FA_SAIF_INSTANCE="$TOP"
export FA_POWER_REPORT_DIR="$REPORT_DIR"
export FA_RTL_HASH="$rtl_hash"
export FA_DDC_SHA256="$(sha256sum "$DDC_FILE" | awk '{print $1}')"
export FA_SAIF_SHA256="$(sha256sum "$SAIF_FILE" | awk '{print $1}')"

"$DC_POWER_BIN" -64bit -f "$ROOT_DIR/asic/scripts/saif_power.tcl" \
  2>&1 | tee "$LOG_DIR/saif_power_${PROFILE}_${CORNER}.log"

if grep -Eq '(^|[[:space:]])(Error:|ERROR:)' "$LOG_DIR/saif_power_${PROFILE}_${CORNER}.log"; then
  echo "SAIF power readback reported an error" >&2
  exit 1
fi
for report in check_design.rpt clocks.rpt saif_coverage.rpt clock_gating.rpt \
              power_hierarchy.rpt power_summary.rpt run_config.rpt; do
  test -s "$REPORT_DIR/$report"
done

echo "SAIF power reports: $REPORT_DIR"
