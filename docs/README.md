# FLOPA Documentation Index

This directory contains the current English documentation set for submission.
It replaces the earlier fragmented design notes, implementation diaries, and
coverage summaries. The RTL under `../rtl/` and the checked reports under
`../asic/dc/work/` remain the source of truth when a document conflicts with
an implementation artifact.

## Submission Set

| Required deliverable | Document | Evidence location |
| --- | --- | --- |
| Register map and external interfaces | [Register and Interface Reference](register_and_interface_reference.md) | `rtl/common/attention_defines.vh`, `rtl/control/accel_regfile.v`, `rtl/attention_accel_top.v` |
| Storage definitions and architecture description | [Design Specification](design_specification.md) Sections 3 and 4 | `rtl/memory/`, `rtl/axi/`, `rtl/control/`, `rtl/attention_accel_top.v` |
| Algorithm, buffer architecture, and detailed design | [Design Specification](design_specification.md) Sections 2, 5, and 6 | `rtl/compute/`, `rtl/softmax/` and `figures/` |
| Resource, power, and performance analysis | [PPA and Optimization](ppa_and_optimization.md) | `asic/dc/work/synth/` and `asic/dc/work/power/` |
| Verification plan | [Verification Report](verification_report.md) Sections 2-4 | `tb/module_tb/`, `tb/uvm/`, `tb/sim/` |
| Test-case analysis and coverage analysis | [Verification Report](verification_report.md) Sections 5-7 | `tb/sim/build/.../urg/` |
| Requirement compliance and open items | [Submission Checklist](submission_checklist.md) | Cross-reference to the documents above |
| Repository overview and reproduction | [Root README](../README.md) | Root `Makefile`, `tb/sim/Makefile` |

## Figures

The design document uses the following maintained assets:

- `../figures/architecture/flash_attention_accelerator_architecture.{pdf,svg,png,tiff}`
- `../figures/pipeline/flash_attention_pipeline.{pdf,svg,png,tiff}`

For a two-column paper or presentation, use the PDF/SVG. The PNG/TIFF forms
are supplied for review systems that do not accept vector graphics.

## Supplementary Material Retained Outside This Directory

- `../asic/docs/`: implementation-specific SAIF workflow and gate-power report.
- `reference/rtl_code_guide_zh.md`: detailed Chinese RTL reading guide,
  retained as engineering reference rather than a second submission document.
- `../docs/pdf/`: supplied reference papers and literature index.
- `../ppt/defense_outline.md`: source outline for the required defense slides.
- `../fpga/`: board-integration collateral. It is not used as evidence of a
  completed VCK190 implementation.

Do not copy a result from a superseded report into the submission documents.
When a new run is accepted, update the baseline table in
[PPA and Optimization](ppa_and_optimization.md) and the run record in
[Verification Report](verification_report.md) together.
