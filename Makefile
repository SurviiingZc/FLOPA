SHELL := /bin/bash

CORNER ?= tt
CLOCK_PERIOD ?= 1.6
SETUP_UNCERTAINTY ?= 0.100
HOLD_UNCERTAINTY ?= 0.020
CLOCK_TRANSITION ?= 0.050
INPUT_DELAY ?= 0.200
OUTPUT_DELAY ?= 0.200
INPUT_TRANSITION ?= 0.050
OUTPUT_LOAD ?= 0.020
MAX_TRANSITION ?= 0.300
MAX_FANOUT ?= 24
SRAM_INPUT_MIN_DELAY ?= 0.000
DC_CORES ?= 4
EXPECTED_TOP_SRAM_MACROS ?= 480
FREQ_SWEEP_PERIODS ?= 3.2 2.8 2.5 2.3 2.1 1.9
FANOUT_SWEEP_LIMITS ?= 16 24 32
POSTCTS_TOP ?= attention_accel_top
SAIF_SEED ?= 301
SAIF_PROFILE ?= fa_two_tile_pingpong_random_seed$(SAIF_SEED)
SAIF_SIM_CLOCK_PERIOD ?= 1.6
SAIF_POWER_CLOCK_PERIOD ?= $(SAIF_SIM_CLOCK_PERIOD)
SAIF_SIM_OUT_DIR ?= tb/sim/build/saif_$(SAIF_PROFILE)
SAIF_FILE ?=
SAIF_DDC_FILE ?=
SAIF_SYNTH_GROUP ?= system
# Single-test UVM runner. The output directory is relative to tb/sim because
# VCS is launched from that directory to resolve the RTL and UVM filelists.
UVM_TEST ?= fa_two_tile_pingpong_test
UVM_SEED ?= 301
UVM_SIM_CLOCK_PERIOD ?= 1.6
UVM_SIM_OUT_DIR ?= build/uvm_$(UVM_TEST)_seed$(UVM_SEED)

SYNTH_SCRIPT := asic/scripts/run_synth.sh
SAIF_SIM_SCRIPT := tb/sim/scripts/run_saif_random_qkv.sh
SAIF_POWER_SCRIPT := asic/scripts/run_saif_power.sh
SAIF_DDC_ARG = $(if $(strip $(SAIF_DDC_FILE)),DDC_FILE=$(SAIF_DDC_FILE),)

AXI_TOPS := axi4_slave_if axi4_master_write
CONTROL_TOPS := accel_regfile accel_scheduler perf_counter
COMPUTE_TOPS := fa_clear_replica fa_signed_mult_pipe2 fa_unsigned_mult_pipe2 \
	score_scale_pipe fsa_delay_line fsa_fused_pe fsa_stripe \
	fsa_fused_array fsa_controller fsa_qk_engine fsa_pv_engine
MEMORY_TOPS := asic_sram_1024x16 asic_sram_256xwide banked_sram \
	o_accumulator_bank output_buffer pingpong_buffer qkv_tile_cache
SOFTMAX_TOPS := pwl_exp_unit reciprocal_lut online_normalizer
SYSTEM_TOP := attention_accel_top

SYNTH_ENV = CORNER=$(CORNER) CLOCK_PERIOD=$(CLOCK_PERIOD) \
	FA_SETUP_UNCERTAINTY=$(SETUP_UNCERTAINTY) \
	FA_HOLD_UNCERTAINTY=$(HOLD_UNCERTAINTY) \
	FA_CLOCK_TRANSITION=$(CLOCK_TRANSITION) FA_INPUT_DELAY=$(INPUT_DELAY) \
	FA_OUTPUT_DELAY=$(OUTPUT_DELAY) FA_INPUT_TRANSITION=$(INPUT_TRANSITION) \
	FA_OUTPUT_LOAD=$(OUTPUT_LOAD) FA_MAX_TRANSITION=$(MAX_TRANSITION) \
	FA_MAX_FANOUT=$(MAX_FANOUT) DC_CORES=$(DC_CORES) \
	FA_SRAM_INPUT_MIN_DELAY=$(SRAM_INPUT_MIN_DELAY) \
	EXPECTED_TOP_SRAM_MACROS=$(EXPECTED_TOP_SRAM_MACROS)

