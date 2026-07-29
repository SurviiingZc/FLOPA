# FLOPA: Fully Local and Overlapped Probability-Stationary Attention

FLOPA is a fixed-point FlashAttention accelerator that fuses QK, online
softmax, and PV on a 32 x 32 systolic array. Scores, probabilities, row state,
and partial output remain local to the compute fabric; the design therefore
avoids round trips through a global score/probability scratchpad and overlaps
the major attention phases.

The final RTL supports tiled MHA prefill, causal masking, and single-query MHA
decode. A complete VCK190 path replaces the Attention nodes of
SmolLM2-135M-Instruct and has been measured on board.

## Design Point

| Item | Final implementation |
| --- | --- |
| Compute fabric | 32 x 32 fused PEs in four 8 x 32 stripes |
| Head dimension | 64 |
| Arithmetic | signed INT8 Q/K/V and output, unsigned Q1.15 P/alpha, INT32 state |
| Softmax parallelism | 32 score-scale/PWL-exp lanes |
| Dataflow | output-stationary QK, column-overlapped online softmax, probability-stationary WS-PV |
| Local storage | PE-local score/P, persistent feature-addressed O banks, ping-pong Q/K/V cache |
| Control/input/output | AXI4-Lite, 128-bit tile loader, 128-bit AXI4 write master |
| Runtime modes | MHA prefill and single-query multi-KV-tile MHA decode |

![FLOPA overall architecture](figures/flopa_overall_architecture.png)

## Final Results

### ASIC estimate

The 28 nm TT, 0.9 V, 25 C synthesis target is 1.60 ns (625 MHz). The final
area estimate is **2,438,948.64 library units** with 480 SRAM macros. A
64 x 64 mapped-netlist `fa_random_qkv_test` run achieved 100% SAIF annotation
and zero UVM errors/fatals.

| Gate-SAIF metric | Value |
| --- | ---: |
| Cell internal power | 630.4358 mW |
| Net switching power | 18.1893 mW |
| Dynamic power | **648.6251 mW** |
| Leakage power | **9.8584 mW** |
| Total power | **658.4835 mW** |
| Workload throughput | 76.58 GMAC/s (153.16 GOPS at 2 ops/MAC) |
| Energy efficiency | 8.60 pJ/MAC, 0.233 TOPS/W |

These are mapped, pre-layout estimates. Exact workload and reporting
conventions are defined in [PPA and Optimization](docs/ppa_and_optimization.md).

### VCK190 board result

The routed design operates at **170 MHz** on an AMD VCK190. The final board
smoke test passed twice with 2,942 accelerator cycles, zero stall cycles, and
zero errors. SmolLM2-135M-Instruct uses two Cortex-A72 threads and software
GQA-to-MHA expansion for the current MHA hardware interface.

| Sequence | Attention-core speedup | Callback speedup | Full-prefill speedup |
| ---: | ---: | ---: | ---: |
| 64 | **19.762x** | 1.410x | 1.008x |
| 1024 | **9.378x** | 3.865x | 1.185x |

PS conversion and packing dominate the short-sequence callback; native GQA,
layout fusion, and reducing repeated external K/V traffic are the principal
next integration optimizations. Board power and Re10K measurements remain to
be collected.

## Result Locations

| Result | Repository path |
| --- | --- |
| Design Compiler configuration, QoR, area, resource, timing, and check reports | `asic/dc/work/synth/tt/system/attention_accel_top/reports/` |
| ASIC PPA and gate-SAIF interpretation | `docs/ppa_and_optimization.md` |
| FPGA board evaluation report | `fpga/docs/final_report_material.md` |
| Sequence-64/1024 raw FPGA JSON, logs, and hashes | `fpga/model/results/` |
| Generated Vivado/Vitis release reports | `fpga/vitis/build/reports/release-20260729/` |

The compact DC `reports/` trees are intentionally allowed by `.gitignore` so
accepted synthesis evidence can be versioned. DDC/netlist/SDF, simulator,
waveform, SAIF, and general EDA work products remain ignored.

