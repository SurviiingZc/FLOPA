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
# The current implementation is an explicit zero-ICG baseline. DC automatic
# insertion is intentionally unavailable in this flow.
DC_CORES ?= 32
EXPECTED_TOP_SRAM_MACROS ?= 480
EXPECTED_TOP_RTL_ICGS ?= 0

# Physical timing inputs. They deliberately have no repository defaults: these
# views are technology-installation specific and must be provided by the run.
PHYSICAL_MW_LIB ?=
PHYSICAL_TLUPLUS_MAX ?=
PHYSICAL_TLUPLUS_MIN ?=
PHYSICAL_TLUPLUS_MAP ?=
PHYSICAL_FLOORPLAN_FILE ?=
POSTCTS_TOP ?= attention_accel_top
POSTCTS_NETLIST ?=
POSTCTS_SDC ?=
POSTCTS_SPEF ?=

SYSTEM_TOP := attention_accel_top
# The default result is the zero-ICG baseline consumed by gate simulation and
# DC power reporting.
SYNTH_RESULT_DIR = asic/dc/work/synth/$(CORNER)/system/$(SYSTEM_TOP)/results

GATE_SAIF_SEED ?= 301
GATE_SEQ_Q ?= 64
GATE_SEQ_KV ?= 64
GATE_READY_LOW_PCT ?= 0
GATE_SAIF_PROFILE ?= gate_ungated_random_qkv_$(GATE_SEQ_Q)x$(GATE_SEQ_KV)_seed$(GATE_SAIF_SEED)
GATE_SIM_CLOCK_PERIOD ?= 1.6
GATE_SIM_OUT_DIR ?= tb/sim/build/saif_$(GATE_SAIF_PROFILE)
GATE_ANNOTATE_SDF ?= 0
GATE_NETLIST ?= $(SYNTH_RESULT_DIR)/$(SYSTEM_TOP)_mapped.v
GATE_SDF ?= $(SYNTH_RESULT_DIR)/$(SYSTEM_TOP).sdf
GATE_DDC ?= $(SYNTH_RESULT_DIR)/$(SYSTEM_TOP).ddc
GATE_SYNTH_CONFIG ?= $(SYNTH_RESULT_DIR)/../reports/run_config.rpt
GATE_STD_CELL_V ?= /data/public/STD/tcbn28hpcplusbwp12t30p140_190a/tcbn28hpcplusbwp12t30p140_170a_vlg/TSMCHOME/digital/Front_End/verilog/tcbn28hpcplusbwp12t30p140_170a/tcbn28hpcplusbwp12t30p140.v
GATE_SRAM_V ?= /data/public/SRAM/uhdsp_256x8m4s/VERILOG/uhdsp_256x8m4s_tt0p9v25c.v
GATE_TIMING_SEQ_Q ?= 64
GATE_TIMING_SEQ_KV ?= 64
GATE_TIMING_PROFILE ?= gate_timing_random_qkv_$(GATE_TIMING_SEQ_Q)x$(GATE_TIMING_SEQ_KV)_seed$(GATE_SAIF_SEED)
GATE_TIMING_OUT_DIR ?= tb/sim/build/timing_$(GATE_TIMING_PROFILE)

# Formality checks the exact mapped netlist/SVF emitted by the selected synth
# group. Override these only when checking an intentionally archived result.
FORMAL_TOP ?= $(SYSTEM_TOP)
FORMAL_NETLIST ?= $(SYNTH_RESULT_DIR)/$(FORMAL_TOP)_mapped.v
FORMAL_SVF ?= $(SYNTH_RESULT_DIR)/$(FORMAL_TOP).svf
FORMAL_SYNTH_CONFIG ?= $(SYNTH_RESULT_DIR)/../reports/run_config.rpt
FORMAL_OUT_DIR ?= asic/dc/work/formality/$(CORNER)/system/$(FORMAL_TOP)

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
UVM_ASIC_MODEL_FILELIST ?= filelists/asic_models.f
UVM_ASIC_RUNTIME_ARGS ?= +no_notifier +notimingcheck

