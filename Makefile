SHELL := /bin/bash

CORNER ?= tt
CLOCK_PERIOD ?= 3.2

SYNTH_SCRIPT := asic/scripts/run_synth.sh

AXI_TOPS := axi4_slave_if axi4_master_write
CONTROL_TOPS := accel_regfile accel_scheduler perf_counter
COMPUTE_TOPS := scale_requant_unit os_fsa_pe os_fsa_array \
	os_fsa_controller qk_engine pv_engine
MEMORY_TOPS := asic_sram_1024x16 asic_sram_256xwide banked_sram \
	bram_buffer output_buffer pingpong_buffer qkv_tile_cache stream_fifo uram_bank
SOFTMAX_TOPS := causal_mask row_broadcast row_reduce_unit pwl_exp_unit \
	block_lse_update reciprocal_lut online_normalizer softmax_engine

.PHONY: help sram-lib rtl-check pe-timing \
	synth-module synth-axi synth-control synth-compute synth-memory synth-softmax \
	synth-modules synth-top synth-all clean-synth

.NOTPARALLEL: synth-modules synth-all

help:
	@echo "Synthesis targets:"
	@echo "  make synth-module TOP=os_fsa_pe [CORNER=tt|ss] [CLOCK_PERIOD=3.2]"
	@echo "  make synth-axi       - synthesize each AXI module independently"
	@echo "  make synth-control   - synthesize each control module independently"
	@echo "  make synth-compute   - synthesize each compute module independently"
	@echo "  make synth-memory    - synthesize each memory module independently"
	@echo "  make synth-softmax   - synthesize each softmax module independently"
	@echo "  make synth-modules   - synthesize every submodule"
	@echo "  make synth-top       - synthesize attention_accel_top"
	@echo "  make synth-all       - synthesize submodules, then the full top"
	@echo "  make sram-lib        - prepare the SRAM DB for CORNER"
	@echo "  make rtl-check       - elaborate/link the complete ASIC RTL"
	@echo "  make pe-timing       - run the focused PE timing flow"

sram-lib:
	asic/scripts/prepare_sram_lib.sh $(CORNER)

rtl-check:
	asic/scripts/run_rtl_check.sh

pe-timing:
	asic/scripts/run_pe_timing.sh $(CORNER)

synth-module:
	@test -n "$(TOP)" || { echo "TOP is required" >&2; exit 2; }
	CORNER=$(CORNER) CLOCK_PERIOD=$(CLOCK_PERIOD) \
		$(SYNTH_SCRIPT) module $(TOP)

synth-axi:
	CORNER=$(CORNER) CLOCK_PERIOD=$(CLOCK_PERIOD) \
		$(SYNTH_SCRIPT) axi $(AXI_TOPS)

synth-control:
	CORNER=$(CORNER) CLOCK_PERIOD=$(CLOCK_PERIOD) \
		$(SYNTH_SCRIPT) control $(CONTROL_TOPS)

synth-compute:
	CORNER=$(CORNER) CLOCK_PERIOD=$(CLOCK_PERIOD) \
		$(SYNTH_SCRIPT) compute $(COMPUTE_TOPS)

synth-memory:
	CORNER=$(CORNER) CLOCK_PERIOD=$(CLOCK_PERIOD) \
		$(SYNTH_SCRIPT) memory $(MEMORY_TOPS)

synth-softmax:
	CORNER=$(CORNER) CLOCK_PERIOD=$(CLOCK_PERIOD) \
		$(SYNTH_SCRIPT) softmax $(SOFTMAX_TOPS)

synth-modules: synth-axi synth-control synth-compute synth-memory synth-softmax

synth-top:
	CORNER=$(CORNER) CLOCK_PERIOD=$(CLOCK_PERIOD) \
		$(SYNTH_SCRIPT) top attention_accel_top

synth-all: synth-modules synth-top

clean-synth:
	rm -rf asic/dc/work/synth
	rm -f asic/dc/logs/synth_*.log
