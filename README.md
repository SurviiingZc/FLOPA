# FLOPA: Fully Local and Overlapped Probability-Stationary Attention

FLOPA is a fixed-point FlashAttention accelerator that keeps score,
probability, row state, and partial output close to a 32 x 32 fused systolic PE
fabric. QK, column-streamed online softmax, and probability-stationary WS-PV
reuse the same array without materializing full score or probability tiles in a
global scratchpad.

The current RTL supports tiled MHA prefill and single-query MHA decode. It is a
research implementation baseline rather than a post-route ASIC or FPGA release.

## Current Design Point

| Item | Current implementation |
| --- | --- |
| PE fabric | 32 x 32 PEs organized as four 8 x 32 stripes |
| Head dimension | 64 features |
| Arithmetic | signed INT8 Q/K/V, unsigned Q1.15 P/alpha, INT32 state, INT8 output |
| Softmax parallelism | 32 scale/PWL-exp lanes, one complete score column per cycle after fill |
| Data reuse | PE-local score/P, persistent feature-addressed O banks, Q/K/V ping-pong cache |
| External control | AXI4-Lite slave |
| Bulk input | 128-bit tile-loader interface; external DMA/adapter required |
| Output | 128-bit AXI4 write master |
| Supported modes | MHA prefill, causal masking, single-query multi-KV-tile MHA decode |
| Deferred mode | native GQA |

[View the current FLOPA architecture figure (PDF)](figures/flopa_overall_architecture.pdf)

## Measured Baseline

The latest ASIC estimate uses the 28 nm TT 0.9 V, 25 C libraries at a 1.60 ns
target clock. The mapped design contains 480 SRAM macros and has a total cell
area of 2,438,964.94 library units. A 64 x 64 random mapped-netlist UVM run
produced 100% SAIF annotation and zero UVM errors/fatals.

| Gate-SAIF power metric | Value |
| --- | ---: |
| Cell internal | 630.4358 mW |
| Net switching | 18.1893 mW |
| Total dynamic | **648.6251 mW** |
| Leakage | **9.8584 mW** |
| Total | **658.4835 mW** |

These values are activity-based pre-layout estimates. Full conditions and
artifact paths are recorded in [PPA and Optimization](docs/ppa_and_optimization.md).

## Documentation

| Document | Purpose |
| --- | --- |
| [Design Specification](docs/design_specification.md) | architecture, algorithms, formats, memory organization, and dataflow |
| [Register and Interface Reference](docs/register_and_interface_reference.md) | register table, bit fields, protocols, and programming sequence |
| [PPA and Optimization](docs/ppa_and_optimization.md) | current area, timing, power, performance, and optimization evidence |
| [Verification Report](docs/verification_report.md) | 21-run regression, raw/waived code coverage, functional coverage, and waveform plan |
| [Submission Checklist](docs/submission_checklist.md) | requirement-to-evidence and packaging checklist |
| [RTL Code Guide](docs/rtl.md) | detailed Chinese implementation walkthrough |
| [Synthesis Notes](docs/synth.md) | internal synthesis and implementation history |

## Repository Layout

```text
rtl/                  Synthesizable Verilog RTL.
  common/             Constants, multiplier pipes, delay/clear helpers.
  control/            Register file, scheduler, controller, counters.
  axi/                AXI4-Lite slave and AXI4 write master.
  compute/            Fused PE, stripes, QK/PV engines, scale pipeline.
  softmax/            PWL exponential, reciprocal, final normalizer.
  memory/             Ping-pong cache, persistent O banks, output buffer.
tb/module_tb/         Directed self-checking testbenches with default FSDB.
tb/uvm/               UVM agents, tests, model, scoreboard, and coverage.
tb/sim/               Simulation Makefile, filelists, and scripts.
asic/                 DC/Power Compiler scripts, constraints, SRAM setup.
fpga/                 VCK190 integration collateral and model test plan.
figures/              Maintained architecture and pipeline figures.
docs/                 Submission documents and engineering references.
ppt/                  Defense presentation outline.
```

Generated outputs live below `tb/sim/build/`, `asic/dc/work/`, and
`asic/dc/logs/` and are not part of the source package.

## Tool Prerequisites

- Synopsys VCS V-2023.12-SP2 or a compatible SystemVerilog/UVM simulator;
- Synopsys Design Compiler/Power Compiler V-2023.12-SP5;
- `/data/public` TSMC 28 nm standard-cell and `uhdsp_256x8m4s` SRAM libraries;
- GNU Make, Bash, and standard Unix utilities.

## Reproduction

Run from the repository root:

```bash
# Directed RTL and SRAM-model checks.
make -C tb/sim syntax
make -C tb/sim run
make -C tb/sim asic-sram
make -C tb/sim lint-rtl

# Complete 21-run UVM regression and raw/waived merged coverage.
make uvm-regression

# One configurable UVM workload.
make uvm-test UVM_TEST=fa_random_qkv_test \
  UVM_SEQ_Q=64 UVM_SEQ_KV=64 UVM_SEED=301

# Current TT mapped baseline and equivalence proof.
make synth CORNER=tt CLOCK_PERIOD=1.6
make formality CORNER=tt

# Current mapped-netlist SAIF and Power Compiler readback.
make gate-saif-power CORNER=tt GATE_SEQ_Q=64 GATE_SEQ_KV=64 \
  GATE_SAIF_SEED=301
```

## Verification Status

The recorded VCS regression contains 21 fixed-seed runs. All 21 pass with zero
UVM errors and fatals. Functional coverage is 100.00%; the raw `tb_top` score is
95.01% and the reviewed DUT-scoped score is 96.00%. Waived module-definition
line and branch coverage reach 95.23% and 97.61%. The aggregate code-coverage
target is met; remaining condition/toggle gaps are classified in the verification
report and remain visible in the raw report. The latest
64 x 64 mapped-netlist power workload also passes byte-exact checking.

## Integration Boundaries

- The top-level does not contain an AXI read master. VCK190 integration needs an
  AXI DMA or custom adapter that drives `tile_load_*` and `tile_commit_*`.
- Native GQA is rejected at START; software KV-head expansion is only an FPGA
  experiment option, not a native RTL feature.
- FPGA post-route utilization, timing, bandwidth, model throughput, and board
  power remain to be measured.