SYNTH_SCRIPT := asic/scripts/run_synth.sh
SYNTH_PHYSICAL_SCRIPT := asic/scripts/run_synth_physical.sh
PRECTS_HOLD_SCRIPT := asic/scripts/run_prects_hold.sh
POSTCTS_HOLD_SCRIPT := asic/scripts/run_postcts_hold.sh
GATE_SAIF_SCRIPT := tb/sim/scripts/run_gate_saif.sh
FORMALITY_SCRIPT := asic/scripts/run_formality.sh

SYNTH_ENV = CORNER=$(CORNER) CLOCK_PERIOD=$(CLOCK_PERIOD) \
	FA_SETUP_UNCERTAINTY=$(SETUP_UNCERTAINTY) \
	FA_HOLD_UNCERTAINTY=$(HOLD_UNCERTAINTY) \
	FA_CLOCK_TRANSITION=$(CLOCK_TRANSITION) FA_INPUT_DELAY=$(INPUT_DELAY) \
	FA_OUTPUT_DELAY=$(OUTPUT_DELAY) FA_INPUT_TRANSITION=$(INPUT_TRANSITION) \
	FA_OUTPUT_LOAD=$(OUTPUT_LOAD) FA_MAX_TRANSITION=$(MAX_TRANSITION) \
	FA_MAX_FANOUT=$(MAX_FANOUT) DC_CORES=$(DC_CORES) \
	EXPECTED_TOP_SRAM_MACROS=$(EXPECTED_TOP_SRAM_MACROS) \
	EXPECTED_TOP_RTL_ICGS=$(EXPECTED_TOP_RTL_ICGS)

PHYSICAL_OPTIONAL_ENV = $(if $(PHYSICAL_TLUPLUS_MAP),FA_TLUPLUS_MAP="$(PHYSICAL_TLUPLUS_MAP)") \
	$(if $(PHYSICAL_FLOORPLAN_FILE),FA_FLOORPLAN_FILE="$(PHYSICAL_FLOORPLAN_FILE)")

.PHONY: help synth synth-config synth-physical prects-hold postcts-hold \
	formality uvm-test uvm-regression gate-saif gate-saif-power gate-timing \
	precision-check pwl-error ppa-breakdown clean-synth

help:
	@echo "Targets:"
	@echo "  make synth [CORNER=tt] [CLOCK_PERIOD=1.6] - mapped top with no ICG insertion"
	@echo "  make synth-config - show the active top-synthesis configuration"
	@echo "  make formality - prove RTL equivalence of the selected mapped netlist/SVF"
	@echo "  make synth-physical PHYSICAL_MW_LIB=<dir> PHYSICAL_TLUPLUS_MAX=<file> PHYSICAL_TLUPLUS_MIN=<file> - physical-aware synthesis"
	@echo "  make prects-hold PHYSICAL_MW_LIB=<dir> PHYSICAL_TLUPLUS_MIN=<file> - FF/min-RC logical hold repair"
	@echo "  make postcts-hold POSTCTS_NETLIST=<v> POSTCTS_SDC=<sdc> POSTCTS_SPEF=<spef> - propagated-clock FF hold signoff"
	@echo "  make uvm-test [UVM_SEQ_Q=512] [UVM_SEQ_KV=512] - run one UVM test with ASIC SRAM models"
	@echo "  make uvm-regression - run the UVM regression"
	@echo "  make gate-saif - run 64x64 mapped-netlist SAIF simulation"
	@echo "  make gate-saif-power - run gate-saif and mapped-DDC power readback"
	@echo "  make gate-timing GATE_NETLIST=<physical.v> GATE_SDF=<physical.sdf> - timing gate after physical hold closure"
	@echo "  make precision-check [PRECISION_SEED=301] - 64x64 FP32/fixed-point error and scale search"
	@echo "  make pwl-error - exhaustive PWL exp error scan over the implemented Q8 domain"
	@echo "  make ppa-breakdown - extract DC area and Vivado hierarchy breakdown"
	@echo "  make clean-synth - remove synthesis results and synthesis logs"

