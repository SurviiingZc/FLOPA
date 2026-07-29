#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf 'Error: source this file instead of executing it.\n' >&2
    printf 'Usage: source fpga/my_env.sh\n' >&2
    exit 1
fi

_vitis_settings="/opt/Xilinx/Vitis/2023.1/settings64.sh"
_xilinx_license="/opt/Xilinx/license/Xlnx_2024.lic"
_existing_xilinx_license="${XILINXD_LICENSE_FILE:-}"

if [[ ! -r "${_vitis_settings}" ]]; then
    printf 'Error: Vitis 2023.1 settings not found: %s\n' "${_vitis_settings}" >&2
    unset _vitis_settings
    return 1
fi

if [[ -r "${_xilinx_license}" ]]; then
    case ":${XILINXD_LICENSE_FILE:-}:" in
        *":${_xilinx_license}:"*)
            ;;
        *)
            export XILINXD_LICENSE_FILE="${_xilinx_license}${_existing_xilinx_license:+:}"
            export XILINXD_LICENSE_FILE+="${_existing_xilinx_license}"
            ;;
    esac
fi

unset _existing_xilinx_license
unset _xilinx_license

if ! source "${_vitis_settings}"; then
    printf 'Error: failed to load Vitis 2023.1 toolchain.\n' >&2
    unset _vitis_settings
    return 1
fi

unset _vitis_settings
