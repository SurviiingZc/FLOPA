# ASIC Synthesis and Power Flow

The current baseline targets the TSMC 28 nm TT 0.9 V, 25 C CCS standard-cell
library and the matching `uhdsp_256x8m4s` SRAM library. The default design point
is `attention_accel_top` at 1.60 ns with zero RTL and zero automatically inserted
clock gates.

Run all commands from the repository root.

```bash
# Show the active configuration.
make synth-config

# Generate the mapped TT baseline and prove equivalence.
make synth CORNER=tt CLOCK_PERIOD=1.6
make formality CORNER=tt

# Run the default 64 x 64 mapped-netlist activity workload.
make gate-saif CORNER=tt GATE_SEQ_Q=64 GATE_SEQ_KV=64 GATE_SAIF_SEED=301

# Repeat the workload and read SAIF into the matching mapped DDC.
make gate-saif-power CORNER=tt GATE_SEQ_Q=64 GATE_SEQ_KV=64 GATE_SAIF_SEED=301
```

The synthesis script checks the current structural contract:

- exactly 480 `uhdsp_256x8m4s` SRAM macros;
- 1,220 multiplier wrappers linked to 1,220 `DW02_mult` instances;
- zero pre-existing and zero tool-inserted ICGs;
- no generic `SNPS_CLOCK_GATE_HIGH_*` modules in the mapped netlist.

Each synthesis run produces mapped Verilog, DDC, SDC, SDF, SVF, and reports
under `asic/dc/work/synth/<corner>/system/attention_accel_top/`. Power Compiler
reports are stored below `asic/dc/work/power/reports/<rtl-hash>/<profile>/<corner>/`.

## Current Baseline

| Metric | Value |
| --- | ---: |
| target clock | 1.60 ns / 625 MHz |
| cell area | 2,438,964.94 library units |
| SRAM macros | 480 |
| mapped cells | 1,524,232 |
| dynamic power | 648.6251 mW |
| leakage power | 9.8584 mW |
| total power | 658.4835 mW |
| net switching power | 18.1893 mW |

The power run is a 64 x 64 random MHA prefill with seed 301 and 100% SAIF
annotation. Detailed conditions and paths are maintained in
`docs/ppa_and_optimization.md`.

## Libraries and Memory Mapping

Library selection is centralized in `asic/scripts/library_paths.sh`. The
default 32 x 32 x 64 top instantiates 480 byte-wide SRAM macros:

| Owner | Macro count |
| --- | ---: |
| Q/K/V ping-pong cache | 192 |
| persistent O banks | 256 |
| output buffer | 32 |
| total | 480 |

The current macro composition prioritizes a working, characterized library
binding. A later physical implementation should evaluate wider/deeper macros,
especially for the persistent O banks.

## Physical Implementation Entry Point

`make synth-physical` accepts an assembled Milkyway library and max/min TLU+
files. It is a separate implementation stage and is not required to reproduce
the current logical-synthesis and gate-SAIF baseline. Exact arguments are shown
by `make help`.

Internal chronological synthesis notes are retained in `docs/synth.md`; they
are engineering history rather than the contest-facing result table.
