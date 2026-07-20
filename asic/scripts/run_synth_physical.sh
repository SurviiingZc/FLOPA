#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CORNER="${CORNER:-ss}"
CLOCK_PERIOD="${CLOCK_PERIOD:-2.5}"

if [ -z "${FA_MW_LIB:-}" ] || [ ! -d "$FA_MW_LIB" ]; then
  echo "FA_MW_LIB must point to a prepared Milkyway design library" >&2
  echo "It must contain both the standard-cell FRAM views and the SRAM abstract." >&2
  exit 2
fi

FA_PHYSICAL_AWARE=1 CLOCK_PERIOD="$CLOCK_PERIOD" CORNER="$CORNER" \
  "$ROOT_DIR/asic/scripts/run_synth.sh" physical attention_accel_top
