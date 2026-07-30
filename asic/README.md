# ASIC Synthesis and Power Flow

The final synthesis configuration targets `attention_accel_top` with the TSMC
28 nm TT 0.9 V, 25 C CCS standard-cell library and the matching
`uhdsp_256x8m4s` SRAM library. The target period is 1.60 ns (625 MHz).

Run from the repository root:

```bash
make synth-config
make synth CORNER=tt CLOCK_PERIOD=1.6
make formality CORNER=tt
make gate-saif CORNER=tt GATE_SEQ_Q=64 GATE_SEQ_KV=64 GATE_SAIF_SEED=301
make gate-saif-power CORNER=tt GATE_SEQ_Q=64 GATE_SEQ_KV=64 GATE_SAIF_SEED=301
```

The flow checks 480 SRAM macros and 1,220 multiplier wrappers linked to
DesignWare `DW02_mult`. It emits mapped Verilog, DDC, SDC, SDF, SVF, timing,
area, resource, and configuration reports below
`asic/dc/work/synth/<corner>/system/attention_accel_top/`. Power Compiler
outputs are written below `asic/dc/work/power/reports/`.

## Final Estimate

| Metric | Value |
| --- | ---: |
| target clock | 1.60 ns / 625 MHz |
| setup WNS / TNS | 0.000 / 0.000 ns |
| critical path | 1.49 ns, 57 logic levels |
| cell area | 2,436,075.17 library units |
| mapped leaf cells | 1,518,837 |
| SRAM macros | 480 |
| dynamic / leakage / total power | 648.6251 / 9.8584 / 658.4835 mW |
| net switching power | 18.1893 mW |

The power workload is a 64 x 64 random MHA prefill (`seed=301`) with 100%
SAIF annotation and zero UVM errors/fatals. These are mapped pre-layout
estimates; [PPA and Optimization](../docs/ppa_and_optimization.md) defines the
measurement boundary and derived throughput convention.

The synthesis-local `reports/power.rpt` uses default vectorless activity and
reports 594.6547 mW total power. It is retained as a synthesis diagnostic only;
the workload-annotated gate-SAIF result above is the reportable power number.

## Memory Mapping

Library selection is centralized in `asic/scripts/library_paths.sh`. The final
32 x 32 x 64 top uses byte-wide SRAM macros as follows:

| Owner | Macro count |
| --- | ---: |
| Q/K/V ping-pong cache | 192 |
| persistent O banks | 256 |
| output buffer | 32 |
| total | 480 |

The current composition is functional and characterized. Wider/deeper O-bank
macros remain a physical-design optimization because the 256 x 8 composition
prioritizes library availability over bit efficiency.

## Physical Implementation

`make synth-physical` accepts an assembled Milkyway library and max/min TLU+
files. Use `make help` for the exact parameters. This stage is separate from
the reproducible logical-synthesis and gate-SAIF flow above.
