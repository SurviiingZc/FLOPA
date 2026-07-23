#!/usr/bin/env bash
set -euo pipefail

# Generate a DUT-only SAIF from the two-tile ping-pong random-QKV UVM workload
# without output backpressure. The temporary SAIF is promoted only when UVM
# reports zero errors and zero fatals.
SIM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOT_DIR=$(cd "$SIM_ROOT/../.." && pwd)
VCS_BIN="${VCS:-vcs}"
SEED="${SEED:-301}"
PROFILE="${PROFILE:-fa_two_tile_pingpong_random_seed${SEED}}"
OUT_DIR="${OUT_DIR:-$SIM_ROOT/build/saif_${PROFILE}}"
SIM_CLOCK_PERIOD_NS="${SIM_CLOCK_PERIOD_NS:-1.6}"

if [[ ! "$SEED" =~ ^[0-9]+$ ]]; then
  echo "SEED must be a non-negative integer" >&2
  exit 2
fi
if [[ ! "$PROFILE" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "PROFILE may contain only letters, digits, dot, underscore, and dash" >&2
  exit 2
fi
if [[ ! "$SIM_CLOCK_PERIOD_NS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "SIM_CLOCK_PERIOD_NS must be a positive number" >&2
  exit 2
fi
if ! awk -v period="$SIM_CLOCK_PERIOD_NS" 'BEGIN { exit (period > 0.0) ? 0 : 1 }'; then
  echo "SIM_CLOCK_PERIOD_NS must be greater than zero" >&2
  exit 2
fi

rtl_hash=$(find "$ROOT_DIR/rtl" -type f -print0 | sort -z | \
  xargs -0 sha256sum | sha256sum | awk '{print $1}')
saif_dir="$ROOT_DIR/asic/power/saif/$rtl_hash"
saif_file="$saif_dir/$PROFILE.saif"
partial_saif="$OUT_DIR/$PROFILE.partial.saif"
metadata_file="$saif_dir/$PROFILE.json"

mkdir -p "$OUT_DIR/csrc" "$saif_dir"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
saif_dir=$(cd "$saif_dir" && pwd)
saif_file="$saif_dir/$PROFILE.saif"
metadata_file="$saif_dir/$PROFILE.json"
partial_saif="$OUT_DIR/$PROFILE.partial.saif"
cd "$SIM_ROOT"

cleanup_transients() {
  rm -f "$SIM_ROOT"/flex*.log "$SIM_ROOT"/ucli.key
  rm -rf "$SIM_ROOT/csrc"
}
trap cleanup_transients EXIT

"$VCS_BIN" -full64 -sverilog -ntb_opts uvm -timescale=1ns/1ps \
  -debug_access+all -kdb -lca -Mdir="$OUT_DIR/csrc" \
  -f filelists/rtl.f -f filelists/uvm.f -top tb_top \
  -l "$OUT_DIR/compile.log" -o "$OUT_DIR/simv"

# Never discard an earlier passing artifact before this new run has passed.
rm -f "$partial_saif"
log="$OUT_DIR/fa_two_tile_pingpong_test.log"
"$OUT_DIR/simv" +UVM_TESTNAME=fa_two_tile_pingpong_test +ntb_random_seed="$SEED" \
  +CLK_PERIOD_NS="$SIM_CLOCK_PERIOD_NS" +SAIF_ENABLE +SAIF_FILE="$partial_saif" \
  -l "$log"

if ! grep -Eq 'UVM_ERROR :[[:space:]]*0' "$log" || \
   ! grep -Eq 'UVM_FATAL :[[:space:]]*0' "$log"; then
  echo "UVM failed; partial SAIF is retained at $partial_saif and was not published" >&2
  exit 1
fi
if [[ ! -s "$partial_saif" ]]; then
  echo "SAIF capture completed without producing $partial_saif" >&2
  exit 1
fi

start_cycle=$(sed -n 's/.*\[SAIF_CAPTURE\] START cycle=\([0-9][0-9]*\).*/\1/p' "$log" | tail -n 1)
stop_cycle=$(sed -n 's/.*\[SAIF_CAPTURE\] STOP cycle=\([0-9][0-9]*\).*/\1/p' "$log" | tail -n 1)
if [[ -z "$start_cycle" || -z "$stop_cycle" ]]; then
  echo "SAIF capture markers are missing from $log" >&2
  exit 1
fi

mv "$partial_saif" "$saif_file"
git_commit=$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf 'unknown')
git_status_hash=$(git -C "$ROOT_DIR" status --porcelain=v1 | sha256sum | awk '{print $1}')
tensor_checksum=$({ grep -E '\[FCOV_MATH\]|\[FCOV_SUMMARY\]' "$log" || true; } | \
  sha256sum | awk '{print $1}')

{
  printf '{\n'
  printf '  "profile": "%s",\n' "$PROFILE"
  printf '  "test": "fa_two_tile_pingpong_test",\n'
  printf '  "seed": %s,\n' "$SEED"
  printf '  "rtl_hash": "%s",\n' "$rtl_hash"
  printf '  "git_commit": "%s",\n' "$git_commit"
  printf '  "git_status_hash": "%s",\n' "$git_status_hash"
  printf '  "simulator": "%s",\n' "$VCS_BIN"
  printf '  "clock_period_ns": %s,\n' "$SIM_CLOCK_PERIOD_NS"
  printf '  "strip_path": "tb_top/dut",\n'
  printf '  "start_cycle": %s,\n' "$start_cycle"
  printf '  "stop_cycle": %s,\n' "$stop_cycle"
  printf '  "sampled_cycles": %s,\n' "$((stop_cycle - start_cycle))"
  printf '  "sequence": {"seq_q": 64, "seq_kv": 64, "num_q_heads": 1, "num_kv_heads": 1, "head_dim": 64, "tile_q": 32, "tile_k": 32},\n'
  printf '  "ready_low_pct": 0,\n'
  printf '  "window": "two_tile_load+pingpong_refill+compute+normalization+axi_writeback_no_stall",\n'
  printf '  "tensor_log_checksum": "%s",\n' "$tensor_checksum"
  printf '  "status": "pass"\n'
  printf '}\n'
} > "$metadata_file"

echo "SAIF published: $saif_file"
echo "Metadata: $metadata_file"
echo "Capture cycles: $start_cycle..$stop_cycle"
