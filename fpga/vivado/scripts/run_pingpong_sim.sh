#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fpga_dir="$(cd "${script_dir}/../.." && pwd)"
repo_dir="$(cd "${fpga_dir}/.." && pwd)"
build_dir="${fpga_dir}/vivado/build/sim-pingpong/xsim"
vivado_root="${XILINX_VIVADO:-/opt/Xilinx/Vivado/2023.1}"
xvlog="${vivado_root}/bin/xvlog"
xelab="${vivado_root}/bin/xelab"
xsim="${vivado_root}/bin/xsim"

for tool in "${xvlog}" "${xelab}" "${xsim}"; do
    if [[ ! -x "${tool}" ]]; then
        printf 'Vivado simulation tool not found: %s\n' "${tool}" >&2
        exit 1
    fi
done

mkdir -p "${build_dir}"
cd "${build_dir}"

"${xvlog}" --sv \
    -i "${repo_dir}/rtl/common" \
    -i "${repo_dir}/tb/module_tb/common" \
    "${repo_dir}/rtl/axi/axi4_slave_if.v" \
    "${repo_dir}/rtl/memory/pingpong_buffer.v" \
    "${repo_dir}/rtl/memory/banked_sram.v" \
    "${repo_dir}/rtl/memory/qkv_tile_cache.v" \
    "${fpga_dir}/rtl/axis_tile_loader.v" \
    "${repo_dir}/tb/module_tb/memory/tb_axis_tile_loader.sv"
"${xelab}" tb_axis_tile_loader -s tb_axis_tile_loader_sim
"${xsim}" tb_axis_tile_loader_sim -runall

"${xvlog}" --sv -d TB_NO_FSDB \
    -i "${repo_dir}/rtl/common" \
    -i "${repo_dir}/tb/module_tb/common" \
    "${repo_dir}/rtl/control/accel_scheduler.v" \
    "${repo_dir}/tb/module_tb/control/tb_accel_scheduler.sv"
"${xelab}" tb_accel_scheduler -s tb_accel_scheduler_sim
"${xsim}" tb_accel_scheduler_sim -runall