synth:
	$(SYNTH_ENV) $(SYNTH_SCRIPT) system $(SYSTEM_TOP)

# Run this after every synthesis that will be used by gate simulation or power
# analysis, including a synthesis with logical hold repair. A failing or aborted
# proof returns nonzero and leaves reports below FORMAL_OUT_DIR.
formality:
	CORNER=$(CORNER) FORMAL_TOP=$(FORMAL_TOP) \
		FORMAL_NETLIST="$(FORMAL_NETLIST)" FORMAL_SVF="$(FORMAL_SVF)" \
		FORMAL_SYNTH_CONFIG="$(FORMAL_SYNTH_CONFIG)" \
		FORMAL_EXPECTED_RTL_ICGS="$(EXPECTED_TOP_RTL_ICGS)" \
		FORMAL_OUT_DIR="$(FORMAL_OUT_DIR)" $(FORMALITY_SCRIPT)

# The physical flow consumes real macro abstracts and RC tables. It is a
# placement-aware implementation step, not a substitute for post-CTS signoff.
synth-physical:
	@test -n "$(PHYSICAL_MW_LIB)" && test -d "$(PHYSICAL_MW_LIB)" || { echo "PHYSICAL_MW_LIB must name a combined standard-cell/SRAM Milkyway library" >&2; exit 2; }
	@test -n "$(PHYSICAL_TLUPLUS_MAX)" && test -s "$(PHYSICAL_TLUPLUS_MAX)" || { echo "PHYSICAL_TLUPLUS_MAX must name a max-RC TLU+ file" >&2; exit 2; }
	@test -n "$(PHYSICAL_TLUPLUS_MIN)" && test -s "$(PHYSICAL_TLUPLUS_MIN)" || { echo "PHYSICAL_TLUPLUS_MIN must name a min-RC TLU+ file" >&2; exit 2; }
	$(SYNTH_ENV) FA_MW_LIB="$(PHYSICAL_MW_LIB)" FA_TLUPLUS_MAX="$(PHYSICAL_TLUPLUS_MAX)" \
		FA_TLUPLUS_MIN="$(PHYSICAL_TLUPLUS_MIN)" $(PHYSICAL_OPTIONAL_ENV) \
		$(SYNTH_PHYSICAL_SCRIPT)

# This pre-CTS run uses the FF Liberty and min RC, enables DC logical hold
# repair, and produces an implementation guide before clock-tree insertion.
prects-hold:
	@test -n "$(PHYSICAL_MW_LIB)" && test -d "$(PHYSICAL_MW_LIB)" || { echo "PHYSICAL_MW_LIB must name a combined standard-cell/SRAM Milkyway library" >&2; exit 2; }
	@test -n "$(PHYSICAL_TLUPLUS_MIN)" && test -s "$(PHYSICAL_TLUPLUS_MIN)" || { echo "PHYSICAL_TLUPLUS_MIN must name a min-RC TLU+ file" >&2; exit 2; }
	$(SYNTH_ENV) FA_MW_LIB="$(PHYSICAL_MW_LIB)" FA_TLUPLUS_MIN="$(PHYSICAL_TLUPLUS_MIN)" \
		$(if $(PHYSICAL_TLUPLUS_MAP),FA_TLUPLUS_MAP="$(PHYSICAL_TLUPLUS_MAP)") \
		$(PRECTS_HOLD_SCRIPT)

