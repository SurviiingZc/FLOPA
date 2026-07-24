# FLOPA: A Fully Local and Overlapped Probability-Stationary Systolic Accelerator for Flash Attention

FLOPA is a fixed-point FlashAttention accelerator RTL project. Its principal
design choice is to retain score, probability, row-state, and partial-output
state close to the 32 x 32 systolic processing-element (PE) fabric. This
avoids materializing a score/probability tile in an external scratchpad and
overlaps QK, online softmax, and WS-PV work at column or feature granularity.

The implementation supports fixed-tile MHA prefill and a single-token MHA
decode mode. It is a research RTL baseline, not an ASIC or FPGA sign-off
release. The name FLOPA is a working project name.

## Submission Documents

The contest-facing English documents are intentionally concentrated in
[`docs/`](docs/README.md):

| Document | Contents |
| --- | --- |
| [`docs/design_specification.md`](docs/design_specification.md) | Algorithm, numerical formats, architecture, buffers, interfaces, and dataflow |
| [`docs/register_and_interface_reference.md`](docs/register_and_interface_reference.md) | Complete AXI4-Lite register map, bit fields, programming rules, and top-level interface contracts |
| [`docs/ppa_and_optimization.md`](docs/ppa_and_optimization.md) | Resource/power/timing baseline, performance model, optimization evidence, and update protocol |
| [`docs/verification_report.md`](docs/verification_report.md) | Verification plan, test cases, coverage analysis, current results, and waveform capture placeholders |
| [`docs/submission_checklist.md`](docs/submission_checklist.md) | Requirement-to-evidence map and remaining delivery gaps |

The existing architecture and pipeline figures are referenced by the design
document and are available in `figures/architecture/` and `figures/pipeline/`
as PDF, SVG, PNG, and TIFF.

## Repository Layout

```text
rtl/                  Synthesizable Verilog, grouped by function.
  common/             Shared types, fixed-point constants, clock-gate wrapper.
  control/            AXI-Lite register file, scheduler, performance counter.
  axi/                AXI4-Lite slave and AXI4 master write engine.
  compute/            Fused PE array, QK/PV engines, scale and multiplier pipes.
  softmax/            PWL exp, reciprocal, and final online normalizer.
  memory/             Ping-pong Q/K/V cache, persistent O banks, output buffer.
tb/module_tb/         Directed, self-checking module and top-level SV testbenches.
tb/uvm/               UVM environment, agents, sequences, scoreboard, coverage,
                       and bit-accurate SystemVerilog reference model.
tb/sim/               Filelists and simulation scripts; generated builds go below build/.
asic/                 Design Compiler scripts, constraints, SRAM setup, SAIF flow,
                       and implementation-specific reports.
fpga/                 VCK190/Vivado integration collateral and board-test planning.
figures/              Source scripts plus publication-ready architecture/pipeline figures.
docs/                 Current contest-facing documentation and paper catalogue.
ppt/                  Slide-deck outline for the required defense presentation.
```

Generated simulation and synthesis outputs are intentionally excluded from
source control: `tb/sim/build/`, `asic/dc/work/`, and `asic/dc/logs/`.

## Reproduction Prerequisites

The verified flows expect a Linux EDA environment with:

- Synopsys VCS V-2023.12-SP2 or a compatible SystemVerilog/UVM simulator;
- Synopsys Design Compiler/Power Compiler V-2023.12-SP5 or compatible tools;
- the `/data/public` 28 nm TSMC standard-cell Liberty libraries and
  `uhdsp_256x8m4s` SRAM model/Liberty collateral;
- GNU Make, Bash, and standard Unix utilities.

The supplied top-level RTL uses a 128-bit `tile_load_*` integration interface
for Q/K/V ingress. A VCK190 build therefore needs an AXI DMA or an equivalent
AXI4-to-tile-loader wrapper on the input side; this wrapper is not an AXI read
master inside `attention_accel_top`.

## Reproduction Commands

Run commands from the repository root unless a command changes directory.
The commands below are provided for reproducibility; they are not run merely
by reading this document.

```bash
# Fast module/top-level regression. Module testbenches generate FSDB by default.
cd tb/sim
make syntax
make run
make asic-sram
make lint-rtl

# Full fixed-seed UVM regression and merged coverage report.
OUT_DIR=build/uvm_two_tile_random_pingpong scripts/run_uvm_regression.sh

# One focused UVM test.
cd ../..
make uvm-test UVM_TEST=fa_two_tile_pingpong_test UVM_SEED=301

# Nominal-corner RTL elaboration and complete synthesis.
make rtl-check CORNER=tt
make synth-system CORNER=tt CLOCK_PERIOD=1.6

# Frequency/fanout sweeps and activity-based power flow.
make synth-frequency-sweep CORNER=tt
make synth-fanout-sweep CORNER=tt
make gate-saif-power CORNER=tt GATE_SAIF_SEED=301
```

The current gate-level SAIF reference run uses a two-Q-tile/two-KV-tile random
prefill workload at 1.6 ns. Power, area, and timing numbers in this repository
are pre-layout characterization data, not post-route or silicon claims; see
[`docs/ppa_and_optimization.md`](docs/ppa_and_optimization.md).

## Supported Scope and Boundaries

| Capability | Current state |
| --- | --- |
| MHA prefill | Implemented; two 32-token Q/KV tiles have bit-exact UVM coverage |
| MHA decode | Implemented for one query and one 32-token KV tile; smoke/random/backpressure tested |
| Causal masking and tail masking | Implemented and tested |
| GQA | Rejected by START validation; planned extension |
| Q/K/V input from DDR | Requires external DMA/wrapper; not implemented as a top-level AXI read master |
| VCK190 bitstream and post-route PPA | Planned; not yet a deliverable result |
| Softmax approximation | PWL Q1.15 output with eight active intervals; the contest's ">16 precision" wording must be resolved before final submission |

## Evidence Integrity

All submitted numerical claims must identify the RTL revision, workload,
clock, process/voltage/temperature condition, tool version, and report path.
Current verified numerical correctness is limited to the documented 15-test
fixed-seed UVM suite. Current coverage is below the stated 95% code and 100%
functional-coverage targets, so neither closure is claimed.
