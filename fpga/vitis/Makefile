SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

XILINX_VITIS ?= /opt/Xilinx/Vitis/2023.1
XILINX_VIVADO ?= /opt/Xilinx/Vivado/2023.1
PLATFORM_DIR ?= $(XILINX_VITIS)/base_platforms/xilinx_vck190_base_202310_1
PLATFORM ?= $(PLATFORM_DIR)/xilinx_vck190_base_202310_1.xpfm
SYSROOT ?= /opt/petalinux/2023.1/sysroots/cortexa72-cortexa53-xilinx-linux

VPP ?= $(XILINX_VITIS)/bin/v++
VIVADO ?= $(XILINX_VIVADO)/bin/vivado
ifeq ($(origin CXX),default)
CXX := $(XILINX_VITIS)/gnu/aarch64/lin/aarch64-linux/bin/aarch64-linux-gnu-g++
endif
XCLBINUTIL ?= /opt/xilinx/xrt/bin/xclbinutil
TARGET ?= hw
FREQ_HZ ?= 170000000
JOBS ?= 1

BUILD_DIR ?= $(abspath build)
RTL_XO := $(BUILD_DIR)/dit_fa.xo
MOVER_XO := $(BUILD_DIR)/dit_fa_tile_mover.xo
LINK_XSA := $(BUILD_DIR)/dit_fa_link.xsa
XCLBIN := $(BUILD_DIR)/dit_fa.xclbin
BOOT_BIN := $(BUILD_DIR)/package/BOOT.BIN
HOST := $(BUILD_DIR)/dit_fa_xrt_test
RUNTIME_DIR := $(BUILD_DIR)/runtime
RUNTIME_TAR := $(BUILD_DIR)/dit-fa-xrt-runtime.tar.gz
GIT_COMMIT := $(shell git -C ../.. rev-parse HEAD 2>/dev/null || printf unknown)

RTL_SOURCES := $(wildcard rtl/*.v) kernel.xml scripts/package_rtl_kernel.tcl
RTL_SOURCES += $(wildcard ../rtl/*.v ../../rtl/*/*.v ../../rtl/*.v)
HLS_SOURCES := hls/dit_fa_tile_mover.cpp
HOST_SOURCES := host/dit_fa_xrt_test.cpp

HOST_FLAGS := -std=c++17 -O2 -Wall -Wextra -Werror --sysroot=$(SYSROOT)
HOST_FLAGS += -I$(SYSROOT)/usr/include/xrt
HOST_LINK_FLAGS := --sysroot=$(SYSROOT) -L$(SYSROOT)/usr/lib
HOST_LINK_FLAGS += -lxrt_coreutil -luuid -lpthread -lrt -ldl

.NOTPARALLEL:

.PHONY: all help check rtl-xo mover-xo xo link xclbin host
.PHONY: runtime inspect clean

all: runtime

help:
	@printf '%s\n' 'Vitis/XRT flow for the installed VCK190 common platform'
	@printf '%s\n' ''
	@printf '%s\n' '  make -C fpga/vitis xo'
	@printf '%s\n' '  make -C fpga/vitis xclbin FREQ_HZ=170000000 JOBS=1'
	@printf '%s\n' '  make -C fpga/vitis host'
	@printf '%s\n' '  make -C fpga/vitis runtime'
	@printf '%s\n' ''
	@printf '%s\n' 'Copy build/runtime to the board, then follow runtime/README.md.'

check:
	@test -r "$(PLATFORM)" || { echo "Platform not found: $(PLATFORM)" >&2; exit 1; }
	@test -d "$(SYSROOT)" || { echo "Sysroot not found: $(SYSROOT)" >&2; exit 1; }
	@test -x "$(VPP)" || { echo "v++ not found: $(VPP)" >&2; exit 1; }
	@test -x "$(VIVADO)" || { echo "Vivado not found: $(VIVADO)" >&2; exit 1; }
	@test -x "$(CXX)" || { echo "AArch64 C++ compiler not found: $(CXX)" >&2; exit 1; }

rtl-xo: check $(RTL_XO)

$(RTL_XO): $(RTL_SOURCES)
	@mkdir -p "$(BUILD_DIR)"
	"$(VIVADO)" -mode batch -log "$(BUILD_DIR)/package_rtl.log" \
		-journal "$(BUILD_DIR)/package_rtl.jou" \
		-source scripts/package_rtl_kernel.tcl \
		-tclargs "$@" "$(BUILD_DIR)/rtl"

mover-xo: check $(MOVER_XO)

$(MOVER_XO): $(HLS_SOURCES)
	@mkdir -p "$(BUILD_DIR)"
	"$(VPP)" -c -t "$(TARGET)" --platform "$(PLATFORM)" \
		-k dit_fa_tile_mover --hls.clock "$(FREQ_HZ):dit_fa_tile_mover" \
		--hls.jobs "$(JOBS)" --temp_dir "$(BUILD_DIR)/mover" \
		-o "$@" "$<"

xo: rtl-xo mover-xo

xclbin: check $(XCLBIN)

link: check $(LINK_XSA)

$(LINK_XSA): $(RTL_XO) $(MOVER_XO) system.cfg
	"$(VPP)" -l -t "$(TARGET)" --platform "$(PLATFORM)" \
		--config system.cfg --clock.defaultFreqHz "$(FREQ_HZ)" \
		--vivado.synth.jobs "$(JOBS)" --vivado.impl.jobs "$(JOBS)" \
		--temp_dir "$(BUILD_DIR)/link" --report_dir "$(BUILD_DIR)/reports" \
		--log_dir "$(BUILD_DIR)/logs" -o "$@" "$(RTL_XO)" "$(MOVER_XO)"

$(XCLBIN): $(LINK_XSA)
	@mkdir -p "$(BUILD_DIR)/package"
	"$(VPP)" -p -t "$(TARGET)" --platform "$(PLATFORM)" \
		--package.boot_mode sd --package.no_image \
		--package.out_dir "$(BUILD_DIR)/package" \
		--temp_dir "$(BUILD_DIR)/package_tmp" \
		--report_dir "$(BUILD_DIR)/reports/package" \
		--log_dir "$(BUILD_DIR)/logs/package" -o "$@" "$<"

$(BOOT_BIN): $(XCLBIN)
	@mkdir -p "$(dir $@)"
	"$(XCLBINUTIL)" --input "$(XCLBIN)" \
		--dump-section "PDI:RAW:$@" --force

host: check $(HOST)

$(HOST): $(HOST_SOURCES)
	@mkdir -p "$(BUILD_DIR)"
	"$(CXX)" $(HOST_FLAGS) "$<" -o "$@" $(HOST_LINK_FLAGS)

runtime: $(XCLBIN) $(BOOT_BIN) $(HOST)
	scripts/package_runtime.sh "$(XCLBIN)" "$(BOOT_BIN)" "$(HOST)" \
		"$(RUNTIME_DIR)" "$(RUNTIME_TAR)" "$(FREQ_HZ)" "$(GIT_COMMIT)"

inspect: $(XCLBIN)
	"$(XCLBINUTIL)" --info --input "$(XCLBIN)"

clean:
	$(RM) -r "$(BUILD_DIR)" .Xil *.log *.jou
