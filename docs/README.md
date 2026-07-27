# FLOPA Documentation Index

The maintained submission set is intentionally small. RTL and generated tool
reports remain the source of truth if a document conflicts with an artifact.

## Submission Documents

| Deliverable | Document |
| --- | --- |
| architecture, algorithm, storage, and detailed design | [Design Specification](design_specification.md) |
| register definitions and external interfaces | [Register and Interface Reference](register_and_interface_reference.md) |
| resource, timing, power, performance, and optimization analysis | [PPA and Optimization](ppa_and_optimization.md) |
| verification plan, test cases, coverage, and waveform instructions | [Verification Report](verification_report.md) |
| requirement traceability and final packaging | [Submission Checklist](submission_checklist.md) |
| repository layout and reproduction | [Root README](../README.md) |
| presentation structure | [Defense Outline](../ppt/defense_outline.md) |

## Engineering References

| Document | Role |
| --- | --- |
| [RTL Code Guide](rtl.md) | detailed Chinese walkthrough from top level through PE dataflow |
| [Synthesis Notes](synth.md) | internal chronological synthesis/debug record; not a submission result table |
| [ASIC README](../asic/README.md) | current synthesis and power commands |
| [FPGA Test Plan](../fpga/docs/attention_test_plan.md) | VCK190 Re10K and LLM experiment plan |
| [Module-TB README](../tb/module_tb/README.md) | directed-test inventory and FSDB convention |

## Maintained Figures

- `../figures/architecture/flopa_overall_architecture.png`
- `../figures/dataflow/flopa_design_overview.png`
- `../figures/pipeline/flash_attention_pipeline.{pdf,svg,png,tiff}`

The architecture PNG is the current overview asset. The pipeline is available
in vector and raster formats for papers and slides.

## Result Update Rule

Update [PPA and Optimization](ppa_and_optimization.md),
[Verification Report](verification_report.md), the root README, and the defense
outline together whenever a new result is accepted. Record the RTL revision,
test, seed, clock, PVT, tool versions, and exact artifact path. Superseded
standalone result reports should be removed rather than retained beside the
current baseline.
