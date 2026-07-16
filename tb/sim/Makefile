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

.PHONY: help syntax run common control axi compute softmax top asic-sram lint-rtl \
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
	@echo "  make compute     - run PE tests"
	@echo "  make softmax     - run softmax reduction tests"
	@echo "  make top         - run one-tile end-to-end test"
	@echo "  make asic-sram   - run ASIC SRAM macro composition test"
	@echo "  make lint-rtl    - lint RTL as Verilog-2001"
	@echo "  make clean       - remove build output"

syntax: syntax-common syntax-regfile syntax-scheduler syntax-perf syntax-axi-if syntax-axi-wr syntax-pe syntax-reduce syntax-top
run: run-common run-regfile run-scheduler run-perf run-axi-if run-axi-wr run-pe run-reduce run-top

common: run-common
control: run-regfile run-scheduler run-perf
axi: run-axi-if run-axi-wr
compute: run-pe
softmax: run-reduce
top: run-top

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
