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
CLOCK_GATING ?= 1
CLOCK_GATING_MIN_BITWIDTH ?= 8
CLOCK_GATING_MAX_FANOUT ?= 256
SRAM_INPUT_MIN_DELAY ?= 0.000
DC_CORES ?= 4
EXPECTED_TOP_SRAM_MACROS ?= 480

SYSTEM_TOP := attention_accel_top
# The default synthesis result is clock-gated and is consumed directly by the
# gate-level SAIF flow. Set SYNTH_GROUP only when intentionally comparing a
# separate synthesis implementation.
SYNTH_GROUP ?= system_clock_gated
SYNTH_RESULT_DIR = asic/dc/work/synth/$(CORNER)/$(SYNTH_GROUP)/$(SYSTEM_TOP)/results

GATE_SAIF_SEED ?= 301
GATE_SEQ_Q ?= 512
GATE_SEQ_KV ?= 512
GATE_READY_LOW_PCT ?= 0
GATE_SAIF_PROFILE ?= gate_clock_gated_random_qkv_$(GATE_SEQ_Q)x$(GATE_SEQ_KV)_seed$(GATE_SAIF_SEED)
GATE_SIM_CLOCK_PERIOD ?= 1.6
GATE_SIM_OUT_DIR ?= tb/sim/build/saif_$(GATE_SAIF_PROFILE)
GATE_NETLIST ?= $(SYNTH_RESULT_DIR)/$(SYSTEM_TOP)_mapped.v
GATE_SDF ?= $(SYNTH_RESULT_DIR)/$(SYSTEM_TOP).sdf
GATE_DDC ?= $(SYNTH_RESULT_DIR)/$(SYSTEM_TOP).ddc
GATE_STD_CELL_V ?= /data/public/STD/tcbn28hpcplusbwp12t30p140_190a/tcbn28hpcplusbwp12t30p140_170a_vlg/TSMCHOME/digital/Front_End/verilog/tcbn28hpcplusbwp12t30p140_170a/tcbn28hpcplusbwp12t30p140.v
GATE_SRAM_V ?= /data/public/SRAM/uhdsp_256x8m4s/VERILOG/uhdsp_256x8m4s_tt0p9v25c.v

UVM_TEST ?= fa_random_qkv_test
UVM_SEED ?= 301
UVM_SIM_CLOCK_PERIOD ?= 1.6
UVM_SEQ_Q ?= 512
UVM_SEQ_KV ?= 512
UVM_READY_LOW_PCT ?= 0
UVM_CAUSAL_EN ?= 0
UVM_DECODE_EN ?= 0
UVM_PLUSARGS ?=
UVM_SIM_OUT_DIR ?= build/uvm_$(UVM_TEST)_seed$(UVM_SEED)

SYNTH_SCRIPT := asic/scripts/run_synth.sh
GATE_SAIF_SCRIPT := tb/sim/scripts/run_gate_saif.sh

SYNTH_ENV = CORNER=$(CORNER) CLOCK_PERIOD=$(CLOCK_PERIOD) \
	FA_SETUP_UNCERTAINTY=$(SETUP_UNCERTAINTY) \
	FA_HOLD_UNCERTAINTY=$(HOLD_UNCERTAINTY) \
	FA_CLOCK_TRANSITION=$(CLOCK_TRANSITION) FA_INPUT_DELAY=$(INPUT_DELAY) \
	FA_OUTPUT_DELAY=$(OUTPUT_DELAY) FA_INPUT_TRANSITION=$(INPUT_TRANSITION) \
	FA_OUTPUT_LOAD=$(OUTPUT_LOAD) FA_MAX_TRANSITION=$(MAX_TRANSITION) \
	FA_MAX_FANOUT=$(MAX_FANOUT) DC_CORES=$(DC_CORES) \
	FA_CLOCK_GATING=$(CLOCK_GATING) \
	FA_CLOCK_GATING_MIN_BITWIDTH=$(CLOCK_GATING_MIN_BITWIDTH) \
	FA_CLOCK_GATING_MAX_FANOUT=$(CLOCK_GATING_MAX_FANOUT) \
	FA_SRAM_INPUT_MIN_DELAY=$(SRAM_INPUT_MIN_DELAY) \
	EXPECTED_TOP_SRAM_MACROS=$(EXPECTED_TOP_SRAM_MACROS)

.PHONY: help synth synth-system synth-config uvm-test gate-saif gate-saif-power clean-synth

help:
	@echo "Targets:"
	@echo "  make synth [CORNER=tt] [CLOCK_PERIOD=1.6] - clock-gated top synthesis"
	@echo "  make synth-config - show the active top-synthesis configuration"
	@echo "  make uvm-test [UVM_SEQ_Q=512] [UVM_SEQ_KV=512] - run one UVM test"
	@echo "  make gate-saif - run 512x512 mapped-netlist SAIF simulation"
	@echo "  make gate-saif-power - run gate-saif and mapped-DDC power readback"
	@echo "  make clean-synth - remove synthesis results and synthesis logs"

synth: synth-system

synth-system:
	$(SYNTH_ENV) $(SYNTH_SCRIPT) $(SYNTH_GROUP) $(SYSTEM_TOP)

