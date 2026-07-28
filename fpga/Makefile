SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

VIVADO ?= vivado
JOBS ?= 8
FREQ_MHZ ?= 170
FREQ_HZ ?= 170000000
SYNTH_MIN_WNS ?= 0.0
VIVADO_SCRIPT := $(abspath vivado/scripts/run_flow.tcl)
VIVADO_BUILD_DIR := vivado/build

export FREQ_MHZ SYNTH_MIN_WNS

.NOTPARALLEL:

.PHONY: all help check-vivado project synth impl hw vitis-xo xclbin host \
	runtime full clean-vivado clean-vitis clean

all: runtime

help:
	@printf '%s\n' 'Board deployment uses the Vitis/XRT common-platform flow:'
	@printf '%s\n' '  source fpga/my_env.sh'
	@printf '%s\n' '  make -C fpga runtime FREQ_HZ=170000000 JOBS=8'
	@printf '%s\n' ''
	@printf '%s\n' 'Targets:'
	@printf '%s\n' '  synth      Run the standalone Vivado RTL timing baseline.'
	@printf '%s\n' '  impl       Run the standalone Vivado implementation baseline.'
	@printf '%s\n' '  vitis-xo   Package the RTL and HLS kernels.'
	@printf '%s\n' '  xclbin     Link the kernels into the VCK190 common platform.'
	@printf '%s\n' '  host       Cross-compile the AArch64 XRT test.'
	@printf '%s\n' '  runtime    Build the matched BOOT.BIN, xclbin, and host payload.'

check-vivado:
	@command -v "$(VIVADO)" >/dev/null || { \
		echo 'Vivado not found; run: source fpga/my_env.sh' >&2; \
		exit 1; \
	}

project: check-vivado
	@mkdir -p "$(VIVADO_BUILD_DIR)"
	cd "$(VIVADO_BUILD_DIR)" && "$(VIVADO)" -mode batch -log project.log \
		-journal project.jou -source "$(VIVADO_SCRIPT)" -tclargs project "$(JOBS)"

synth: check-vivado
	@mkdir -p "$(VIVADO_BUILD_DIR)"
	cd "$(VIVADO_BUILD_DIR)" && "$(VIVADO)" -mode batch -log synth.log \
		-journal synth.jou -source "$(VIVADO_SCRIPT)" -tclargs synth "$(JOBS)"

impl: check-vivado
	@mkdir -p "$(VIVADO_BUILD_DIR)"
	cd "$(VIVADO_BUILD_DIR)" && "$(VIVADO)" -mode batch -log impl.log \
		-journal impl.jou -source "$(VIVADO_SCRIPT)" -tclargs impl "$(JOBS)"

hw: impl

vitis-xo:
	+$(MAKE) -C vitis xo FREQ_HZ="$(FREQ_HZ)" JOBS="$(JOBS)"

xclbin:
	+$(MAKE) -C vitis xclbin FREQ_HZ="$(FREQ_HZ)" JOBS="$(JOBS)"

host:
	+$(MAKE) -C vitis host FREQ_HZ="$(FREQ_HZ)" JOBS="$(JOBS)"

runtime:
	+$(MAKE) -C vitis runtime FREQ_HZ="$(FREQ_HZ)" JOBS="$(JOBS)"

full: runtime

clean-vivado:
	$(RM) -r "$(VIVADO_BUILD_DIR)"

clean-vitis:
	+$(MAKE) -C vitis clean

clean: clean-vitis
