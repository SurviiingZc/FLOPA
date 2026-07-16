#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
RUN_DIR="$ROOT_DIR/asic/dc/work/rtl_check"
LIB_DIR="$ROOT_DIR/asic/dc/work/lib"
LOG_DIR="$ROOT_DIR/asic/dc/logs"

rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR" "$LIB_DIR" "$LOG_DIR"
cd "$RUN_DIR"

export FA_ROOT="$ROOT_DIR"
export FA_DC_WORK="$RUN_DIR"
export FA_DC_LIB="$LIB_DIR"

if [ ! -s "$LIB_DIR/uhdsp_256x8m4s_tt0p9v25c.db" ]; then
  set +e
  LD_PRELOAD="/lib64/libcrypto.so.1.1 /lib64/libk5crypto.so.3" \
    lc_shell -f "$ROOT_DIR/asic/scripts/compile_sram_lib.tcl" \
    2>&1 | tee "$LOG_DIR/sram_lib_compile.log"
  LC_STATUS=${PIPESTATUS[0]}
  set -e
  if [ "$LC_STATUS" -ne 0 ]; then
    echo "lc_shell exited with status $LC_STATUS after library write; validating DB output" \
      | tee -a "$LOG_DIR/sram_lib_compile.log"
  fi
fi

test -s "$LIB_DIR/uhdsp_256x8m4s_tt0p9v25c.db"
rm -f "$RUN_DIR"/Synopsys_stack_trace_*.txt
rm -f "$RUN_DIR"/crte_*.txt
rm -f "$RUN_DIR"/flex*.log
rm -f "$RUN_DIR"/lc_command.log "$RUN_DIR"/lc_output.txt

dc_shell -64bit -f "$ROOT_DIR/asic/scripts/check_rtl.tcl" \
  2>&1 | tee "$LOG_DIR/rtl_check.log"
