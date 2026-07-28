// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2023 Advanced Micro Devices, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2023.1 (lin64) Build 3865809 Sun May  7 15:04:56 MDT 2023
// Date        : Tue Jul 28 15:01:39 2026
// Host        : xidianhyy-HP-Pro-Tower-ZHAN-99-G9-Desktop-PC running 64-bit Ubuntu 20.04.6 LTS
// Command     : write_verilog -force -mode synth_stub -rename_top decalper_eb_ot_sdeen_pot_pi_dehcac_xnilix -prefix
//               decalper_eb_ot_sdeen_pot_pi_dehcac_xnilix_ vitis_design_noc_lpddr4_0_stub.v
// Design      : vitis_design_noc_lpddr4_0
// Purpose     : Stub declaration of top-level module interface
// Device      : xcvc1902-vsva2197-2MP-e-S
// --------------------------------------------------------------------------------

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// The synthesis directives are for Synopsys Synplify support to prevent IO buffer insertion.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
(* X_CORE_INFO = "bd_28ba,Vivado 2023.1" *)
module decalper_eb_ot_sdeen_pot_pi_dehcac_xnilix(S00_INI_internoc, S01_INI_internoc, 
  S02_INI_internoc, S03_INI_internoc, sys_clk0_clk_p, sys_clk0_clk_n, CH0_LPDDR4_0_dq_a, 
  CH0_LPDDR4_0_dq_b, CH0_LPDDR4_0_dqs_t_a, CH0_LPDDR4_0_dqs_t_b, CH0_LPDDR4_0_dqs_c_a, 
  CH0_LPDDR4_0_dqs_c_b, CH0_LPDDR4_0_ca_a, CH0_LPDDR4_0_ca_b, CH0_LPDDR4_0_cs_a, 
  CH0_LPDDR4_0_cs_b, CH0_LPDDR4_0_ck_t_a, CH0_LPDDR4_0_ck_t_b, CH0_LPDDR4_0_ck_c_a, 
  CH0_LPDDR4_0_ck_c_b, CH0_LPDDR4_0_cke_a, CH0_LPDDR4_0_cke_b, CH0_LPDDR4_0_dmi_a, 
  CH0_LPDDR4_0_dmi_b, CH0_LPDDR4_0_reset_n, CH1_LPDDR4_0_dq_a, CH1_LPDDR4_0_dq_b, 
  CH1_LPDDR4_0_dqs_t_a, CH1_LPDDR4_0_dqs_t_b, CH1_LPDDR4_0_dqs_c_a, CH1_LPDDR4_0_dqs_c_b, 
  CH1_LPDDR4_0_ca_a, CH1_LPDDR4_0_ca_b, CH1_LPDDR4_0_cs_a, CH1_LPDDR4_0_cs_b, 
  CH1_LPDDR4_0_ck_t_a, CH1_LPDDR4_0_ck_t_b, CH1_LPDDR4_0_ck_c_a, CH1_LPDDR4_0_ck_c_b, 
  CH1_LPDDR4_0_cke_a, CH1_LPDDR4_0_cke_b, CH1_LPDDR4_0_dmi_a, CH1_LPDDR4_0_dmi_b, 
  CH1_LPDDR4_0_reset_n, sys_clk1_clk_p, sys_clk1_clk_n, CH0_LPDDR4_1_dq_a, 
  CH0_LPDDR4_1_dq_b, CH0_LPDDR4_1_dqs_t_a, CH0_LPDDR4_1_dqs_t_b, CH0_LPDDR4_1_dqs_c_a, 
  CH0_LPDDR4_1_dqs_c_b, CH0_LPDDR4_1_ca_a, CH0_LPDDR4_1_ca_b, CH0_LPDDR4_1_cs_a, 
  CH0_LPDDR4_1_cs_b, CH0_LPDDR4_1_ck_t_a, CH0_LPDDR4_1_ck_t_b, CH0_LPDDR4_1_ck_c_a, 
  CH0_LPDDR4_1_ck_c_b, CH0_LPDDR4_1_cke_a, CH0_LPDDR4_1_cke_b, CH0_LPDDR4_1_dmi_a, 
  CH0_LPDDR4_1_dmi_b, CH0_LPDDR4_1_reset_n, CH1_LPDDR4_1_dq_a, CH1_LPDDR4_1_dq_b, 
  CH1_LPDDR4_1_dqs_t_a, CH1_LPDDR4_1_dqs_t_b, CH1_LPDDR4_1_dqs_c_a, CH1_LPDDR4_1_dqs_c_b, 
  CH1_LPDDR4_1_ca_a, CH1_LPDDR4_1_ca_b, CH1_LPDDR4_1_cs_a, CH1_LPDDR4_1_cs_b, 
  CH1_LPDDR4_1_ck_t_a, CH1_LPDDR4_1_ck_t_b, CH1_LPDDR4_1_ck_c_a, CH1_LPDDR4_1_ck_c_b, 
  CH1_LPDDR4_1_cke_a, CH1_LPDDR4_1_cke_b, CH1_LPDDR4_1_dmi_a, CH1_LPDDR4_1_dmi_b, 
  CH1_LPDDR4_1_reset_n)
