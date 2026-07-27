# PPA Baseline and Optimization Record

## 1. Reporting Policy

This document uses the latest reproducible synthesis and gate-activity data for
the current RTL. Every number is tied to a workload, tool version, PVT point,
clock period, and report path. The ASIC results are pre-layout estimates; they
are suitable for architectural comparison and contest reporting, but they are
not post-route or silicon measurements.

## 2. Current ASIC Baseline

| Item | Current result | Conditions |
| --- | ---: | --- |
| RTL top | `attention_accel_top` | 32 x 32 PEs, four 8 x 32 stripes, `HEAD_DIM=64` |
| Standard-cell library | TSMC 28 nm TT CCS | 0.9 V, 25 C |
| SRAM library | `uhdsp_256x8m4s_tt0p9v25c` | 480 instantiated macros |
| Tool | Design Compiler V-2023.12-SP5 | logical synthesis, `physical_aware=0` |
| Target clock | 1.60 ns | 625 MHz |
| Setup WNS / TNS / failing paths | 0.000 ns / 0.000 ns / 0 | no positive setup margin |
| Critical path | 1.49 ns, 60 logic levels | current mapped netlist |
| Total cell area | 2,438,964.94 library units | interconnect area is not included |
| Fused-array area | 2,048,222.41 (84.0%) | includes PE fabric and persistent O banks |
| Total cells | 1,524,232 | 1,281,371 combinational and 242,335 sequential |
| Buffer/inverter cells | 252,342 | pre-layout mapped count |
| SRAM macros | 480 | 192 Q/K/V cache, 256 persistent O, 32 output buffer |
| RTL/tool-inserted ICGs | 0 / 0 | current zero-ICG comparison baseline |

Primary synthesis evidence:

- `asic/dc/work/synth/tt/system/attention_accel_top/reports/qor.rpt`
- `asic/dc/work/synth/tt/system/attention_accel_top/reports/area.rpt`
- `asic/dc/work/synth/tt/system/attention_accel_top/reports/resources.rpt`
- `asic/dc/work/synth/tt/system/attention_accel_top/reports/run_config.rpt`

The synthesis uses `ZeroWireload`, so the reported area excludes routed
interconnect and the 625 MHz result must not be presented as post-route Fmax.

## 3. Gate-SAIF Power Baseline

The accepted power run executes `fa_random_qkv_test` with seed 301 on the
mapped 64 x 64 MHA prefill configuration. It loads two Q tiles and two K/V
tiles, uses full-range signed INT8 random operands, applies no AXI write
backpressure, and checks every output byte with the UVM reference model.

| Run field | Value |
| --- | --- |
| Simulator | VCS V-2023.12-SP2_Full64 |
| Power engine | Design Compiler Power Compiler V-2023.12-SP5 |
| Netlist | TT mapped `attention_accel_top`, zero ICG |
| Git / RTL identity | commit `89a6999`; RTL hash `9fa3552430ace318...` |
| Clock | 1.60 ns / 625 MHz |
| SAIF window | cycles 57 through 4336, 4,279 cycles / 6,846.4 ns |
| Functional result | `UVM_ERROR=0`, `UVM_FATAL=0` |
| Traffic result | Q/K/V load words 128/256/256; 256 output beats / 4,096 bytes |
| SAIF coverage | nets, ports, and pins all 100% user annotated |
| SDF mode | zero-delay mapped-cell activity run; no SDF annotation |

### 3.1 Power Summary

| Metric | Measured value | Share / interpretation |
| --- | ---: | --- |
| Cell internal power | 630.4358 mW | includes register clock-pin internal power |
| Net switching power | 18.1893 mW | activity-derived mapped-net switching |
| Total dynamic power | **648.6251 mW** | internal plus switching |
| Leakage power | **9.8584 mW** | TT library estimate |
| Total power | **658.4835 mW** | dynamic plus leakage |
| Clock-network internal power | 582.5795 mW | 88.51% of the grouped report |
| Gross sampled-job energy | 4.508 uJ | total power multiplied by the SAIF window |

`clock_network` shows zero net-switching power because this is a pre-layout
`ZeroWireload` model without a routed clock tree. Clock-pin activity is instead
reported as cell-internal power. The total net-switching result is not zero:
the top-level value is 18.1893 mW.

### 3.2 Hierarchical Power

| Hierarchy | Total power | Share |
| --- | ---: | ---: |
| `u_fused_array` | 620.086 mW | 94.2% |
| `u_tile_cache` | 13.983 mW | 2.1% |
| `u_normalizer` | 12.470 mW | 1.9% |
| `u_output_buffer` | 7.236 mW | 1.1% |
| `u_regfile` | 2.227 mW | 0.3% |

The fused-array number includes the clock load and persistent O-bank hierarchy;
it must not be interpreted as arithmetic-only power.

Power evidence:

