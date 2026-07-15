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

.PHONY: help syntax run common control axi \
        syntax-common run-common \
        syntax-regfile run-regfile \
        syntax-scheduler run-scheduler \
        syntax-perf run-perf \
        syntax-axi-if run-axi-if \
        syntax-axi-wr run-axi-wr \
        clean

help:
	@echo "Targets:"
	@echo "  make syntax      - compile all module TBs with VCS"
	@echo "  make run         - run all module TBs with VCS"
	@echo "  make common      - run common smoke TB"
	@echo "  make control     - run control TBs"
	@echo "  make axi         - run AXI TBs"
	@echo "  make clean       - remove build output"

syntax: syntax-common syntax-regfile syntax-scheduler syntax-perf syntax-axi-if syntax-axi-wr
run: run-common run-regfile run-scheduler run-perf run-axi-if run-axi-wr

common: run-common
control: run-regfile run-scheduler run-perf
axi: run-axi-if run-axi-wr

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

clean:
	rm -rf $(BUILD_DIR)