# This is the hold signoff gate after CTS and routed SPEF are available. The
# underlying PrimeTime script exits nonzero for any setup or hold violation.
postcts-hold:
	@test -n "$(POSTCTS_NETLIST)" && test -s "$(POSTCTS_NETLIST)" || { echo "POSTCTS_NETLIST must name a routed gate netlist" >&2; exit 2; }
	@test -n "$(POSTCTS_SDC)" && test -s "$(POSTCTS_SDC)" || { echo "POSTCTS_SDC must name the propagated-clock SDC" >&2; exit 2; }
	@test -n "$(POSTCTS_SPEF)" && test -s "$(POSTCTS_SPEF)" || { echo "POSTCTS_SPEF must name the routed SPEF" >&2; exit 2; }
	POSTCTS_TOP="$(POSTCTS_TOP)" POSTCTS_NETLIST="$(POSTCTS_NETLIST)" \
		POSTCTS_SDC="$(POSTCTS_SDC)" POSTCTS_SPEF="$(POSTCTS_SPEF)" \
		$(POSTCTS_HOLD_SCRIPT)

synth-config:
	@echo "CORNER=$(CORNER)"
	@echo "CLOCK_PERIOD=$(CLOCK_PERIOD) ns"
	@echo "SYNTH_GROUP=system"
	@echo "CLOCK_GATING=none; expected ICG count is zero"
	@echo "EXPECTED_TOP_RTL_ICGS=$(EXPECTED_TOP_RTL_ICGS)"
	@echo "DC_CORES=$(DC_CORES)"

uvm-test:
	@case "$(UVM_TEST)" in ''|*[!A-Za-z0-9_]*) echo "UVM_TEST must contain only letters, digits, and underscores" >&2; exit 2;; esac
	@case "$(UVM_SEED)" in ''|*[!0-9]*) echo "UVM_SEED must be a non-negative integer" >&2; exit 2;; esac
	@case "$(UVM_SEQ_Q):$(UVM_SEQ_KV):$(UVM_READY_LOW_PCT)" in *[!0-9:]*|::*|:*|*:) echo "UVM sequence and backpressure values must be non-negative integers" >&2; exit 2;; esac
	@case "$(UVM_CAUSAL_EN):$(UVM_DECODE_EN)" in 0:0|0:1|1:0|1:1) ;; *) echo "UVM_CAUSAL_EN and UVM_DECODE_EN must be 0 or 1" >&2; exit 2;; esac
	@mkdir -p tb/sim/$(UVM_SIM_OUT_DIR)/csrc
	cd tb/sim && vcs -full64 -sverilog -ntb_opts uvm -timescale=1ns/1ps \
		-debug_access+all -kdb -lca -Mdir="$(UVM_SIM_OUT_DIR)/csrc" \
		+define+ATTN_ASIC -f "$(UVM_ASIC_MODEL_FILELIST)" \
		-f filelists/rtl.f -f filelists/uvm.f -top tb_top \
		-l "$(UVM_SIM_OUT_DIR)/compile.log" -o "$(UVM_SIM_OUT_DIR)/simv"
	cd tb/sim && "$(UVM_SIM_OUT_DIR)/simv" +UVM_TESTNAME="$(UVM_TEST)" \
		+ntb_random_seed="$(UVM_SEED)" +CLK_PERIOD_NS="$(UVM_SIM_CLOCK_PERIOD)" \
		+FA_SEQ_Q="$(UVM_SEQ_Q)" +FA_SEQ_KV="$(UVM_SEQ_KV)" \
		+FA_READY_LOW_PCT="$(UVM_READY_LOW_PCT)" +FA_CAUSAL_EN="$(UVM_CAUSAL_EN)" \
		+FA_DECODE_EN="$(UVM_DECODE_EN)" $(UVM_ASIC_RUNTIME_ARGS) $(UVM_PLUSARGS) \
		-l "$(UVM_SIM_OUT_DIR)/$(UVM_TEST).log"
	@grep -Eq 'UVM_ERROR :[[:space:]]*0' tb/sim/$(UVM_SIM_OUT_DIR)/$(UVM_TEST).log && \
		grep -Eq 'UVM_FATAL :[[:space:]]*0' tb/sim/$(UVM_SIM_OUT_DIR)/$(UVM_TEST).log || \
		{ echo "UVM test failed; see tb/sim/$(UVM_SIM_OUT_DIR)/$(UVM_TEST).log" >&2; exit 1; }
	@echo "PASS $(UVM_TEST) seed=$(UVM_SEED); log: tb/sim/$(UVM_SIM_OUT_DIR)/$(UVM_TEST).log"

