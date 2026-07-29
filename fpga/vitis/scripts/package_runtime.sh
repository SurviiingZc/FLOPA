#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 7 ]]; then
    printf '%s\n' \
        "Usage: $0 <xclbin> <boot_bin> <host> <runtime_dir> <archive>" \
        '       <frequency_hz> <git_commit>' >&2
    exit 2
fi

xclbin="$(realpath "$1")"
boot_bin="$(realpath "$2")"
host="$(realpath "$3")"
runtime_dir="$4"
archive="$5"
frequency_hz="$6"
git_commit="$7"

rm -rf "${runtime_dir}"
mkdir -p "${runtime_dir}"
install -m 0644 "${xclbin}" "${runtime_dir}/dit_fa.xclbin"
install -m 0644 "${boot_bin}" "${runtime_dir}/BOOT.BIN"
install -m 0755 "${host}" "${runtime_dir}/dit_fa_xrt_test"

cp "$(dirname "$0")/../runtime.README.md" "${runtime_dir}/README.md"
{
    printf 'git_commit=%s\n' "${git_commit}"
    printf 'frequency_hz=%s\n' "${frequency_hz}"
    printf 'platform=xilinx_vck190_base_202310_1\n'
    printf 'toolchain=Vitis_2023.1\n'
} > "${runtime_dir}/BUILD_INFO"
(
    cd "${runtime_dir}"
    sha256sum BOOT.BIN dit_fa.xclbin dit_fa_xrt_test BUILD_INFO > SHA256SUMS
)

tar -C "$(dirname "${runtime_dir}")" -czf "${archive}" \
    "$(basename "${runtime_dir}")"

printf 'Runtime directory: %s\n' "${runtime_dir}"
printf 'Runtime archive:   %s\n' "${archive}"
