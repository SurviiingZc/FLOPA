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
mkdir -p "$OUTDIR"
cd "$(dirname "$0")/.."

cmd=("$VCS_BIN" -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb -top "$TOP" -l "$OUTDIR/compile.log" -o "$OUTDIR/simv")
for f in "$@"; do
  cmd+=(-f "$f")
done

"${cmd[@]}"
"$OUTDIR/simv" -l "$OUTDIR/run.log"
