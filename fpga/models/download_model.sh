#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
revision="09816acd5d99df7be770d85ea30822623dab342c"
filename="SmolLM2-135M-Instruct-Q8_0.gguf"
expected_size="144811360"
expected_sha256="5a1395716f7913741cc51d98581b9b1228d80987a9f7d3664106742eb06bba83"
url="https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve"
url+="/${revision}/${filename}?download=true"
output="${script_dir}/${filename}"

if [[ -f "${output}" ]] && \
    [[ "$(stat --format='%s' "${output}")" == "${expected_size}" ]]; then
    printf '%s  %s\n' "${expected_sha256}" "${output}" | sha256sum --check --status
    printf 'Model already downloaded and verified: %s\n' "${output}"
    exit 0
fi

curl --fail --location --retry 20 --retry-delay 3 --continue-at - \
    --output "${output}" "${url}"

actual_size="$(stat --format='%s' "${output}")"
if [[ "${actual_size}" != "${expected_size}" ]]; then
    printf 'Model size mismatch: expected %s, got %s\n' \
        "${expected_size}" "${actual_size}" >&2
    exit 1
fi

printf '%s  %s\n' "${expected_sha256}" "${output}" | sha256sum --check
