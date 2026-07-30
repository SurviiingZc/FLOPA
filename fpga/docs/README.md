# FLOPA FPGA Documentation

| Document | Purpose |
| --- | --- |
| [Final Evaluation Report](final_report_material.md) | authoritative VCK190/SmolLM2 configuration, measurements, and limits |
| [Vivado Flow](vivado_flow.md) | block design, address map, implementation, and export |
| [Vitis/XRT Flow](../vitis/README.md) | common-platform build, packaging, and board smoke |
| [Model Benchmark](../model/README.md) | pinned SmolLM2 PS and PS+PL comparison |
| [Ping-Pong Streaming](pingpong_streaming.md) | mover protocol, bank ownership, backpressure, and reuse |
| [Bring-Up Postmortem](board_bringup_postmortem.md) | root causes, recovery, and release gates |
| [Evaluation Protocol](attention_test_plan.md) | completed SmolLM2 method and remaining Re10K/power plan |

The supported release uses a matched `BOOT.BIN`, xclbin, and AArch64 host from
one Vitis link against `xilinx_vck190_base_202310_1`. Standalone PDI/DTBO,
replacement-rootfs, and mixed-build deployment are not supported.

At the nominal 170 MHz point (170.019 MHz routed), FLOPA achieves
19.762x/9.378x PL-core speedup for SmolLM2 sequence
64/1024. Callback speedups are 1.410x/3.865x and full-prefill speedups are
1.008x/1.185x. The final report is the only authoritative performance table.
Board power and Re10K board measurements remain open.

The retained Vivado timing, utilization, DRC, methodology, clock, and power
container reports are under `../vivado/build/reports/`.
