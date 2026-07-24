#!/usr/bin/env bash
set -euo pipefail

# Run the random 512x512 UVM workload on the mapped TT netlist, annotate the
# matching SDF, and publish DUT-only gate SAIF only after a clean UVM result.
SIM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOT_DIR=$(cd "$SIM_ROOT/../.." && pwd)
VCS_BIN="${VCS:-vcs}"
SEED="${SEED:-301}"
PROFILE="${PROFILE:-gate_clock_gated_random_qkv_512x512_seed${SEED}}"
OUT_DIR="${OUT_DIR:-$SIM_ROOT/build/saif_${PROFILE}}"
SIM_CLOCK_PERIOD_NS="${SIM_CLOCK_PERIOD_NS:-1.6}"
NETLIST="${NETLIST:-$ROOT_DIR/asic/dc/work/synth/tt/system_clock_gated/attention_accel_top/results/attention_accel_top_mapped.v}"
SDF_FILE="${SDF_FILE:-$ROOT_DIR/asic/dc/work/synth/tt/system_clock_gated/attention_accel_top/results/attention_accel_top.sdf}"
DDC_FILE="${DDC_FILE:-$ROOT_DIR/asic/dc/work/synth/tt/system_clock_gated/attention_accel_top/results/attention_accel_top.ddc}"
STD_CELL_V="${STD_CELL_V:-/data/public/STD/tcbn28hpcplusbwp12t30p140_190a/tcbn28hpcplusbwp12t30p140_170a_vlg/TSMCHOME/digital/Front_End/verilog/tcbn28hpcplusbwp12t30p140_170a/tcbn28hpcplusbwp12t30p140.v}"
SRAM_V="${SRAM_V:-/data/public/SRAM/uhdsp_256x8m4s/VERILOG/uhdsp_256x8m4s_tt0p9v25c.v}"
POWER_READBACK="${POWER_READBACK:-0}"
SEQ_Q="${SEQ_Q:-512}"
SEQ_KV="${SEQ_KV:-512}"
READY_LOW_PCT="${READY_LOW_PCT:-0}"

if [[ ! "$SEED" =~ ^[0-9]+$ ]]; then
  echo "SEED must be a non-negative integer" >&2
  exit 2
fi
if [[ ! "$PROFILE" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "PROFILE may contain only letters, digits, dot, underscore, and dash" >&2
  exit 2
fi
if [[ ! "$SIM_CLOCK_PERIOD_NS" =~ ^[0-9]+([.][0-9]+)?$ ]] || \
   ! awk -v period="$SIM_CLOCK_PERIOD_NS" 'BEGIN { exit (period > 0.0) ? 0 : 1 }'; then
  echo "SIM_CLOCK_PERIOD_NS must be a positive number" >&2
  exit 2
fi
if [[ "$POWER_READBACK" != "0" && "$POWER_READBACK" != "1" ]]; then
  echo "POWER_READBACK must be 0 or 1" >&2
  exit 2
fi
for value in "$SEQ_Q" "$SEQ_KV" "$READY_LOW_PCT"; do
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "SEQ_Q, SEQ_KV, and READY_LOW_PCT must be non-negative integers" >&2
    exit 2
  fi
done
if (( SEQ_Q == 0 || SEQ_Q > 512 || SEQ_KV == 0 || SEQ_KV > 512 ||
      SEQ_Q > SEQ_KV || READY_LOW_PCT > 75 )); then
  echo "Require 1 <= SEQ_Q <= SEQ_KV <= 512 and 0 <= READY_LOW_PCT <= 75" >&2
  exit 2
fi
for input in "$NETLIST" "$SDF_FILE" "$DDC_FILE" "$STD_CELL_V" "$SRAM_V"; do
  if [[ ! -f "$input" ]]; then
    echo "Required gate-level input is missing: $input" >&2
    exit 2
  fi
done

# Gate simulation must observe scheduler progress only through preserved top
# ports. Internal RTL hierarchy is intentionally not stable after mapping.
if ! grep -Eq '(^|[^[:alnum:]_])debug_tile_indices_o([^[:alnum:]_]|$)' "$NETLIST"; then
  echo "Gate netlist lacks debug_tile_indices_o; rerun make synth before gate-saif" >&2
  exit 2
fi
if rg -n 'dut[.]' "$SIM_ROOT/../uvm"; then
  echo "Gate UVM must not reference DUT internal hierarchy; use status_if ports" >&2
  exit 2
fi

NETLIST=$(readlink -f "$NETLIST")
SDF_FILE=$(readlink -f "$SDF_FILE")
DDC_FILE=$(readlink -f "$DDC_FILE")
STD_CELL_V=$(readlink -f "$STD_CELL_V")
SRAM_V=$(readlink -f "$SRAM_V")
rtl_hash=$(find "$ROOT_DIR/rtl" -type f -print0 | sort -z | \
  xargs -0 sha256sum | sha256sum | awk '{print $1}')
saif_dir="$ROOT_DIR/asic/dc/work/power/saif/$rtl_hash"
saif_file="$saif_dir/$PROFILE.saif"
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
  rm -f "$OUT_DIR"/flex*.log "$OUT_DIR"/ucli.key
  rm -rf "$SIM_ROOT/csrc"
}
trap cleanup_transients EXIT

"$VCS_BIN" -full64 -sverilog -ntb_opts uvm -timescale=1ns/1ps \
  -debug_access+all -kdb -lca -Mdir="$OUT_DIR/csrc" \
  -f filelists/uvm.f "$NETLIST" "$STD_CELL_V" "$SRAM_V" -top tb_top \
  -l "$OUT_DIR/compile.log" -o "$OUT_DIR/simv"

# Never replace an earlier passing artifact with a failed or incomplete run.
rm -f "$partial_saif"
log="$OUT_DIR/fa_random_qkv_test.log"
"$OUT_DIR/simv" +UVM_TESTNAME=fa_random_qkv_test +ntb_random_seed="$SEED" \
  +FA_SEQ_Q="$SEQ_Q" +FA_SEQ_KV="$SEQ_KV" +FA_READY_LOW_PCT="$READY_LOW_PCT" \
  +CLK_PERIOD_NS="$SIM_CLOCK_PERIOD_NS" +SAIF_ENABLE +SAIF_FILE="$partial_saif" \
  -sdf max:tb_top.dut:"$SDF_FILE" +no_notifier -l "$log"

if ! grep -Eq 'UVM_ERROR :[[:space:]]*0' "$log" || \
   ! grep -Eq 'UVM_FATAL :[[:space:]]*0' "$log"; then
  echo "Gate UVM failed; partial SAIF is retained at $partial_saif and was not published" >&2
  exit 1
fi
if [[ ! -s "$partial_saif" ]]; then
  echo "Gate SAIF capture completed without producing $partial_saif" >&2
  exit 1
fi

start_cycle=$(sed -n 's/.*\[SAIF_CAPTURE\] START cycle=\([0-9][0-9]*\).*/\1/p' "$log" | tail -n 1)
stop_cycle=$(sed -n 's/.*\[SAIF_CAPTURE\] STOP cycle=\([0-9][0-9]*\).*/\1/p' "$log" | tail -n 1)
if [[ -z "$start_cycle" || -z "$stop_cycle" ]]; then
  echo "Gate SAIF capture markers are missing from $log" >&2
  exit 1
fi

mv "$partial_saif" "$saif_file"
git_commit=$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf 'unknown')
git_status_hash=$(git -C "$ROOT_DIR" status --porcelain=v1 | sha256sum | awk '{print $1}')
netlist_hash=$(sha256sum "$NETLIST" | awk '{print $1}')
sdf_hash=$(sha256sum "$SDF_FILE" | awk '{print $1}')
ddc_hash=$(sha256sum "$DDC_FILE" | awk '{print $1}')
tensor_checksum=$({ grep -E '\[FCOV_MATH\]|\[FCOV_SUMMARY\]' "$log" || true; } | \
  sha256sum | awk '{print $1}')