/* synthesis syn_black_box black_box_pad_pin="S00_INI_internoc[0:0],S01_INI_internoc[0:0],S02_INI_internoc[0:0],S03_INI_internoc[0:0],sys_clk0_clk_p[0:0],sys_clk0_clk_n[0:0],CH0_LPDDR4_0_dq_a[15:0],CH0_LPDDR4_0_dq_b[15:0],CH0_LPDDR4_0_dqs_t_a[1:0],CH0_LPDDR4_0_dqs_t_b[1:0],CH0_LPDDR4_0_dqs_c_a[1:0],CH0_LPDDR4_0_dqs_c_b[1:0],CH0_LPDDR4_0_ca_a[5:0],CH0_LPDDR4_0_ca_b[5:0],CH0_LPDDR4_0_cs_a[0:0],CH0_LPDDR4_0_cs_b[0:0],CH0_LPDDR4_0_ck_t_a[0:0],CH0_LPDDR4_0_ck_t_b[0:0],CH0_LPDDR4_0_ck_c_a[0:0],CH0_LPDDR4_0_ck_c_b[0:0],CH0_LPDDR4_0_cke_a[0:0],CH0_LPDDR4_0_cke_b[0:0],CH0_LPDDR4_0_dmi_a[1:0],CH0_LPDDR4_0_dmi_b[1:0],CH0_LPDDR4_0_reset_n[0:0],CH1_LPDDR4_0_dq_a[15:0],CH1_LPDDR4_0_dq_b[15:0],CH1_LPDDR4_0_dqs_t_a[1:0],CH1_LPDDR4_0_dqs_t_b[1:0],CH1_LPDDR4_0_dqs_c_a[1:0],CH1_LPDDR4_0_dqs_c_b[1:0],CH1_LPDDR4_0_ca_a[5:0],CH1_LPDDR4_0_ca_b[5:0],CH1_LPDDR4_0_cs_a[0:0],CH1_LPDDR4_0_cs_b[0:0],CH1_LPDDR4_0_ck_t_a[0:0],CH1_LPDDR4_0_ck_t_b[0:0],CH1_LPDDR4_0_ck_c_a[0:0],CH1_LPDDR4_0_ck_c_b[0:0],CH1_LPDDR4_0_cke_a[0:0],CH1_LPDDR4_0_cke_b[0:0],CH1_LPDDR4_0_dmi_a[1:0],CH1_LPDDR4_0_dmi_b[1:0],CH1_LPDDR4_0_reset_n[0:0],sys_clk1_clk_p[0:0],sys_clk1_clk_n[0:0],CH0_LPDDR4_1_dq_a[15:0],CH0_LPDDR4_1_dq_b[15:0],CH0_LPDDR4_1_dqs_t_a[1:0],CH0_LPDDR4_1_dqs_t_b[1:0],CH0_LPDDR4_1_dqs_c_a[1:0],CH0_LPDDR4_1_dqs_c_b[1:0],CH0_LPDDR4_1_ca_a[5:0],CH0_LPDDR4_1_ca_b[5:0],CH0_LPDDR4_1_cs_a[0:0],CH0_LPDDR4_1_cs_b[0:0],CH0_LPDDR4_1_ck_t_a[0:0],CH0_LPDDR4_1_ck_t_b[0:0],CH0_LPDDR4_1_ck_c_a[0:0],CH0_LPDDR4_1_ck_c_b[0:0],CH0_LPDDR4_1_cke_a[0:0],CH0_LPDDR4_1_cke_b[0:0],CH0_LPDDR4_1_dmi_a[1:0],CH0_LPDDR4_1_dmi_b[1:0],CH0_LPDDR4_1_reset_n[0:0],CH1_LPDDR4_1_dq_a[15:0],CH1_LPDDR4_1_dq_b[15:0],CH1_LPDDR4_1_dqs_t_a[1:0],CH1_LPDDR4_1_dqs_t_b[1:0],CH1_LPDDR4_1_dqs_c_a[1:0],CH1_LPDDR4_1_dqs_c_b[1:0],CH1_LPDDR4_1_ca_a[5:0],CH1_LPDDR4_1_ca_b[5:0],CH1_LPDDR4_1_cs_a[0:0],CH1_LPDDR4_1_cs_b[0:0],CH1_LPDDR4_1_ck_t_a[0:0],CH1_LPDDR4_1_ck_t_b[0:0],CH1_LPDDR4_1_ck_c_a[0:0],CH1_LPDDR4_1_ck_c_b[0:0],CH1_LPDDR4_1_cke_a[0:0],CH1_LPDDR4_1_cke_b[0:0],CH1_LPDDR4_1_dmi_a[1:0],CH1_LPDDR4_1_dmi_b[1:0],CH1_LPDDR4_1_reset_n[0:0]" */;
  input [0:0]S00_INI_internoc;
  input [0:0]S01_INI_internoc;
  input [0:0]S02_INI_internoc;
  input [0:0]S03_INI_internoc;
  input [0:0]sys_clk0_clk_p;
  input [0:0]sys_clk0_clk_n;
  inout [15:0]CH0_LPDDR4_0_dq_a;
  inout [15:0]CH0_LPDDR4_0_dq_b;
  inout [1:0]CH0_LPDDR4_0_dqs_t_a;
  inout [1:0]CH0_LPDDR4_0_dqs_t_b;
  inout [1:0]CH0_LPDDR4_0_dqs_c_a;
  inout [1:0]CH0_LPDDR4_0_dqs_c_b;
  output [5:0]CH0_LPDDR4_0_ca_a;
  output [5:0]CH0_LPDDR4_0_ca_b;
  output [0:0]CH0_LPDDR4_0_cs_a;
  output [0:0]CH0_LPDDR4_0_cs_b;
  output [0:0]CH0_LPDDR4_0_ck_t_a;
  output [0:0]CH0_LPDDR4_0_ck_t_b;
  output [0:0]CH0_LPDDR4_0_ck_c_a;
  output [0:0]CH0_LPDDR4_0_ck_c_b;
  output [0:0]CH0_LPDDR4_0_cke_a;
  output [0:0]CH0_LPDDR4_0_cke_b;
  inout [1:0]CH0_LPDDR4_0_dmi_a;
  inout [1:0]CH0_LPDDR4_0_dmi_b;
  output [0:0]CH0_LPDDR4_0_reset_n;
  inout [15:0]CH1_LPDDR4_0_dq_a;
  inout [15:0]CH1_LPDDR4_0_dq_b;
  inout [1:0]CH1_LPDDR4_0_dqs_t_a;
  inout [1:0]CH1_LPDDR4_0_dqs_t_b;
  inout [1:0]CH1_LPDDR4_0_dqs_c_a;
  inout [1:0]CH1_LPDDR4_0_dqs_c_b;
  output [5:0]CH1_LPDDR4_0_ca_a;
  output [5:0]CH1_LPDDR4_0_ca_b;
  output [0:0]CH1_LPDDR4_0_cs_a;
  output [0:0]CH1_LPDDR4_0_cs_b;
  output [0:0]CH1_LPDDR4_0_ck_t_a;
  output [0:0]CH1_LPDDR4_0_ck_t_b;
  output [0:0]CH1_LPDDR4_0_ck_c_a;
  output [0:0]CH1_LPDDR4_0_ck_c_b;
  output [0:0]CH1_LPDDR4_0_cke_a;
  output [0:0]CH1_LPDDR4_0_cke_b;
  inout [1:0]CH1_LPDDR4_0_dmi_a;
  inout [1:0]CH1_LPDDR4_0_dmi_b;
  output [0:0]CH1_LPDDR4_0_reset_n;
  input [0:0]sys_clk1_clk_p;
  input [0:0]sys_clk1_clk_n;
  inout [15:0]CH0_LPDDR4_1_dq_a;
  inout [15:0]CH0_LPDDR4_1_dq_b;
  inout [1:0]CH0_LPDDR4_1_dqs_t_a;
  inout [1:0]CH0_LPDDR4_1_dqs_t_b;
  inout [1:0]CH0_LPDDR4_1_dqs_c_a;
  inout [1:0]CH0_LPDDR4_1_dqs_c_b;
  output [5:0]CH0_LPDDR4_1_ca_a;
  output [5:0]CH0_LPDDR4_1_ca_b;
  output [0:0]CH0_LPDDR4_1_cs_a;
  output [0:0]CH0_LPDDR4_1_cs_b;
  output [0:0]CH0_LPDDR4_1_ck_t_a;
  output [0:0]CH0_LPDDR4_1_ck_t_b;
  output [0:0]CH0_LPDDR4_1_ck_c_a;
  output [0:0]CH0_LPDDR4_1_ck_c_b;
  output [0:0]CH0_LPDDR4_1_cke_a;
  output [0:0]CH0_LPDDR4_1_cke_b;
  inout [1:0]CH0_LPDDR4_1_dmi_a;
  inout [1:0]CH0_LPDDR4_1_dmi_b;
  output [0:0]CH0_LPDDR4_1_reset_n;
  inout [15:0]CH1_LPDDR4_1_dq_a;
  inout [15:0]CH1_LPDDR4_1_dq_b;
  inout [1:0]CH1_LPDDR4_1_dqs_t_a;
  inout [1:0]CH1_LPDDR4_1_dqs_t_b;
  inout [1:0]CH1_LPDDR4_1_dqs_c_a;
  inout [1:0]CH1_LPDDR4_1_dqs_c_b;
  output [5:0]CH1_LPDDR4_1_ca_a;
  output [5:0]CH1_LPDDR4_1_ca_b;
  output [0:0]CH1_LPDDR4_1_cs_a;
  output [0:0]CH1_LPDDR4_1_cs_b;
  output [0:0]CH1_LPDDR4_1_ck_t_a;
  output [0:0]CH1_LPDDR4_1_ck_t_b;
  output [0:0]CH1_LPDDR4_1_ck_c_a;
  output [0:0]CH1_LPDDR4_1_ck_c_b;
  output [0:0]CH1_LPDDR4_1_cke_a;
  output [0:0]CH1_LPDDR4_1_cke_b;
  inout [1:0]CH1_LPDDR4_1_dmi_a;
  inout [1:0]CH1_LPDDR4_1_dmi_b;
  output [0:0]CH1_LPDDR4_1_reset_n;
endmodule