uvm-regression:
	bash tb/sim/scripts/run_uvm_regression.sh

GATE_SAIF_ENV = SEED=$(GATE_SAIF_SEED) READY_LOW_PCT=$(GATE_READY_LOW_PCT) \
	SIM_CLOCK_PERIOD_NS=$(GATE_SIM_CLOCK_PERIOD) NETLIST=$(GATE_NETLIST) \
	SDF_FILE=$(GATE_SDF) DDC_FILE=$(GATE_DDC) SYNTH_CONFIG=$(GATE_SYNTH_CONFIG) \
	STD_CELL_V=$(GATE_STD_CELL_V) \
	SRAM_V=$(GATE_SRAM_V) EXPECTED_RTL_ICGS=$(EXPECTED_TOP_RTL_ICGS)

gate-saif:
	$(GATE_SAIF_ENV) PROFILE=$(GATE_SAIF_PROFILE) SEQ_Q=$(GATE_SEQ_Q) \
	SEQ_KV=$(GATE_SEQ_KV) OUT_DIR=$(GATE_SIM_OUT_DIR) POWER_READBACK=0 \
	TIMING_CHECKS=0 ANNOTATE_SDF=$(GATE_ANNOTATE_SDF) CAPTURE_SAIF=1 \
	$(GATE_SAIF_SCRIPT)

gate-saif-power:
	$(GATE_SAIF_ENV) PROFILE=$(GATE_SAIF_PROFILE) SEQ_Q=$(GATE_SEQ_Q) \
	SEQ_KV=$(GATE_SEQ_KV) OUT_DIR=$(GATE_SIM_OUT_DIR) POWER_READBACK=1 \
	TIMING_CHECKS=0 ANNOTATE_SDF=$(GATE_ANNOTATE_SDF) CAPTURE_SAIF=1 \
	$(GATE_SAIF_SCRIPT)

# Timing validation uses the same UVM workload and SDF as gate-SAIF, but keeps
# SRAM timing checks enabled and fails if VCS reports any violation.
gate-timing:
	$(GATE_SAIF_ENV) PROFILE=$(GATE_TIMING_PROFILE) SEQ_Q=$(GATE_TIMING_SEQ_Q) \
	SEQ_KV=$(GATE_TIMING_SEQ_KV) OUT_DIR=$(GATE_TIMING_OUT_DIR) POWER_READBACK=0 \
	TIMING_CHECKS=1 ANNOTATE_SDF=1 CAPTURE_SAIF=0 \
	$(GATE_SAIF_SCRIPT)

PRECISION_SEED ?= 301
PRECISION_OUT ?= docs/results/precision_64x64.json
PWL_ERROR_OUT ?= docs/results/pwl_error.json
PPA_BREAKDOWN_OUT ?= docs/results/ppa_breakdown.json

precision-check:
	python3 scripts/precision/attention_precision.py --seed $(PRECISION_SEED) \
		--rows 64 --dim 64 --out $(PRECISION_OUT)

pwl-error:
	python3 scripts/precision/pwl_error.py --out $(PWL_ERROR_OUT)

ppa-breakdown:
	python3 scripts/report/ppa_breakdown.py --root . --out $(PPA_BREAKDOWN_OUT)

clean-synth:
	rm -rf asic/dc/work/synth
	rm -rf asic/dc/work/power
	rm -rf asic/dc/work/formality
	rm -rf asic/dc/work/saif_power
	rm -f asic/dc/logs/synth_*.log
