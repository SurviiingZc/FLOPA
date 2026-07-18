SHELL := /bin/bash

SIM_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD_DIR ?= $(SIM_ROOT)/build
SCRIPTS_DIR := $(SIM_ROOT)/scripts
FILELIST_DIR := $(SIM_ROOT)/filelists
FILELISTS := $(FILELIST_DIR)/rtl.f $(FILELIST_DIR)/module_tb.f

TOP_COMMON := tb_fixed_defs_smoke
TOP_REGFILE := tb_accel_regfile
TOP_SCHEDULER := tb_accel_scheduler
TOP_PERF := tb_perf_counter
TOP_AXI_IF := tb_axi4_slave_if
TOP_AXI_WR := tb_axi4_master_write
TOP_PE := tb_os_fsa_pe
TOP_REDUCE := tb_row_reduce_unit
TOP_ACCEL := tb_attention_accel_top

COMMON_TOPS := tb_fixed_defs_smoke
CONTROL_TOPS := tb_accel_regfile tb_accel_scheduler tb_perf_counter
AXI_TOPS := tb_axi4_slave_if tb_axi4_master_write
COMPUTE_TOPS := tb_os_fsa_pe tb_os_fsa_array tb_os_fsa_controller \
	tb_scale_requant_unit tb_qk_engine tb_pv_engine
MEMORY_TOPS := tb_banked_sram tb_bram_buffer tb_output_buffer \
	tb_pingpong_buffer tb_qkv_tile_cache tb_stream_fifo tb_uram_bank
SOFTMAX_TOPS := tb_block_lse_update tb_causal_mask tb_online_normalizer \
	tb_pwl_exp_unit tb_reciprocal_lut tb_row_broadcast tb_row_reduce_unit \
	tb_softmax_engine
TOP_TOPS := tb_attention_accel_top
MODULE_TOPS := $(COMMON_TOPS) $(CONTROL_TOPS) $(AXI_TOPS) $(COMPUTE_TOPS) \
	$(MEMORY_TOPS) $(SOFTMAX_TOPS) $(TOP_TOPS)

.PHONY: help syntax run common control axi compute memory softmax top asic-sram lint-rtl \
        syntax-common run-common \
        syntax-regfile run-regfile \
        syntax-scheduler run-scheduler \
        syntax-perf run-perf \
        syntax-axi-if run-axi-if \
        syntax-axi-wr run-axi-wr \
        syntax-pe run-pe syntax-reduce run-reduce syntax-top run-top \
        clean

help:
	@echo "Targets:"
	@echo "  make syntax      - compile all module TBs with VCS"
	@echo "  make run         - run all module TBs with VCS"
	@echo "  make common      - run common smoke TB"
	@echo "  make control     - run control TBs"
	@echo "  make axi         - run AXI TBs"
	@echo "  make compute     - run all compute module TBs"
	@echo "  make memory      - run all generic memory module TBs"
	@echo "  make softmax     - run all softmax module TBs"
	@echo "  make top         - run one-tile end-to-end test"
	@echo "  make asic-sram   - run ASIC SRAM macro composition test"
	@echo "  make lint-rtl    - lint RTL as Verilog-2001"
	@echo "  make clean       - remove build output"

syntax:
	@set -e; for top in $(MODULE_TOPS); do \
		$(SCRIPTS_DIR)/syntax_vcs.sh $$top $(BUILD_DIR)/$$top $(FILELISTS); \
	done

run:
	@set -e; for top in $(MODULE_TOPS); do \
		$(SCRIPTS_DIR)/run_vcs.sh $$top $(BUILD_DIR)/$$top $(FILELISTS); \
	done

define run_tops
	@set -e; for top in $(1); do \
		$(SCRIPTS_DIR)/run_vcs.sh $$top $(BUILD_DIR)/$$top $(FILELISTS); \
	done
endef

common:
	$(call run_tops,$(COMMON_TOPS))