.PHONY: help synth-config synth-list sram-lib rtl-check pe-timing \
	synth-module synth-axi synth-control synth-compute synth-memory \
	synth-softmax synth-modules synth-system synth-top synth-all \
	synth-system-tt synth-system-ss synth-all-tt synth-all-ss \
	synth-frequency-sweep synth-physical physical-config \
	synth-system-hold synth-fanout-sweep \
	synth-hold-ff hold-signoff uvm-test saif-random-qkv saif-two-tile-pingpong saif-two-tile-random saif-power \
	clean-synth clean-asic

.NOTPARALLEL: synth-modules synth-all synth-all-tt synth-all-ss

help:
	@echo "ASIC synthesis targets:"
	@echo "  make synth-module TOP=fsa_fused_pe [CORNER=tt|ss] [CLOCK_PERIOD=2.5]"
	@echo "  make synth-axi       - synthesize each AXI module independently"
	@echo "  make synth-control   - synthesize each control module independently"
	@echo "  make synth-compute   - synthesize each compute module independently"
	@echo "  make synth-memory    - synthesize ASIC-used memory modules independently"
	@echo "  make synth-softmax   - synthesize each softmax module independently"
	@echo "  make synth-modules   - synthesize every module group"
	@echo "  make synth-system    - synthesize the complete attention_accel_top"
	@echo "  make synth-all       - synthesize all module groups, then the system"
	@echo "  make synth-system-tt - complete system at TT 0.9 V, 25 C"
	@echo "  make synth-system-ss - complete system at SS 0.9 V, 125 C"
	@echo "  make synth-frequency-sweep [CORNER=tt] - sweep periods and emit Fmax CSV"
	@echo "  make synth-system-hold - separate post-compile logical hold-repair trial"
	@echo "  make synth-hold-ff FA_MW_LIB=... FA_TLUPLUS_MIN=... - FF/min-RC pre-CTS hold repair"
	@echo "  make hold-signoff POSTCTS_NETLIST=... POSTCTS_SDC=... POSTCTS_SPEF=... - post-CTS PT hold signoff"
	@echo "  make synth-fanout-sweep - compare max-fanout limits 16/24/32"
	@echo "  make synth-physical FA_MW_LIB=/path/to/mw - DC Graphical SPG synthesis"
	@echo "  make physical-config - print public physical collateral paths"
	@echo "  make sram-lib        - compile the SRAM Liberty file for CORNER"
	@echo "  make rtl-check       - analyze/elaborate/link ASIC RTL without compile_ultra"
	@echo "  make pe-timing       - focused shared PE MAC timing synthesis"
	@echo "  make uvm-test [UVM_TEST=fa_two_tile_pingpong_test] [UVM_SEED=301] - compile and run one UVM test"
	@echo "  make saif-two-tile-pingpong [SAIF_SEED=301] [SAIF_SIM_CLOCK_PERIOD=1.6] - simulate random-Q/K/V fa_two_tile_pingpong_test without AXI write backpressure"
	@echo "  make saif-two-tile-random / saif-random-qkv - compatibility aliases for saif-two-tile-pingpong"
	@echo "  make saif-power SAIF_FILE=/abs/profile.saif [SAIF_POWER_CLOCK_PERIOD=1.6] - back-annotate SAIF to matching mapped DDC"
	@echo "  make synth-config    - print active libraries/constraint variables"
	@echo "  make synth-list      - print module groups"

synth-config:
	@echo "CORNER=$(CORNER)"
	@echo "CLOCK_PERIOD=$(CLOCK_PERIOD) ns"
	@echo "SETUP_UNCERTAINTY=$(SETUP_UNCERTAINTY) ns"
	@echo "HOLD_UNCERTAINTY=$(HOLD_UNCERTAINTY) ns"
	@echo "CLOCK_TRANSITION=$(CLOCK_TRANSITION) ns"
	@echo "INPUT_DELAY=$(INPUT_DELAY) ns"
	@echo "OUTPUT_DELAY=$(OUTPUT_DELAY) ns"
	@echo "INPUT_TRANSITION=$(INPUT_TRANSITION) ns"
	@echo "OUTPUT_LOAD=$(OUTPUT_LOAD)"
	@echo "MAX_TRANSITION=$(MAX_TRANSITION) ns"
	@echo "MAX_FANOUT=$(MAX_FANOUT)"
	@echo "SRAM_INPUT_MIN_DELAY=$(SRAM_INPUT_MIN_DELAY) ns"
	@echo "DC_CORES=$(DC_CORES)"
	@echo "EXPECTED_TOP_SRAM_MACROS=$(EXPECTED_TOP_SRAM_MACROS)"

