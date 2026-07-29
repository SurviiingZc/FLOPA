# FPGA Board-Level Test Documents

- `attention_test_plan.md`: Re10K and LLM Attention board test plan.
- `board_bringup_postmortem.md`: Board failures, root causes, recovery, and release gates.
- `pingpong_streaming.md`: Batched mover protocol, cache ownership, and bandwidth method.
- `model_dataflow.md`: Current PS+PL model data flow and prioritized optimization plan.
- `final_report_material.md`: Reproducible measurements and final-report conclusions.
- `vivado_flow.md`: Vivado block design, implementation, and hardware export flow.
- `../vitis/README.md`: Common-platform Vitis/XRT build and board test flow.
- `../model/README.md`: Pinned SmolLM2 full-model PS and PS+PL comparison flow.

Board deployment uses the matched `BOOT.BIN`, xclbin, and AArch64 host generated
under `fpga/vitis`. The standalone PDI, DTBO, kernel-module, WIC, and replacement
rootfs paths are not part of the supported flow.

The final 170 MHz board result demonstrates `19.762x` Attention-core acceleration at seq64 and
`9.378x` at seq1024. The current Attention integration bottleneck is PS-side quantization,
packing, GQA expansion, and output conversion. See `final_report_material.md` for the only
authoritative performance table; older exploratory results are not retained.
