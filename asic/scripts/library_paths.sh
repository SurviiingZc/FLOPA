#!/usr/bin/env bash

FA_STD_ROOT_DEFAULT="/data/public/STD/tcbn28hpcplusbwp12t30p140_190a/tcbn28hpcplusbwp12t30p140_180a_ccs/TSMCHOME/digital/Front_End/timing_power_noise/CCS/tcbn28hpcplusbwp12t30p140_180a"
FA_SRAM_ROOT_DEFAULT="/data/public/SRAM/uhdsp_256x8m4s/NLDM"

fa_select_libraries() {
  local root_dir="$1"
  local corner="$2"
  local std_root="${FA_STD_ROOT:-$FA_STD_ROOT_DEFAULT}"
  local sram_root="${FA_SRAM_ROOT:-$FA_SRAM_ROOT_DEFAULT}"

  case "$corner" in
    tt)
      FA_STD_DB="$std_root/tcbn28hpcplusbwp12t30p140tt0p9v25c_ccs.db"
      FA_SRAM_LIB_NAME="uhdsp_256x8m4s_tt0p9v25c"
      ;;
    ss)
      FA_STD_DB="$std_root/tcbn28hpcplusbwp12t30p140ssg0p9v125c_ccs.db"
      FA_SRAM_LIB_NAME="uhdsp_256x8m4s_ssg0p9v125c"
      ;;
    *)
      echo "CORNER must be tt or ss" >&2
      return 2
      ;;
  esac

  FA_SRAM_LIB_FILE="$sram_root/$FA_SRAM_LIB_NAME.lib"
  FA_SRAM_DB="$root_dir/asic/dc/work/lib/$FA_SRAM_LIB_NAME.db"
  export FA_STD_DB FA_SRAM_LIB_NAME FA_SRAM_LIB_FILE FA_SRAM_DB
}