## Documentation

| Document | Purpose |
| --- | --- |
| [Technical Report](docs/design_specification.md) | algorithm, architecture, storage, dataflow, and final results |
| [Register and Interface Reference](docs/register_and_interface_reference.md) | register table, interfaces, protocols, and programming sequence |
| [PPA and Optimization](docs/ppa_and_optimization.md) | ASIC/FPGA PPA, throughput, power, and optimization analysis |
| [Verification Report](docs/verification_report.md) | regression, coverage, gate workload, and waveform guidance |
| [RTL Code Guide](docs/rtl.md) | implementation walkthrough from top level to each datapath |
| [Submission Checklist](docs/submission_checklist.md) | competition requirement traceability and packaging status |
| [FPGA Evaluation](fpga/docs/final_report_material.md) | reproducible VCK190 and SmolLM2 measurements |

## Repository Layout

```text
rtl/                  Synthesizable RTL.
  common/             Constants, pipelined arithmetic, and timing helpers.
  control/            Register file, scheduler, controller, and counters.
  axi/                AXI4-Lite control and AXI4 writeback.
  compute/            Fused PE/stripe, QK/PV engines, and scale pipeline.
  softmax/            PWL exponential, reciprocal, and final normalizer.
  memory/             Ping-pong cache, persistent O banks, output buffer.
tb/module_tb/         Directed self-checking module tests with default FSDB.
tb/uvm/               UVM agents, tests, reference model, and coverage.
tb/sim/               Simulation Makefile, filelists, and coverage scripts.
asic/                 DC/Power Compiler scripts, constraints, and SRAM setup.
fpga/                 VCK190 Vivado/Vitis flow, host code, model tests, results.
figures/              Maintained architecture and dataflow figures.
docs/                 Contest-facing reports and implementation references.
ppt/                  Defense presentation outline.
```

Generated simulation and EDA work directories are excluded from the source
package. Raw board JSON/log evidence under `fpga/model/results/` is retained.

## Reproduction

Prerequisites are VCS V-2023.12-SP2 or compatible, Design Compiler/Power
Compiler V-2023.12-SP5, Vivado/Vitis 2023.1 for VCK190, GNU Make, and the
28 nm libraries configured below `/data/public`.

Run from the repository root:

```bash
# Directed checks and the final 21-run UVM regression.
make -C tb/sim syntax
make -C tb/sim run
make -C tb/sim asic-sram
make uvm-regression

# One configurable UVM workload.
make uvm-test UVM_TEST=fa_random_qkv_test \
  UVM_SEQ_Q=64 UVM_SEQ_KV=64 UVM_SEED=301

# ASIC synthesis, equivalence, and mapped-netlist power.
make synth CORNER=tt CLOCK_PERIOD=1.6
make formality CORNER=tt
make gate-saif-power CORNER=tt GATE_SEQ_Q=64 GATE_SEQ_KV=64 \
  GATE_SAIF_SEED=301
```

For the FPGA build and board run, follow [fpga/vitis/README.md](fpga/vitis/README.md)
and [fpga/model/README.md](fpga/model/README.md). The Vitis collateral retains
the legacy `dit_fa_*` filename prefix; it identifies FLOPA artifacts and does
not denote a second architecture.

## Verification Status

All 21 fixed-seed UVM runs pass with zero errors/fatals. Functional coverage is
100.00%; raw full merged coverage is 95.66%, raw `tb_top` coverage is 95.01%,
and reviewed DUT-scoped coverage is 96.00%. Directed module coverage completes
23/23 jobs. Prefill is checked through 512 x 512 and MHA decode through one
query by 256 KV tokens.

## Current Boundaries

- The RTL input boundary is a 128-bit tile-loader stream; the VCK190 design
  supplies the external mover/DMA wrapper.
- Native GQA is not implemented. The board host expands three model KV heads
  to nine MHA heads before transfer.
- FPGA board power and Re10K board results are not yet measured.
- ASIC figures are synthesis/gate-activity estimates, not placed-and-routed or
  silicon measurements.
