# FPGA Board-Level Test Documents

- `attention_test_plan.md`: Re10K and LLM Attention board test plan.
- `vivado_flow.md`: Vivado block design, implementation, and hardware export flow.
- `../vitis/README.md`: Common-platform Vitis/XRT build and board test flow.

Board deployment uses the matched `BOOT.BIN`, xclbin, and AArch64 host generated
under `fpga/vitis`. The standalone PDI, DTBO, kernel-module, WIC, and replacement
rootfs paths are not part of the supported flow.
