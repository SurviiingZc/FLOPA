#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
: "${FA_MW_LIB:?FA_MW_LIB must point to the combined standard-cell/SRAM Milkyway library}"
: "${FA_TLUPLUS_MIN:?FA_TLUPLUS_MIN must point to the extracted minimum-RC TLU+ table}"

test -d "$FA_MW_LIB"
test -s "$FA_TLUPLUS_MIN"
if [ -n "${FA_TLUPLUS_MAP:-}" ]; then
  test -s "$FA_TLUPLUS_MAP"
fi

export CORNER=ff
export FA_PHYSICAL_AWARE=1
export FA_LOGICAL_HOLD_REPAIR=1
# DC Graphical requires a max table to establish the RC environment. For this
# dedicated min-delay run both slots intentionally use the minimum-RC table.
export FA_TLUPLUS_MAX="$FA_TLUPLUS_MIN"

"$ROOT_DIR/asic/scripts/run_synth.sh" hold_ff attention_accel_top

echo "Pre-CTS FF/min-RC reports: $ROOT_DIR/asic/dc/work/synth/ff/hold_ff"
echo "This is an implementation guide; post-CTS PrimeTime is the hold signoff."
