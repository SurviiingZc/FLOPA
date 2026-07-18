#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CORNER="${1:-tt}"
LIB_DIR="$ROOT_DIR/asic/dc/work/lib"
RUN_DIR="$ROOT_DIR/asic/dc/work/sram_lib/$CORNER"
LOG_DIR="$ROOT_DIR/asic/dc/logs"
SRAM_ROOT="/data/public/SRAM/uhdsp_256x8m4s/NLDM"

case "$CORNER" in
  tt) LIB_NAME="uhdsp_256x8m4s_tt0p9v25c" ;;
  ss) LIB_NAME="uhdsp_256x8m4s_ssg0p9v125c" ;;
  *) echo "usage: $0 [tt|ss]" >&2; exit 2 ;;
esac

LIB_FILE="$SRAM_ROOT/$LIB_NAME.lib"
DB_FILE="$LIB_DIR/$LIB_NAME.db"

test -s "$LIB_FILE"
if [ -s "$DB_FILE" ]; then
  echo "$DB_FILE"
  exit 0
fi

rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR" "$LIB_DIR" "$LOG_DIR"

export FA_DC_LIB="$LIB_DIR"
export FA_SRAM_LIB_FILE="$LIB_FILE"
export FA_SRAM_DB_FILE="$DB_FILE"
export FA_SRAM_LIB_NAME="$LIB_NAME"

cd "$RUN_DIR"
set +e
LD_PRELOAD="/lib64/libcrypto.so.1.1 /lib64/libk5crypto.so.3" \
  lc_shell -f "$ROOT_DIR/asic/scripts/compile_sram_lib.tcl" \
  2>&1 | tee "$LOG_DIR/sram_lib_${CORNER}.log"
LC_STATUS=${PIPESTATUS[0]}
set -e

if [ "$LC_STATUS" -ne 0 ]; then
  echo "lc_shell exited with status $LC_STATUS; validating generated DB" >&2
fi
test -s "$DB_FILE"

rm -f "$RUN_DIR"/Synopsys_stack_trace_*.txt
rm -f "$RUN_DIR"/crte_*.txt "$RUN_DIR"/flex*.log
rm -f "$RUN_DIR"/lc_command.log "$RUN_DIR"/lc_output.txt
echo "$DB_FILE"
