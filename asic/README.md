# ASIC Synthesis

The default synthesis corner is the 28 nm TT 0.9 V, 25 C CCS standard-cell
library with the matching TT SRAM macro. The SS 0.9 V, 125 C corner remains
available for timing stress checks.

Run all commands from the repository root. `make synth-list` prints the current
module groups and `make help` prints the supported flows. The normal entry points
are:

```text
make rtl-check
make synth-module TOP=fsa_fused_pe
make synth-compute
make synth-system
make synth-all
make synth-frequency-sweep
```

Override constraints on the command line, for example:

```text
make synth-system CORNER=tt CLOCK_PERIOD=2.5 DC_CORES=8
```

The initial ASIC optimization target is 400 MHz (2.5 ns). Use
`make synth-frequency-sweep` to generate `summary.csv` and `best_passing.csv`
without writing a mapped netlist or multi-gigabyte SDF at every period. TT is a
logic-limit estimate; SS and physical-aware results determine the usable target.

Setup and hold uncertainty are independent. The defaults are 0.100 ns and
0.020 ns, and non-clock SRAM inputs receive a 0.200 ns minimum-path constraint.
These constraints guide DC hold buffering but do not replace post-CTS hold
analysis with propagated clocks.

Physical-aware synthesis uses DC Graphical SPG and requires a prepared Milkyway
design library containing both standard-cell FRAM views and the SRAM abstract:

```text
make physical-config
make synth-physical CORNER=ss CLOCK_PERIOD=2.5 \
  FA_MW_LIB=/path/to/combined_design_mw \
  FA_TLUPLUS_MAX=/path/to/max.tluplus \
  FA_TLUPLUS_MIN=/path/to/min.tluplus \
  FA_TLUPLUS_MAP=/path/to/tech2itf.map
```

The server has standard-cell Milkyway/LEF, SRAM LEF/GDS, and 28 nm RC source
collateral, but those views must be assembled into the combined physical library
before the SPG result is treated as placement-aware.

Generated data is isolated below `asic/dc/work/` and logs below
`asic/dc/logs/`; both are ignored by Git. Each synthesized top produces timing,
QoR, hierarchical area, power, constraint, resource, reference, and library
reports plus mapped Verilog, DDC, SDC, and SDF results.

`asic/filelists/rtl.f` is a repository-root-relative source list for auxiliary
lint/elaboration tools. DC uses the matching checked source list in
`asic/scripts/rtl_sources.tcl`.

The top-level macro-count guard expects 480 `uhdsp_256x8m4s` instances for the
default 32x32, head-dimension-64 configuration: 192 in Q/K/V ping-pong caches,
256 in persistent O banks, and 32 in the output buffer.

Synthesis findings and optimization status are maintained in `docs/synth.md`.