synth-list:
	@echo "AXI:     $(AXI_TOPS)"
	@echo "CONTROL: $(CONTROL_TOPS)"
	@echo "COMPUTE: $(COMPUTE_TOPS)"
	@echo "MEMORY:  $(MEMORY_TOPS)"
	@echo "SOFTMAX: $(SOFTMAX_TOPS)"
	@echo "SYSTEM:  $(SYSTEM_TOP)"

sram-lib:
	asic/scripts/prepare_sram_lib.sh $(CORNER)

rtl-check:
	$(SYNTH_ENV) asic/scripts/run_rtl_check.sh $(CORNER)

pe-timing:
	$(SYNTH_ENV) asic/scripts/run_pe_timing.sh $(CORNER)

synth-module:
	@test -n "$(TOP)" || { echo "TOP is required" >&2; exit 2; }
	$(SYNTH_ENV) $(SYNTH_SCRIPT) module_$(TOP) $(TOP)

synth-axi:
	$(SYNTH_ENV) $(SYNTH_SCRIPT) axi $(AXI_TOPS)

synth-control:
	$(SYNTH_ENV) $(SYNTH_SCRIPT) control $(CONTROL_TOPS)

synth-compute:
	$(SYNTH_ENV) $(SYNTH_SCRIPT) compute $(COMPUTE_TOPS)

synth-memory:
	$(SYNTH_ENV) $(SYNTH_SCRIPT) memory $(MEMORY_TOPS)

synth-softmax:
	$(SYNTH_ENV) $(SYNTH_SCRIPT) softmax $(SOFTMAX_TOPS)

synth-modules: synth-axi synth-control synth-compute synth-memory synth-softmax

synth-system:
	$(SYNTH_ENV) $(SYNTH_SCRIPT) system $(SYSTEM_TOP)

synth-top: synth-system

synth-all: synth-modules synth-system

synth-system-tt:
	$(MAKE) synth-system CORNER=tt

synth-system-ss:
	$(MAKE) synth-system CORNER=ss

synth-all-tt:
	$(MAKE) synth-all CORNER=tt

synth-all-ss:
	$(MAKE) synth-all CORNER=ss

synth-frequency-sweep:
	$(SYNTH_ENV) FREQ_SWEEP_PERIODS="$(FREQ_SWEEP_PERIODS)" \
		asic/scripts/run_frequency_sweep.sh

synth-system-hold:
	$(SYNTH_ENV) FA_LOGICAL_HOLD_REPAIR=1 \
		$(SYNTH_SCRIPT) system_hold $(SYSTEM_TOP)

synth-fanout-sweep:
	$(SYNTH_ENV) FANOUT_SWEEP_LIMITS="$(FANOUT_SWEEP_LIMITS)" \
		asic/scripts/run_fanout_sweep.sh

# Pre-CTS physical-aware hold repair. The min-RC table is deliberately used
# for both RC slots because this run is a dedicated early-path stress case.
synth-hold-ff:
	FA_MW_LIB="$(FA_MW_LIB)" FA_TLUPLUS_MIN="$(FA_TLUPLUS_MIN)" \
		CLOCK_PERIOD="$(CLOCK_PERIOD)" DC_CORES="$(DC_CORES)" \
		asic/scripts/run_prects_hold.sh

# Final hold authority: routed netlist + routed parasitics + propagated CTS.
hold-signoff:
	POSTCTS_TOP="$(POSTCTS_TOP)" POSTCTS_NETLIST="$(POSTCTS_NETLIST)" \
		POSTCTS_SDC="$(POSTCTS_SDC)" POSTCTS_SPEF="$(POSTCTS_SPEF)" \
		asic/scripts/run_postcts_hold.sh

synth-physical:
	$(SYNTH_ENV) asic/scripts/run_synth_physical.sh