control:
	$(call run_tops,$(CONTROL_TOPS))
axi:
	$(call run_tops,$(AXI_TOPS))
compute:
	$(call run_tops,$(COMPUTE_TOPS))
memory:
	$(call run_tops,$(MEMORY_TOPS))
softmax:
	$(call run_tops,$(SOFTMAX_TOPS))
top:
	$(call run_tops,$(TOP_TOPS))

asic-sram:
	$(SCRIPTS_DIR)/run_asic_sram_vcs.sh

lint-rtl:
	$(SCRIPTS_DIR)/lint_rtl_vcs.sh

syntax-common:
	$(SCRIPTS_DIR)/syntax_vcs.sh $(TOP_COMMON) $(BUILD_DIR)/common $(FILELISTS)

run-common:
	$(SCRIPTS_DIR)/run_vcs.sh $(TOP_COMMON) $(BUILD_DIR)/common $(FILELISTS)

syntax-regfile:
	$(SCRIPTS_DIR)/syntax_vcs.sh $(TOP_REGFILE) $(BUILD_DIR)/regfile $(FILELISTS)

run-regfile:
	$(SCRIPTS_DIR)/run_vcs.sh $(TOP_REGFILE) $(BUILD_DIR)/regfile $(FILELISTS)

syntax-scheduler:
	$(SCRIPTS_DIR)/syntax_vcs.sh $(TOP_SCHEDULER) $(BUILD_DIR)/scheduler $(FILELISTS)

run-scheduler:
	$(SCRIPTS_DIR)/run_vcs.sh $(TOP_SCHEDULER) $(BUILD_DIR)/scheduler $(FILELISTS)

syntax-perf:
	$(SCRIPTS_DIR)/syntax_vcs.sh $(TOP_PERF) $(BUILD_DIR)/perf $(FILELISTS)

run-perf:
	$(SCRIPTS_DIR)/run_vcs.sh $(TOP_PERF) $(BUILD_DIR)/perf $(FILELISTS)

syntax-axi-if:
	$(SCRIPTS_DIR)/syntax_vcs.sh $(TOP_AXI_IF) $(BUILD_DIR)/axi_if $(FILELISTS)

run-axi-if:
	$(SCRIPTS_DIR)/run_vcs.sh $(TOP_AXI_IF) $(BUILD_DIR)/axi_if $(FILELISTS)

syntax-axi-wr:
	$(SCRIPTS_DIR)/syntax_vcs.sh $(TOP_AXI_WR) $(BUILD_DIR)/axi_wr $(FILELISTS)

run-axi-wr:
	$(SCRIPTS_DIR)/run_vcs.sh $(TOP_AXI_WR) $(BUILD_DIR)/axi_wr $(FILELISTS)

syntax-pe:
	$(SCRIPTS_DIR)/syntax_vcs.sh $(TOP_PE) $(BUILD_DIR)/pe $(FILELISTS)

run-pe:
	$(SCRIPTS_DIR)/run_vcs.sh $(TOP_PE) $(BUILD_DIR)/pe $(FILELISTS)

syntax-reduce:
	$(SCRIPTS_DIR)/syntax_vcs.sh $(TOP_REDUCE) $(BUILD_DIR)/reduce $(FILELISTS)

run-reduce:
	$(SCRIPTS_DIR)/run_vcs.sh $(TOP_REDUCE) $(BUILD_DIR)/reduce $(FILELISTS)

syntax-top:
	$(SCRIPTS_DIR)/syntax_vcs.sh $(TOP_ACCEL) $(BUILD_DIR)/top $(FILELISTS)

run-top:
	$(SCRIPTS_DIR)/run_vcs.sh $(TOP_ACCEL) $(BUILD_DIR)/top $(FILELISTS)

clean:
	rm -rf $(BUILD_DIR) $(SIM_ROOT)/csrc
	rm -f $(SIM_ROOT)/flex*.log $(SIM_ROOT)/ucli.key
