SHELL := /bin/bash

SIM_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD_DIR ?= $(SIM_ROOT)/build
SCRIPTS_DIR := $(SIM_ROOT)/scripts
FILELISTS := $(SIM_ROOT)/filelists/rtl.f $(SIM_ROOT)/filelists/module_tb.f

COMMON_TOPS := tb_fixed_defs_smoke tb_fa_clear_replica
CONTROL_TOPS := tb_accel_regfile tb_accel_scheduler tb_perf_counter
AXI_TOPS := tb_axi4_slave_if tb_axi4_master_write
COMPUTE_TOPS := tb_fsa_fused_array tb_fa_signed_mult_pipe2 tb_fa_unsigned_mult_pipe2 \
	tb_fsa_fused_pe tb_fsa_stripe tb_fsa_controller tb_score_scale_pipe tb_fsa_pv_engine
MEMORY_TOPS := tb_banked_sram tb_output_buffer tb_o_accumulator_bank \
	tb_pingpong_buffer tb_qkv_tile_cache
SOFTMAX_TOPS := tb_online_normalizer tb_pwl_exp_unit tb_reciprocal_lut
TOP_TOPS := tb_attention_accel_top
MODULE_TOPS := $(COMMON_TOPS) $(CONTROL_TOPS) $(AXI_TOPS) $(COMPUTE_TOPS) \
	$(MEMORY_TOPS) $(SOFTMAX_TOPS) $(TOP_TOPS)

.PHONY: help syntax run module-cov common control axi compute memory softmax top asic-sram lint-rtl clean

help:
	@echo "Targets:"
	@echo "  make syntax    - compile all module testbenches"
	@echo "  make run       - run all module testbenches"
	@echo "  make module-cov - collect independent RTL code-coverage reports from module TBs"
	@echo "  make common|control|axi|compute|memory|softmax|top - run one TB group"
	@echo "  make asic-sram - run ASIC SRAM integration test"
	@echo "  make lint-rtl  - lint synthesizable RTL"
	@echo "  make clean     - remove simulation build output"

syntax:
	@set -e; for top in $(MODULE_TOPS); do \
		$(SCRIPTS_DIR)/syntax_vcs.sh $$top $(BUILD_DIR)/$$top $(FILELISTS); \
	done

run:
	@set -e; for top in $(MODULE_TOPS); do \
		$(SCRIPTS_DIR)/run_vcs.sh $$top $(BUILD_DIR)/$$top $(FILELISTS); \
	done

# Optional TOPS limits the module TB set, e.g.
# make module-cov TOPS="tb_axi4_master_write tb_accel_regfile". Each report is
# kept separate because reduced-parameter module TBs cannot be blindly merged
# into the full integration hierarchy.
module-cov:
	@bash $(SCRIPTS_DIR)/run_module_coverage.sh $(TOPS)

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

clean:
	rm -rf $(BUILD_DIR) $(SIM_ROOT)/csrc
	rm -f $(SIM_ROOT)/flex*.log $(SIM_ROOT)/ucli.key