physical-config:
	@source asic/scripts/physical_library_paths.sh; \
	echo "STD_MW_REF=$$FA_STD_MW_REF_DEFAULT"; \
	echo "STD_LEF=$$FA_STD_LEF_DEFAULT"; \
	echo "SRAM_LEF=$$FA_SRAM_LEF_DEFAULT"; \
	echo "SRAM_GDS=$$FA_SRAM_GDS_DEFAULT"; \
	echo "RC_ROOT=$$FA_RC_ROOT_DEFAULT"

# Compile one fresh UVM simulator and run the requested factory test. VCS may
# return success even when UVM reports an error, so the report summary is the
# authoritative pass/fail check. Override UVM_SIM_OUT_DIR for an isolated run.
uvm-test:
	@case "$(UVM_TEST)" in ''|*[!A-Za-z0-9_]*) echo "UVM_TEST must contain only letters, digits, and underscores" >&2; exit 2;; esac
	@case "$(UVM_SEED)" in ''|*[!0-9]*) echo "UVM_SEED must be a non-negative integer" >&2; exit 2;; esac
	@mkdir -p tb/sim/$(UVM_SIM_OUT_DIR)/csrc
	cd tb/sim && vcs -full64 -sverilog -ntb_opts uvm -timescale=1ns/1ps \
		-debug_access+all -kdb -lca -Mdir="$(UVM_SIM_OUT_DIR)/csrc" \
		-f filelists/rtl.f -f filelists/uvm.f -top tb_top \
		-l "$(UVM_SIM_OUT_DIR)/compile.log" -o "$(UVM_SIM_OUT_DIR)/simv"
	cd tb/sim && "$(UVM_SIM_OUT_DIR)/simv" +UVM_TESTNAME="$(UVM_TEST)" \
		+ntb_random_seed="$(UVM_SEED)" +CLK_PERIOD_NS="$(UVM_SIM_CLOCK_PERIOD)" \
		-l "$(UVM_SIM_OUT_DIR)/$(UVM_TEST).log"
	@grep -Eq 'UVM_ERROR :[[:space:]]*0' tb/sim/$(UVM_SIM_OUT_DIR)/$(UVM_TEST).log && \
		grep -Eq 'UVM_FATAL :[[:space:]]*0' tb/sim/$(UVM_SIM_OUT_DIR)/$(UVM_TEST).log || \
		{ echo "UVM test failed; see tb/sim/$(UVM_SIM_OUT_DIR)/$(UVM_TEST).log" >&2; exit 1; }
	@echo "PASS $(UVM_TEST) seed=$(UVM_SEED); log: tb/sim/$(UVM_SIM_OUT_DIR)/$(UVM_TEST).log"

# The capture script publishes only when the UVM test has zero errors/fatals.
# Its 1.6 ns default must match saif-power to preserve time-based toggle rates.
saif-random-qkv saif-two-tile-pingpong saif-two-tile-random:
	SEED=$(SAIF_SEED) PROFILE=$(SAIF_PROFILE) \
	SIM_CLOCK_PERIOD_NS=$(SAIF_SIM_CLOCK_PERIOD) OUT_DIR=$(SAIF_SIM_OUT_DIR) \
	$(SAIF_SIM_SCRIPT)

saif-power:
	@test -n "$(SAIF_FILE)" || { echo "SAIF_FILE=/absolute/path/to/profile.saif is required" >&2; exit 2; }
	SAIF_FILE=$(SAIF_FILE) PROFILE=$(SAIF_PROFILE) CORNER=$(CORNER) \
	CLOCK_PERIOD=$(SAIF_POWER_CLOCK_PERIOD) SYNTH_GROUP=$(SAIF_SYNTH_GROUP) \
	$(SAIF_DDC_ARG) $(SAIF_POWER_SCRIPT)

clean-synth:
	rm -rf asic/dc/work/synth
	rm -rf asic/dc/work/frequency_sweep
	rm -f asic/dc/logs/synth_*.log

clean-asic: clean-synth
	rm -rf asic/dc/work/rtl_check asic/dc/work/pe_timing
	rm -f asic/dc/logs/rtl_check_*.log asic/dc/logs/pe_timing_*.log