{
  printf '{\n'
  printf '  "profile": "%s",\n' "$PROFILE"
  printf '  "test": "fa_random_qkv_test",\n'
  printf '  "seed": %s,\n' "$SEED"
  printf '  "gate_level": true,\n'
  printf '  "rtl_hash": "%s",\n' "$rtl_hash"
  printf '  "git_commit": "%s",\n' "$git_commit"
  printf '  "git_status_hash": "%s",\n' "$git_status_hash"
  printf '  "simulator": "%s",\n' "$VCS_BIN"
  printf '  "clock_period_ns": %s,\n' "$SIM_CLOCK_PERIOD_NS"
  printf '  "netlist": "%s",\n' "$NETLIST"
  printf '  "netlist_sha256": "%s",\n' "$netlist_hash"
  printf '  "sdf": "%s",\n' "$SDF_FILE"
  printf '  "sdf_sha256": "%s",\n' "$sdf_hash"
  printf '  "ddc": "%s",\n' "$DDC_FILE"
  printf '  "ddc_sha256": "%s",\n' "$ddc_hash"
  printf '  "strip_path": "tb_top/dut",\n'
  printf '  "start_cycle": %s,\n' "$start_cycle"
  printf '  "stop_cycle": %s,\n' "$stop_cycle"
  printf '  "sampled_cycles": %s,\n' "$((stop_cycle - start_cycle))"
  printf '  "sequence": {"seq_q": %s, "seq_kv": %s, "num_q_heads": 1, "num_kv_heads": 1, "head_dim": 64, "tile_q": 32, "tile_k": 32},\n' "$SEQ_Q" "$SEQ_KV"
  printf '  "ready_low_pct": %s,\n' "$READY_LOW_PCT"
  printf '  "window": "gate_level_random_%sx%s_load+pingpong_refill+compute+normalization+axi_writeback",\n' "$SEQ_Q" "$SEQ_KV"
  printf '  "tensor_log_checksum": "%s",\n' "$tensor_checksum"
  printf '  "status": "pass"\n'
  printf '}\n'
} > "$metadata_file"

echo "Gate SAIF published: $saif_file"
echo "Metadata: $metadata_file"
echo "Capture cycles: $start_cycle..$stop_cycle"

if [[ "$POWER_READBACK" == "1" ]]; then
  SAIF_FILE="$saif_file" DDC_FILE="$DDC_FILE" PROFILE="$PROFILE" \
    CLOCK_PERIOD="$SIM_CLOCK_PERIOD_NS" \
    "$ROOT_DIR/asic/scripts/run_saif_power.sh"
fi