synth-config:
	@echo "CORNER=$(CORNER)"
	@echo "CLOCK_PERIOD=$(CLOCK_PERIOD) ns"
	@echo "SYNTH_GROUP=$(SYNTH_GROUP)"
	@echo "CLOCK_GATING=$(CLOCK_GATING)"
	@echo "CLOCK_GATING_MIN_BITWIDTH=$(CLOCK_GATING_MIN_BITWIDTH)"
	@echo "CLOCK_GATING_MAX_FANOUT=$(CLOCK_GATING_MAX_FANOUT)"
	@echo "DC_CORES=$(DC_CORES)"

uvm-test:
	@case "$(UVM_TEST)" in ''|*[!A-Za-z0-9_]*) echo "UVM_TEST must contain only letters, digits, and underscores" >&2; exit 2;; esac
	@case "$(UVM_SEED)" in ''|*[!0-9]*) echo "UVM_SEED must be a non-negative integer" >&2; exit 2;; esac
	@case "$(UVM_SEQ_Q):$(UVM_SEQ_KV):$(UVM_READY_LOW_PCT)" in *[!0-9:]*|::*|:*|*:) echo "UVM sequence and backpressure values must be non-negative integers" >&2; exit 2;; esac
	@case "$(UVM_CAUSAL_EN):$(UVM_DECODE_EN)" in 0:0|0:1|1:0|1:1) ;; *) echo "UVM_CAUSAL_EN and UVM_DECODE_EN must be 0 or 1" >&2; exit 2;; esac
	@mkdir -p tb/sim/$(UVM_SIM_OUT_DIR)/csrc
	cd tb/sim && vcs -full64 -sverilog -ntb_opts uvm -timescale=1ns/1ps \
		-debug_access+all -kdb -lca -Mdir="$(UVM_SIM_OUT_DIR)/csrc" \
		-f filelists/rtl.f -f filelists/uvm.f -top tb_top \
		-l "$(UVM_SIM_OUT_DIR)/compile.log" -o "$(UVM_SIM_OUT_DIR)/simv"
	cd tb/sim && "$(UVM_SIM_OUT_DIR)/simv" +UVM_TESTNAME="$(UVM_TEST)" \
		+ntb_random_seed="$(UVM_SEED)" +CLK_PERIOD_NS="$(UVM_SIM_CLOCK_PERIOD)" \
		+FA_SEQ_Q="$(UVM_SEQ_Q)" +FA_SEQ_KV="$(UVM_SEQ_KV)" \
		+FA_READY_LOW_PCT="$(UVM_READY_LOW_PCT)" +FA_CAUSAL_EN="$(UVM_CAUSAL_EN)" \
		+FA_DECODE_EN="$(UVM_DECODE_EN)" $(UVM_PLUSARGS) \
		-l "$(UVM_SIM_OUT_DIR)/$(UVM_TEST).log"
	@grep -Eq 'UVM_ERROR :[[:space:]]*0' tb/sim/$(UVM_SIM_OUT_DIR)/$(UVM_TEST).log && \
		grep -Eq 'UVM_FATAL :[[:space:]]*0' tb/sim/$(UVM_SIM_OUT_DIR)/$(UVM_TEST).log || \
		{ echo "UVM test failed; see tb/sim/$(UVM_SIM_OUT_DIR)/$(UVM_TEST).log" >&2; exit 1; }
	@echo "PASS $(UVM_TEST) seed=$(UVM_SEED); log: tb/sim/$(UVM_SIM_OUT_DIR)/$(UVM_TEST).log"

uvm-regresssion:
	bash tb/sim/scripts/run_uvm_regression.sh

gate-saif:
	SEED=$(GATE_SAIF_SEED) PROFILE=$(GATE_SAIF_PROFILE) \
	SEQ_Q=$(GATE_SEQ_Q) SEQ_KV=$(GATE_SEQ_KV) READY_LOW_PCT=$(GATE_READY_LOW_PCT) \
	SIM_CLOCK_PERIOD_NS=$(GATE_SIM_CLOCK_PERIOD) OUT_DIR=$(GATE_SIM_OUT_DIR) \
	NETLIST=$(GATE_NETLIST) SDF_FILE=$(GATE_SDF) DDC_FILE=$(GATE_DDC) \
	STD_CELL_V=$(GATE_STD_CELL_V) SRAM_V=$(GATE_SRAM_V) POWER_READBACK=0 \
	$(GATE_SAIF_SCRIPT)

gate-saif-power:
	SEED=$(GATE_SAIF_SEED) PROFILE=$(GATE_SAIF_PROFILE) \
	SEQ_Q=$(GATE_SEQ_Q) SEQ_KV=$(GATE_SEQ_KV) READY_LOW_PCT=$(GATE_READY_LOW_PCT) \
	SIM_CLOCK_PERIOD_NS=$(GATE_SIM_CLOCK_PERIOD) OUT_DIR=$(GATE_SIM_OUT_DIR) \
	NETLIST=$(GATE_NETLIST) SDF_FILE=$(GATE_SDF) DDC_FILE=$(GATE_DDC) \
	STD_CELL_V=$(GATE_STD_CELL_V) SRAM_V=$(GATE_SRAM_V) POWER_READBACK=1 \
	$(GATE_SAIF_SCRIPT)

clean-synth:
	rm -rf asic/dc/work/synth
	rm -f asic/dc/logs/synth_*.log
