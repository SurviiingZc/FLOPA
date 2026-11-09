#!/usr/bin/env bash
set -euo pipefail

# ABI-v3 dense runtime-d validation replaces the historical causal/decode matrix.
# The new runner preserves one build, uses short sequences, and audits every log.
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$script_dir/run_runtime_d_short.sh" "$@"
