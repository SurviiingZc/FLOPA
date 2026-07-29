#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
model_dir="$(cd "${script_dir}/.." && pwd)"
fpga_dir="$(cd "${model_dir}/.." && pwd)"
build_dir="${model_dir}/build-aarch64"
toolchain="${model_dir}/cmake/aarch64-petalinux.cmake"
cmake_bin="${CMAKE_BIN:-/usr/bin/cmake}"

"${script_dir}/fetch_llama_cpp.sh"

if [[ ! -r "${toolchain}" ]]; then
    printf 'PetaLinux CMake toolchain not found: %s\n' "${toolchain}" >&2
    exit 1
fi

if [[ ! -x "${cmake_bin}" ]]; then
    printf 'Usable system CMake not found: %s\n' "${cmake_bin}" >&2
    exit 1
fi

"${cmake_bin}" -S "${model_dir}" -B "${build_dir}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="${toolchain}" \
    -DGGML_NATIVE=OFF \
    -DGGML_CPU_ARM_ARCH=armv8-a+crc \
    -DGGML_OPENMP=OFF \
    -DDIT_FA_ENABLE_PL=ON \
    -DBUILD_SHARED_LIBS=OFF
"${cmake_bin}" --build "${build_dir}" \
    --target dit_fa_model_bench --parallel "${JOBS:-4}"

file "${build_dir}/dit_fa_model_bench"
