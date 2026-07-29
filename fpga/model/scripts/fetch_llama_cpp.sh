#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fpga_dir="$(cd "${script_dir}/../.." && pwd)"
source_dir="${fpga_dir}/third_party/llama.cpp"
patch_file="${fpga_dir}/model/patches/llama-eval-override.patch"
revision="6ba5ef247034cd57201360aed246d98f5a404d92"

if [[ ! -d "${source_dir}/.git" ]]; then
    mkdir -p "$(dirname "${source_dir}")"
    git clone --filter=blob:none --no-checkout \
        https://github.com/ggml-org/llama.cpp.git "${source_dir}"
fi

git -C "${source_dir}" fetch --depth 1 origin "${revision}"
git -C "${source_dir}" checkout --detach "${revision}"

actual="$(git -C "${source_dir}" rev-parse HEAD)"
if [[ "${actual}" != "${revision}" ]]; then
    printf 'llama.cpp revision mismatch: expected %s, got %s\n' \
        "${revision}" "${actual}" >&2
    exit 1
fi

if git -C "${source_dir}" apply --reverse --check "${patch_file}" 2>/dev/null; then
    :
elif git -C "${source_dir}" apply --check "${patch_file}"; then
    git -C "${source_dir}" apply "${patch_file}"
else
    printf 'llama.cpp override patch does not apply cleanly\n' >&2
    exit 1
fi

printf 'llama.cpp ready at %s with PL override patch\n' "${actual}"
