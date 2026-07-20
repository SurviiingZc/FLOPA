#!/usr/bin/env bash

# Public physical collateral discovered on the server. These source views are
# inputs to Milkyway-library preparation; FA_MW_LIB must point to the resulting
# combined design library before run_synth_physical.sh is launched.
FA_STD_MW_REF_DEFAULT="/data/public/STD/tcbn28hpcplusbwp12t30p140_190a/tcbn28hpcplusbwp12t30p140_170a_apt/TSMCHOME/digital/Back_End/milkyway/tcbn28hpcplusbwp12t30p140_170a/cell_frame_VHV_0d5_0/tcbn28hpcplusbwp12t30p140"
FA_STD_LEF_DEFAULT="/data/public/STD/tcbn28hpcplusbwp12t30p140_190a/tcbn28hpcplusbwp12t30p140_170a_sef/TSMCHOME/digital/Back_End/lef/tcbn28hpcplusbwp12t30p140_170a/lef/tcbn28hpcplusbwp12t30p140.lef"
FA_SRAM_LEF_DEFAULT="/data/public/SRAM/uhdsp_256x8m4s/LEF/uhdsp_256x8m4s.lef"
FA_SRAM_GDS_DEFAULT="/data/public/SRAM/uhdsp_256x8m4s/GDSII/uhdsp_256x8m4s.gds"
FA_RC_ROOT_DEFAULT="/data/public/RC/1P10M 6X3Z UT-ALRDL-RCfile"

export FA_STD_MW_REF_DEFAULT FA_STD_LEF_DEFAULT FA_SRAM_LEF_DEFAULT
export FA_SRAM_GDS_DEFAULT FA_RC_ROOT_DEFAULT
