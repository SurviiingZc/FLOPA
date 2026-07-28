proc configure_noc_slave {pin category connections} {
    set_property -dict [list \
        CONFIG.DATA_WIDTH 128 \
        CONFIG.REGION 0 \
        CONFIG.CONNECTIONS $connections \
        CONFIG.DEST_IDS {M00_AXI:0x80} \
        CONFIG.CATEGORY $category \
    ] $pin
}

proc map_address {space segment offset range} {
    assign_bd_address -offset $offset -range $range \
        -target_address_space $space $segment -force
}

proc create_system_bd {pl_freq_mhz} {
    create_bd_design system

    set ddr4 [create_bd_intf_port -mode Master \
        -vlnv xilinx.com:interface:ddr4_rtl:1.0 ddr4_dimm1]
    set ddr_clk [create_bd_intf_port -mode Slave \
        -vlnv xilinx.com:interface:diff_clock_rtl:1.0 ddr4_dimm1_sma_clk]
    set_property CONFIG.FREQ_HZ 200000000 $ddr_clk

    set attention [create_bd_cell -type module \
        -reference attention_fpga_top attention_0]

    set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma axi_dma_0]
    set_property -dict [list \
        CONFIG.c_include_sg 0 \
        CONFIG.c_sg_include_stscntrl_strm 0 \
        CONFIG.c_include_mm2s 1 \
        CONFIG.c_include_s2mm 0 \
        CONFIG.c_include_mm2s_dre 1 \
        CONFIG.c_m_axi_mm2s_data_width 128 \
        CONFIG.c_m_axis_mm2s_tdata_width 128 \
        CONFIG.c_mm2s_burst_size 16 \
    ] $dma

    set control_smc [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:smartconnect control_smc]
    set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 3] $control_smc

    set noc [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_noc axi_noc_0]
    set_property -dict [list \
        CONFIG.CH0_DDR4_0_BOARD_INTERFACE ddr4_dimm1 \
        CONFIG.CONTROLLERTYPE DDR4_SDRAM \
        CONFIG.MC_COMPONENT_WIDTH x8 \
        CONFIG.MC_DATAWIDTH 64 \
        CONFIG.MC_INPUTCLK0_PERIOD 5000 \
        CONFIG.MC_INTERLEAVE_SIZE 128 \
        CONFIG.MC_MEMORY_DEVICETYPE UDIMMs \
        CONFIG.MC_MEMORY_SPEEDGRADE {DDR4-3200AA(22-22-22)} \
        CONFIG.MC_NO_CHANNELS Single \
        CONFIG.MC_RANK 1 \
        CONFIG.MC_ROWADDRESSWIDTH 16 \
        CONFIG.MC_STACKHEIGHT 1 \
        CONFIG.MC_SYSTEM_CLOCK Differential \
        CONFIG.NUM_CLKS 8 \
        CONFIG.NUM_MC 1 \
        CONFIG.NUM_MI 1 \
        CONFIG.NUM_SI 8 \
        CONFIG.sys_clk0_BOARD_INTERFACE ddr4_dimm1_sma_clk \
    ] $noc

    set_property -dict [list \
        CONFIG.DATA_WIDTH 32 \
        CONFIG.APERTURES {{0x201_0000_0000 1G}} \
        CONFIG.CATEGORY pl \
    ] [get_bd_intf_pins $noc/M00_AXI]

    set ps_connections {
        MC_0 {
            read_bw {5} write_bw {5}
            read_avg_burst {4} write_avg_burst {4}
        }
        M00_AXI {
            read_bw {5} write_bw {5}
            read_avg_burst {4} write_avg_burst {4}
        }
    }
    set pl_connections {
        MC_0 {
            read_bw {5} write_bw {5}
            read_avg_burst {4} write_avg_burst {4}
        }
    }

    configure_noc_slave [get_bd_intf_pins $noc/S00_AXI] ps_pmc $ps_connections
    configure_noc_slave [get_bd_intf_pins $noc/S01_AXI] ps_rpu $ps_connections
    foreach index {2 3 4 5} {
        set pin [get_bd_intf_pins $noc/S0${index}_AXI]
        configure_noc_slave $pin ps_cci $ps_connections
    }
    configure_noc_slave [get_bd_intf_pins $noc/S06_AXI] pl $pl_connections
    configure_noc_slave [get_bd_intf_pins $noc/S07_AXI] pl $pl_connections

    set_property CONFIG.ASSOCIATED_BUSIF S00_AXI [get_bd_pins $noc/aclk0]
    set_property CONFIG.ASSOCIATED_BUSIF S01_AXI [get_bd_pins $noc/aclk1]
    foreach index {2 3 4 5} {
        set_property CONFIG.ASSOCIATED_BUSIF S0${index}_AXI \
            [get_bd_pins $noc/aclk${index}]
    }
    set_property CONFIG.ASSOCIATED_BUSIF {M00_AXI:S06_AXI:S07_AXI} \
        [get_bd_pins $noc/aclk6]
    set_property CONFIG.ASSOCIATED_BUSIF {} [get_bd_pins $noc/aclk7]

    set reset [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:proc_sys_reset pl_reset]
    set clock_wizard [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:clk_wizard pl_clock_wizard]
    set output_frequency_list [list \
        $pl_freq_mhz 100.000 100.000 100.000 100.000 100.000 100.000]
    set output_frequencies [join $output_frequency_list ,]
    set_property -dict [list \
        CONFIG.PRIM_IN_FREQ 299.997009 \
        CONFIG.PRIM_SOURCE No_buffer \
        CONFIG.CLKOUT_REQUESTED_OUT_FREQUENCY $output_frequencies \
        CONFIG.USE_LOCKED true \
    ] $clock_wizard
    set generated_pl_freq_hz [get_property CONFIG.FREQ_HZ \
        [get_bd_pins $clock_wizard/clk_out1]]
    set_property CONFIG.FREQ_HZ $generated_pl_freq_hz \
        [get_bd_pins $attention/aclk]
    set cips [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:versal_cips versal_cips_0]

    set irq_usage [list]
    for {set index 0} {$index < 16} {incr index} {
        lappend irq_usage [list CH${index} [expr {$index == 0 ? 1 : 0}]]
    }
    set cips_cfg [dict create \
        CLOCK_MODE Custom \
        DDR_MEMORY_MODE Custom \
        PMC_CRP_PL0_REF_CTRL_FREQMHZ 300 \
        PMC_GPIO0_MIO_PERIPHERAL {{ENABLE 1}} \
        PMC_GPIO1_MIO_PERIPHERAL {{ENABLE 1}} \
        PMC_I2CPMC_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 46 .. 47}}} \
        PMC_QSPI_FBCLK {{ENABLE 1}} \
        PMC_QSPI_PERIPHERAL_DATA_MODE x4 \
        PMC_QSPI_PERIPHERAL_ENABLE 1 \
        PMC_QSPI_PERIPHERAL_MODE {{Dual Parallel}} \
        PMC_SD1 {{CD_ENABLE 1} {POW_ENABLE 0} {WP_ENABLE 0}} \
        PMC_SD1_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 26 .. 36}}} \
        PMC_SD1_SLOT_TYPE {{SD 3.0}} \
        PMC_USE_PMC_NOC_AXI0 1 \
        PS_ENET0_MDIO {{ENABLE 1} {IO {PS_MIO 24 .. 25}}} \
        PS_ENET0_PERIPHERAL {{ENABLE 1} {IO {PS_MIO 0 .. 11}}} \
        PS_ENET1_PERIPHERAL {{ENABLE 1} {IO {PS_MIO 12 .. 23}}} \
        PS_GEN_IPI0_ENABLE 1 \
        PS_GEN_IPI0_MASTER A72 \
        PS_GEN_IPI1_ENABLE 1 \
        PS_GEN_IPI1_MASTER A72 \
        PS_GEN_IPI2_ENABLE 1 \
        PS_GEN_IPI2_MASTER A72 \
        PS_GEN_IPI3_ENABLE 1 \
        PS_GEN_IPI3_MASTER A72 \
        PS_GEN_IPI4_ENABLE 1 \
        PS_GEN_IPI4_MASTER A72 \
        PS_GEN_IPI5_ENABLE 1 \
        PS_GEN_IPI5_MASTER A72 \
        PS_GEN_IPI6_ENABLE 1 \
        PS_GEN_IPI6_MASTER A72 \
        PS_I2C1_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 44 .. 45}}} \
        PS_IRQ_USAGE $irq_usage \
        PS_NUM_FABRIC_RESETS 1 \
        PS_PL_CONNECTIVITY_MODE Custom \
        PS_TTC0_PERIPHERAL_ENABLE 1 \
        PS_UART0_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 42 .. 43}}} \
        PS_USB3_PERIPHERAL {{ENABLE 1}} \
        PS_USE_FPD_CCI_NOC 1 \
        PS_USE_M_AXI_FPD 0 \
        PS_USE_M_AXI_LPD 0 \
        PS_USE_NOC_LPD_AXI0 1 \
        PS_USE_PMCPL_CLK0 1 \
        PS_USE_S_AXI_FPD 0 \
        PS_USE_S_AXI_GP2 0 \
        PS_USE_S_AXI_LPD 0]
    set_property -dict [list \
        CONFIG.CLOCK_MODE Custom \
        CONFIG.DDR_MEMORY_MODE Custom \
        CONFIG.PS_PL_CONNECTIVITY_MODE Custom \
        CONFIG.PS_PMC_CONFIG $cips_cfg \
    ] $cips

    connect_bd_intf_net [get_bd_intf_ports ddr4_dimm1] \
        [get_bd_intf_pins $noc/CH0_DDR4_0]
    connect_bd_intf_net [get_bd_intf_ports ddr4_dimm1_sma_clk] \
        [get_bd_intf_pins $noc/sys_clk0]
    connect_bd_intf_net [get_bd_intf_pins $cips/PMC_NOC_AXI_0] \
        [get_bd_intf_pins $noc/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins $cips/LPD_AXI_NOC_0] \
        [get_bd_intf_pins $noc/S01_AXI]
    for {set index 0} {$index < 4} {incr index} {
        set cips_pin [get_bd_intf_pins $cips/FPD_CCI_NOC_$index]
        set noc_pin [get_bd_intf_pins $noc/S0[expr {$index + 2}]_AXI]
        connect_bd_intf_net $cips_pin $noc_pin
    }
    connect_bd_intf_net [get_bd_intf_pins $dma/M_AXI_MM2S] \
        [get_bd_intf_pins $noc/S06_AXI]
    connect_bd_intf_net [get_bd_intf_pins $attention/M_AXI_OUTPUT] \
        [get_bd_intf_pins $noc/S07_AXI]
    connect_bd_intf_net [get_bd_intf_pins $noc/M00_AXI] \
        [get_bd_intf_pins $control_smc/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins $control_smc/M00_AXI] \
        [get_bd_intf_pins $dma/S_AXI_LITE]
    connect_bd_intf_net [get_bd_intf_pins $control_smc/M01_AXI] \
        [get_bd_intf_pins $attention/S_AXI_CONTROL]
    connect_bd_intf_net [get_bd_intf_pins $control_smc/M02_AXI] \
        [get_bd_intf_pins $attention/S_AXI_LOADER]
    connect_bd_intf_net [get_bd_intf_pins $dma/M_AXIS_MM2S] \
        [get_bd_intf_pins $attention/S_AXIS_TILE]

    connect_bd_net [get_bd_pins $cips/pmc_axi_noc_axi0_clk] \
        [get_bd_pins $noc/aclk0]
    connect_bd_net [get_bd_pins $cips/lpd_axi_noc_clk] \
        [get_bd_pins $noc/aclk1]
    for {set index 0} {$index < 4} {incr index} {
        set cips_clk [get_bd_pins $cips/fpd_cci_noc_axi${index}_clk]
        set noc_clk [get_bd_pins $noc/aclk[expr {$index + 2}]]
        connect_bd_net $cips_clk $noc_clk
    }

    connect_bd_net [get_bd_pins $cips/pl0_ref_clk] \
        [get_bd_pins $clock_wizard/clk_in1]
    set pl_clk [get_bd_pins $clock_wizard/clk_out1]
    connect_bd_net $pl_clk [get_bd_pins $attention/aclk]
    connect_bd_net $pl_clk [get_bd_pins $dma/m_axi_mm2s_aclk]
    connect_bd_net $pl_clk [get_bd_pins $dma/s_axi_lite_aclk]
    connect_bd_net $pl_clk [get_bd_pins $control_smc/aclk]
    connect_bd_net $pl_clk [get_bd_pins $noc/aclk6]
    connect_bd_net $pl_clk [get_bd_pins $noc/aclk7]
    connect_bd_net $pl_clk [get_bd_pins $reset/slowest_sync_clk]
    connect_bd_net [get_bd_pins $cips/pl0_resetn] [get_bd_pins $reset/ext_reset_in]
    connect_bd_net [get_bd_pins $clock_wizard/locked] \
        [get_bd_pins $reset/dcm_locked]

    set pl_resetn [get_bd_pins $reset/peripheral_aresetn]
    connect_bd_net $pl_resetn [get_bd_pins $attention/aresetn]
    connect_bd_net $pl_resetn [get_bd_pins $dma/axi_resetn]
    connect_bd_net $pl_resetn [get_bd_pins $control_smc/aresetn]

    set concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat irq_concat]
    set_property CONFIG.NUM_PORTS 16 $concat
    set zero [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant irq_zero]
    set_property -dict [list CONFIG.CONST_WIDTH 1 CONFIG.CONST_VAL 0] $zero
    connect_bd_net [get_bd_pins $dma/mm2s_introut] [get_bd_pins $concat/In0]
    connect_bd_net [get_bd_pins $attention/attention_irq_o] \
        [get_bd_pins $concat/In1]
    connect_bd_net [get_bd_pins $attention/loader_irq_o] \
        [get_bd_pins $concat/In2]
    for {set index 3} {$index < 16} {incr index} {
        connect_bd_net [get_bd_pins $zero/dout] [get_bd_pins $concat/In${index}]
    }
    connect_bd_net [get_bd_pins $concat/dout] [get_bd_pins $cips/pl_ps_irq0]

    validate_bd_design

    map_address [get_bd_addr_spaces $attention/M_AXI_OUTPUT] \
        [get_bd_addr_segs $noc/S07_AXI/C0_DDR_LOW0] 0x00000000 2G
    map_address [get_bd_addr_spaces $dma/Data_MM2S] \
        [get_bd_addr_segs $noc/S06_AXI/C0_DDR_LOW0] 0x00000000 2G

    set cips_space_names {
        FPD_CCI_NOC_0 FPD_CCI_NOC_1 FPD_CCI_NOC_2 FPD_CCI_NOC_3
        LPD_AXI_NOC_0 PMC_NOC_AXI_0
    }
    set noc_ddr_segments {
        S02_AXI S03_AXI S04_AXI S05_AXI S01_AXI S00_AXI
    }
    foreach space_name $cips_space_names noc_name $noc_ddr_segments {
        set space [get_bd_addr_spaces $cips/$space_name]
        set ddr_segment [get_bd_addr_segs $noc/${noc_name}/C0_DDR_LOW0]
        map_address $space $ddr_segment 0x00000000 2G
        map_address $space [get_bd_addr_segs $dma/S_AXI_LITE/Reg] \
            0x020100000000 64K
        map_address $space [get_bd_addr_segs $attention/S_AXI_CONTROL/reg0] \
            0x020100010000 64K
        map_address $space [get_bd_addr_segs $attention/S_AXI_LOADER/reg0] \
            0x020100020000 64K
    }

    validate_bd_design
    save_bd_design
}