- `asic/dc/work/power/saif/9fa3552430ace318dcc4a079834e44a99449b44441795fe57298cf35f3b0841a/gate_ungated_random_qkv_64x64_seed301.saif`
- `asic/dc/work/power/reports/9fa3552430ace318dcc4a079834e44a99449b44441795fe57298cf35f3b0841a/gate_ungated_random_qkv_64x64_seed301/tt/power_summary.rpt`
- `asic/dc/work/power/reports/9fa3552430ace318dcc4a079834e44a99449b44441795fe57298cf35f3b0841a/gate_ungated_random_qkv_64x64_seed301/tt/power_hierarchy.rpt`
- `asic/dc/work/power/reports/9fa3552430ace318dcc4a079834e44a99449b44441795fe57298cf35f3b0841a/gate_ungated_random_qkv_64x64_seed301/tt/saif_coverage.rpt`
- `tb/sim/build/saif_gate_ungated_random_qkv_64x64_seed301/fa_random_qkv_test.log`

## 4. Workload-Derived Performance

The 64 x 64 run contains four 32 x 32 Q/KV tile pairs. QK and PV each perform
one 64-term MAC for every output pair:

```text
4 tile pairs x 2 phases x 32 x 32 x 64 = 524,288 MACs
```

| Metric | Derived value | Qualification |
| --- | ---: | --- |
| Workload-average MAC rate | 122.53 MAC/cycle | complete load/compute/normalize/write window |
| Workload-average throughput | 76.58 GMAC/s | at the 625 MHz simulation clock |
| Theoretical PE-array peak | 1,024 MAC/cycle, 640 GMAC/s | excludes pipeline and control overhead |
| Gross energy efficiency | 8.60 pJ/MAC | 4.508 uJ / 524,288 MACs |

These are workload-derived metrics, not DDR-backed sustained throughput or
on-board measurements.

## 5. Architecture-Level Optimization Evidence

| Optimization | Implemented mechanism | Benefit |
| --- | --- | --- |
| Fused local dataflow | score, probability, row state, and partial O remain in or next to the PE stripes | avoids materializing full score/P tiles and removes global 32 x 32 result buses |
| Column-overlapped softmax | rowmax, reverse subtraction, 32-lane scale/PWL exp, and rowsum overlap | one score column can enter exp every cycle after pipeline fill |
| Probability-stationary WS-PV | P remains in each PE while feature-major V streams vertically | removes P reload and reuses the array for PV |
| Persistent feature-addressed O banks | partial O survives across KV tiles and is read by feature | eliminates repeated O preload between KV tiles |
| Ping-pong Q/K/V cache | inactive-bank refill overlaps active-bank execution | exposes external-loader latency for overlap |
| Mixed precision | signed INT8 Q/K/V, Q1.15 P/alpha, INT32 score/O/l, INT8 output | reduces operand storage and PE interconnect width |
| Pipelined nonlinear paths | score scaling, PWL exp, O rescale, reciprocal and output scaling carry valid/tag pipelines | sustains II=1 at the selected boundaries |
| SRAM backend separation | ASIC uses characterized macros; FPGA uses BRAM/URAM-compatible wrappers | preserves one logical memory contract across targets |

## 6. Remaining PPA Work

1. Complete the VCK190 implementation and report post-route Fmax, LUT/FF/DSP,
   BRAM/URAM use, DDR bandwidth, board power, and end-to-end model throughput.
2. Use physical placement, CTS, extracted parasitics, and a routed power flow to
   replace the pre-layout clock-network estimate.
3. Evaluate larger and better-shaped SRAM macros for the persistent O banks;
   the current 256 x 8 composition prioritizes availability over bit efficiency.
4. Re-evaluate phase-local clock gating only with a matched ungated/gated
   workload, mapped-netlist equivalence, and gate-level numerical regression.
5. Preserve the current 64 x 64 gate-SAIF run as the immutable comparison
   baseline for subsequent low-power experiments.

## 7. FPGA Result Template

| Metric | VCK190 result |
| --- | ---: |
| Post-route Fmax | TBD |
| LUT / FF | TBD |
| DSP | TBD |
| BRAM / URAM | TBD |
| PS-to-PL and PL-to-DDR bandwidth | TBD |
| Re10K attention throughput / speedup | TBD |
| LLM prefill throughput / speedup | TBD |
| Board dynamic power / energy per attention | TBD |

The FPGA row remains intentionally incomplete until the generated bitstream and
board measurements are available.

## 8. Baseline Record

| Date | RTL revision | Workload | Area | Dynamic / leakage / total power | Verification |
| --- | --- | --- | ---: | ---: | --- |
| 2026-07-27 | RTL hash `9fa3552430ace318...` | gate 64 x 64 random MHA prefill, seed 301 | 2,438,964.94 | 648.6251 / 9.8584 / 658.4835 mW | gate UVM error/fatal = 0; SAIF annotation = 100% |
