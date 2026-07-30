# FLOPA Documentation Index

This directory contains the maintained contest-facing documentation. RTL,
tool reports, and raw board-result JSON remain the primary evidence whenever a
summary table must be regenerated.

## Submission Documents

| Deliverable | Document |
| --- | --- |
| architecture, algorithm, storage, dataflow, and results | [Technical Report](design_specification.md) |
| register definitions and external interfaces | [Register and Interface Reference](register_and_interface_reference.md) |
| area, timing, power, performance, and optimization analysis | [PPA and Optimization](ppa_and_optimization.md) |
| verification plan, tests, coverage, and waveform guidance | [Verification Report](verification_report.md) |
| requirement traceability and packaging | [Submission Checklist](submission_checklist.md) |
| detailed RTL implementation walkthrough | [RTL Code Guide](rtl.md) |
| repository layout and reproduction | [Root README](../README.md) |
| presentation structure | [Defense Outline](../ppt/defense_outline.md) |

## Supporting Evidence

| Document | Role |
| --- | --- |
| [ASIC Flow](../asic/README.md) | synthesis, equivalence, SAIF, and Power Compiler commands |
| [DC Reports](../asic/dc/work/synth/tt/system/attention_accel_top/reports/) | accepted QoR, area, timing, resource, power, and design-check reports |
| [FPGA Evaluation](../fpga/docs/final_report_material.md) | final VCK190 and SmolLM2 result tables |
| [FPGA Flow Index](../fpga/docs/README.md) | Vivado/Vitis, board, and remaining Re10K work |
| [Vivado Reports](../fpga/vivado/build/reports/) | synthesis and routed timing, utilization, DRC, methodology, clock, and power container |
| [Module Tests](../tb/module_tb/README.md) | directed-test inventory and FSDB convention |
| [Coverage Waivers](../tb/sim/coverage/README.md) | reviewed structural exclusions and sign-off scores |

## Maintained Figures

- `../figures/flopa_overall_architecture.png`
- `../figures/flopa_design_overview.png`
- `../figures/flopa_design_QKT.png`
- `../figures/flopa_design_PV.png`
- `../figures/flash_attention_pipeline.png`

The PNG files are the maintained report assets. Editable draw.io sources are
kept outside the source package.

## Result Update Rule

When accepting a new result, update the technical report, PPA report,
verification report, root README, submission checklist, and defense outline as
one change. Preserve workload, clock, PVT, seed, tool version, and artifact
identity with every quantitative claim. Do not add standalone copies of an
existing result table.
