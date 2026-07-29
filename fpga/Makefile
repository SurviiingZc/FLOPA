SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

VIVADO ?= vivado
JOBS ?= 1
FREQ_MHZ ?= 170
FREQ_HZ ?= 170000000
SYNTH_MIN_WNS ?= 0.0
VIVADO_SCRIPT := $(abspath vivado/scripts/run_flow.tcl)
VIVADO_BUILD_DIR := vivado/build
MODEL_PAYLOAD_DIR := model/deploy

export FREQ_MHZ SYNTH_MIN_WNS

.NOTPARALLEL:

.PHONY: all help check-vivado project synth impl hw pingpong-sim vitis-xo xclbin host \
	runtime model-download model-host model-payload model full clean-vivado clean-vitis clean

all: runtime

help:
	@printf '%s\n' 'Board deployment uses the Vitis/XRT common-platform flow:'
	@printf '%s\n' '  source fpga/my_env.sh'
	@printf '%s\n' '  make -C fpga runtime FREQ_HZ=170000000 JOBS=1'
	@printf '%s\n' ''
	@printf '%s\n' 'Targets:'
	@printf '%s\n' '  synth      Run the standalone Vivado RTL timing baseline.'
	@printf '%s\n' '  impl       Run the standalone Vivado implementation baseline.'
	@printf '%s\n' '  pingpong-sim  Verify loader/cache and multi-head scheduling with XSIM.'
	@printf '%s\n' '  vitis-xo   Package the RTL and HLS kernels.'
	@printf '%s\n' '  xclbin     Link the kernels into the VCK190 common platform.'
	@printf '%s\n' '  host       Cross-compile the AArch64 XRT test.'
	@printf '%s\n' '  runtime    Build the matched BOOT.BIN, xclbin, and host payload.'
	@printf '%s\n' '  model      Download the pinned model and build the AArch64 model test.'
	@printf '%s\n' '  model-payload  Build the board-ready model host and test payload.'

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

pingpong-sim:
	vivado/scripts/run_pingpong_sim.sh

vitis-xo:
	+$(MAKE) -C vitis xo FREQ_HZ="$(FREQ_HZ)" JOBS="$(JOBS)"

xclbin:
	+$(MAKE) -C vitis xclbin FREQ_HZ="$(FREQ_HZ)" JOBS="$(JOBS)"

host:
	+$(MAKE) -C vitis host FREQ_HZ="$(FREQ_HZ)" JOBS="$(JOBS)"

runtime:
	+$(MAKE) -C vitis runtime FREQ_HZ="$(FREQ_HZ)" JOBS="$(JOBS)"

model-download:
	models/download_model.sh

model-host:
	JOBS="$(JOBS)" model/scripts/build_aarch64.sh

model-payload: model-download model-host
	$(RM) -r "$(MODEL_PAYLOAD_DIR)"
	install -d "$(MODEL_PAYLOAD_DIR)"
	install -m 0755 model/build-aarch64/dit_fa_model_bench \
		"$(MODEL_PAYLOAD_DIR)/dit_fa_model_bench"
	install -m 0755 model/scripts/run_board_compare.sh \
		"$(MODEL_PAYLOAD_DIR)/run_board_compare.sh"
	install -m 0644 model/test_vectors/prompt.txt \
		"$(MODEL_PAYLOAD_DIR)/prompt_64.txt"
	install -m 0644 model/test_vectors/prompt_1024.txt \
		"$(MODEL_PAYLOAD_DIR)/prompt_1024.txt"
	install -m 0644 models/manifest.json "$(MODEL_PAYLOAD_DIR)/model_manifest.json"
	install -m 0644 model/deploy.README.md "$(MODEL_PAYLOAD_DIR)/README.md"
	cd "$(MODEL_PAYLOAD_DIR)" && sha256sum dit_fa_model_bench \
		run_board_compare.sh prompt_64.txt prompt_1024.txt model_manifest.json \
		README.md > SHA256SUMS

model: model-payload

full: runtime

clean-vivado:
	$(RM) -r "$(VIVADO_BUILD_DIR)"

clean-vitis:
	+$(MAKE) -C vitis clean

clean: clean-vitis
