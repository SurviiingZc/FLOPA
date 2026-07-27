#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CORNER="${CORNER:-tt}"
FORMAL_TOP="${FORMAL_TOP:-attention_accel_top}"
FORMAL_NETLIST="${FORMAL_NETLIST:-}"
FORMAL_SVF="${FORMAL_SVF:-}"
FORMAL_SYNTH_CONFIG="${FORMAL_SYNTH_CONFIG:-}"
FORMAL_EXPECTED_RTL_ICGS="${FORMAL_EXPECTED_RTL_ICGS:-22}"
FORMAL_OUT_DIR="${FORMAL_OUT_DIR:-$ROOT_DIR/asic/dc/work/formality/$CORNER/$FORMAL_TOP}"
FM_BIN="${FM_SHELL:-fm_shell}"
DC_BIN="${DC_SHELL:-dc_shell}"

if [[ ! "$FORMAL_TOP" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "FORMAL_TOP must be a Verilog identifier" >&2
  exit 2
fi
if [[ ! "$FORMAL_EXPECTED_RTL_ICGS" =~ ^[1-9][0-9]*$ ]]; then
  echo "FORMAL_EXPECTED_RTL_ICGS must be a positive integer" >&2
  exit 2
fi
if [ -z "$FORMAL_NETLIST" ] || [ ! -s "$FORMAL_NETLIST" ]; then
  echo "FORMAL_NETLIST must name a nonempty mapped Verilog netlist" >&2
  exit 2
fi
if [ -z "$FORMAL_SVF" ] || [ ! -s "$FORMAL_SVF" ]; then
  echo "FORMAL_SVF must name the matching nonempty synthesis SVF" >&2
  exit 2
fi
if [ -z "$FORMAL_SYNTH_CONFIG" ] || [ ! -s "$FORMAL_SYNTH_CONFIG" ]; then
  echo "FORMAL_SYNTH_CONFIG must name the matching synthesis run_config.rpt" >&2
  exit 2
fi
snps_gate_defs=$(rg -c '^module SNPS_CLOCK_GATE_HIGH_' "$FORMAL_NETLIST" || true)
snps_gate_defs=${snps_gate_defs:-0}
if [ "$snps_gate_defs" -ne 0 ]; then
  echo "FORMAL_NETLIST contains rejected SNPS automatic clock-gate wrappers" >&2
  exit 2
fi
for required_setting in \
  'clock_gating=rtl_explicit' \
  "expected_top_rtl_icgs=$FORMAL_EXPECTED_RTL_ICGS" \
  "rtl_icg_count=$FORMAL_EXPECTED_RTL_ICGS" \
  'automatic_clock_gating=0' \
  'automatic_clock_gating_whitelist_count=0'; do
  if ! grep -qx "$required_setting" "$FORMAL_SYNTH_CONFIG"; then
    echo "Mapped netlist uses a rejected synthesis policy: missing $required_setting" >&2
    echo "Rerun make synth before make formality" >&2
    exit 2
  fi
done
logical_hold_repair=$(awk -F= '$1 == "logical_hold_repair" {print $2}' \
  "$FORMAL_SYNTH_CONFIG")
physical_aware=$(awk -F= '$1 == "physical_aware" {print $2}' \
  "$FORMAL_SYNTH_CONFIG")
if [[ "$logical_hold_repair" != "0" && "$logical_hold_repair" != "1" ]]; then
  echo "Synthesis config has an invalid logical_hold_repair value" >&2
  exit 2
fi
if [[ "$logical_hold_repair" == "1" && "$physical_aware" != "1" ]]; then
  echo "Formality refuses non-physical logical hold repair on the SRAM top" >&2
  exit 2
fi
synth_rtl_hash=$(awk -F= '$1 == "FA_RTL_HASH" {print $2}' \
  "$FORMAL_SYNTH_CONFIG")
current_rtl_hash=$(find "$ROOT_DIR/rtl" -type f -print0 | sort -z | \
  xargs -0 sha256sum | sha256sum | awk '{print $1}')
if [ -z "$synth_rtl_hash" ] || [ "$synth_rtl_hash" != "$current_rtl_hash" ]; then
  echo "RTL differs from the synthesis provenance recorded in run_config.rpt" >&2
  echo "Rerun make synth before make formality" >&2
  exit 2
fi

# shellcheck source=library_paths.sh
source "$ROOT_DIR/asic/scripts/library_paths.sh"
fa_select_libraries "$ROOT_DIR" "$CORNER"
if [ ! -s "$FA_SRAM_DB" ]; then
  "$ROOT_DIR/asic/scripts/prepare_sram_lib.sh" "$CORNER"
fi
test -s "$FA_STD_DB"
test -s "$FA_SRAM_DB"
if ! command -v "$DC_BIN" >/dev/null 2>&1; then
  echo "DC_SHELL is not executable: $DC_BIN" >&2
  exit 2
fi
DC_BIN=$(readlink -f "$(command -v "$DC_BIN")")
FA_DW_ROOT="${FA_DW_ROOT:-$(readlink -f "$(dirname "$DC_BIN")/..")}"
if [ ! -d "$FA_DW_ROOT/dw" ] || [ ! -d "$FA_DW_ROOT/packages" ]; then
  echo "DesignWare root does not contain dw/ and packages/: $FA_DW_ROOT" >&2
  exit 2
fi

mkdir -p "$FORMAL_OUT_DIR"
FORMAL_OUT_DIR=$(cd "$FORMAL_OUT_DIR" && pwd)
FORMAL_NETLIST=$(readlink -f "$FORMAL_NETLIST")
FORMAL_SVF=$(readlink -f "$FORMAL_SVF")

lock_dir="${FORMAL_OUT_DIR}.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "Another Formality run owns $FORMAL_OUT_DIR" >&2
  [[ -f "$lock_dir/owner" ]] && sed 's/^/  /' "$lock_dir/owner" >&2
  exit 2
fi
{
  printf 'pid=%s\n' "$$"
  printf 'host=%s\n' "$(hostname)"
  printf 'started=%s\n' "$(date -Is)"
} > "$lock_dir/owner"
trap 'rm -rf "$lock_dir"' EXIT

rm -f "$FORMAL_OUT_DIR/status.rpt" "$FORMAL_OUT_DIR/verification.rpt" \
  "$FORMAL_OUT_DIR/failing_points.rpt" \
  "$FORMAL_OUT_DIR/unmatched_points.rpt" "$FORMAL_OUT_DIR/formality.log"

export FA_ROOT="$ROOT_DIR"
export FA_FORMAL_TOP="$FORMAL_TOP"
export FA_FORMAL_NETLIST="$FORMAL_NETLIST"
export FA_FORMAL_SVF="$FORMAL_SVF"
export FA_FORMAL_REPORT_DIR="$FORMAL_OUT_DIR"
export FA_DW_ROOT

cd "$FORMAL_OUT_DIR"
# fm_shell writes formality.log in its working directory. Do not tee stdout to
# that same path: two concurrent writers corrupt the transcript and can hide
# the setup lines needed to diagnose a failed proof.
# Keep Formality strictly batch-only. In particular, an SSH-launched proof must
# never inherit a terminal stream that could be interpreted as Tcl commands
# after the script completes.
"$FM_BIN" -no_init -file "$ROOT_DIR/asic/scripts/formality.tcl" </dev/null

if ! grep -qx 'verification_status=PASS' "$FORMAL_OUT_DIR/status.rpt"; then
  echo "Formality did not prove equivalence; see $FORMAL_OUT_DIR/formality.log" >&2
  exit 1
fi

echo "Formality PASS: $FORMAL_TOP"
echo "Reports: $FORMAL_OUT_DIR"
