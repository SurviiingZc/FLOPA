# FPGA Board-Level Test Documents

- `attention_test_plan.md`: Re10K and LLM Attention board test plan.
- `board_bringup_postmortem.md`: Board failures, root causes, recovery, and release gates.
- `pingpong_streaming.md`: Batched mover protocol, cache ownership, and bandwidth method.
- `model_dataflow.md`: Current PS+PL model data flow and prioritized optimization plan.
- `vivado_flow.md`: Vivado block design, implementation, and hardware export flow.
- `../vitis/README.md`: Common-platform Vitis/XRT build and board test flow.
- `../model/README.md`: Pinned SmolLM2 full-model PS and PS+PL comparison flow.

Board deployment uses the matched `BOOT.BIN`, xclbin, and AArch64 host generated
under `fpga/vitis`. The standalone PDI, DTBO, kernel-module, WIC, and replacement
rootfs paths are not part of the supported flow.
