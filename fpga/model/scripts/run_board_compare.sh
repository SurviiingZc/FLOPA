#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sequence_length="${1:-${SEQUENCE_LENGTH:-1024}}"
benchmark="${BENCH_PATH:-${script_dir}/dit_fa_model_bench}"
xclbin="${XCLBIN_PATH:-/run/media/mmcblk0p1/dit_fa.xclbin}"
model="${MODEL_PATH:-${script_dir}/SmolLM2-135M-Instruct-Q8_0.gguf}"
prompt="${PROMPT_PATH:-${script_dir}/prompt_1024.txt}"
output_dir="${OUTPUT_DIR:-${script_dir}/results}"
threads="${THREADS:-2}"
warmups="${WARMUPS:-1}"
repetitions="${REPETITIONS:-1}"
pl_clock_mhz="${PL_CLOCK_MHZ:-170}"

if [[ ! "${sequence_length}" =~ ^[0-9]+$ ]] \
    || (( sequence_length < 32 || sequence_length > 1024 \
        || sequence_length % 32 != 0 )); then
    printf 'Sequence length must be a multiple of 32 in [32, 1024]: %s\n' \
        "${sequence_length}" >&2
    exit 2
fi

for required_file in "${benchmark}" "${xclbin}" "${model}" "${prompt}"; do
    if [[ ! -r "${required_file}" ]]; then
        printf 'Required file is not readable: %s\n' "${required_file}" >&2
        exit 1
    fi
done

if (( EUID != 0 )); then
    exec sudo -E "$0" "${sequence_length}"
fi

mkdir -p "${output_dir}"
timestamp="$(date +%Y%m%d-%H%M%S)"
result_path="${output_dir}/compare-seq${sequence_length}-${timestamp}.json"
log_path="${output_dir}/compare-seq${sequence_length}-${timestamp}.log"

printf 'Result: %s\n' "${result_path}"
printf 'Log:    %s\n' "${log_path}"

"${benchmark}" \
    --backend compare \
    --xclbin "${xclbin}" \
    --model "${model}" \
    --prompt "${prompt}" \
    --sequence-length "${sequence_length}" \
    --threads "${threads}" \
    --warmups "${warmups}" \
    --repetitions "${repetitions}" \
    --pl-clock-mhz "${pl_clock_mhz}" \
    --output "${result_path}" 2>&1 | tee "${log_path}"
