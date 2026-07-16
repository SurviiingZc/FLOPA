#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: $0 TOP OUTDIR FILELIST..." >&2
  exit 1
fi

TOP="$1"
OUTDIR="$2"
shift 2

VCS_BIN="${VCS:-vcs}"
SIM_ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$OUTDIR" "$OUTDIR/csrc"
cd "$SIM_ROOT"

cleanup_transients() {
  rm -f "$SIM_ROOT"/flex*.log "$SIM_ROOT/ucli.key"
  rm -rf "$SIM_ROOT/csrc"
}
trap cleanup_transients EXIT

cmd=("$VCS_BIN" -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb \
  -Mdir="$OUTDIR/csrc" -top "$TOP" -l "$OUTDIR/compile.log" -o "$OUTDIR/simv")
for f in "$@"; do
  cmd+=(-f "$f")
done

"${cmd[@]}"
"$OUTDIR/simv" -l "$OUTDIR/run.log"
