#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 5 ]]; then
    printf 'Usage: %s <xclbin> <boot_bin> <host> <runtime_dir> <archive>\n' "$0" >&2
    exit 2
fi

xclbin="$(realpath "$1")"
boot_bin="$(realpath "$2")"
host="$(realpath "$3")"
runtime_dir="$4"
archive="$5"

rm -rf "${runtime_dir}"
mkdir -p "${runtime_dir}"
install -m 0644 "${xclbin}" "${runtime_dir}/dit_fa.xclbin"
install -m 0644 "${boot_bin}" "${runtime_dir}/BOOT.BIN"
install -m 0755 "${host}" "${runtime_dir}/dit_fa_xrt_test"

cp "$(dirname "$0")/../runtime.README.md" "${runtime_dir}/README.md"
(
    cd "${runtime_dir}"
    sha256sum BOOT.BIN dit_fa.xclbin dit_fa_xrt_test > SHA256SUMS
)

tar -C "$(dirname "${runtime_dir}")" -czf "${archive}" \
    "$(basename "${runtime_dir}")"

printf 'Runtime directory: %s\n' "${runtime_dir}"
printf 'Runtime archive:   %s\n' "${archive}"
