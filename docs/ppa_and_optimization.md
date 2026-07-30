# FLOPA PPA and Optimization Report

## 1. Reporting Policy

ASIC figures are mapped pre-layout estimates at the stated PVT and workload.
FPGA figures are routed timing and VCK190 board measurements. Throughput terms
are kept distinct: **PL core** is the RTL counter interval, **PL callback**
includes host conversion and transfer work, and **full prefill** includes the
entire model graph.

## 2. ASIC Area and Timing

| Item | Final estimate | Conditions |
| --- | ---: | --- |
| RTL top | `attention_accel_top` | 32 x 32 PEs, four stripes, `HEAD_DIM=64` |
| Standard-cell library | TSMC 28 nm TT CCS | 0.9 V, 25 C |
| SRAM library | `uhdsp_256x8m4s_tt0p9v25c` | 480 macros |
| Tool | Design Compiler V-2023.12-SP5 | logical synthesis |
| Target clock | 1.60 ns | 625 MHz |
| Setup WNS / TNS / failing paths | 0.000 ns / 0.000 ns / 0 | mapped netlist |
| Critical path | 1.49 ns, 57 logic levels | mapped netlist |
| Total cell area | **2,436,075.17** library units | interconnect excluded |
| Fused-array area | 2,047,098.32 (84.0%) | includes persistent O banks |
| Leaf cells | 1,518,837 | mapped QoR count |
| Combinational / sequential cells | 1,276,428 / 242,409 | mapped QoR counts |
| Buffer/inverter cells | 250,507 | pre-layout count |
| SRAM macros | 480 | 192 Q/K/V, 256 O-bank, 32 output |

Primary reports are below
`asic/dc/work/synth/tt/system/attention_accel_top/reports/`. ZeroWireload is
used, so 625 MHz is a synthesis target, not a routed ASIC Fmax.

The synthesis-local `power.rpt` uses default vectorless activity and reports
594.6547 mW total. It is a diagnostic estimate and does not replace the
workload-annotated gate-SAIF result in Section 3.

## 3. Gate-SAIF Power

`fa_random_qkv_test` runs a 64 x 64 random MHA prefill with seed 301 on the
mapped netlist. The 1.60 ns activity window spans cycles 57 through 4336
(4,279 cycles, 6.8464 us), loads Q/K/V as 128/256/256 128-bit words, writes
4,096 output bytes, achieves 100% SAIF annotation, and ends with zero UVM
errors/fatals.

| Metric | Value |
| --- | ---: |
| Cell internal power | 630.4358 mW |
| Net switching power | 18.1893 mW |
| Dynamic power | **648.6251 mW** |
| Leakage power | **9.8584 mW** |
| Total power | **658.4835 mW** |
| Clock-related cell internal power | 582.5795 mW |
| Sampled-job energy | 4.508 uJ |

The clock contribution appears mainly as cell-internal power because the
pre-layout model has no routed clock tree. The top-level net-switching result
is 18.1893 mW and must not be reported as zero.

| Hierarchy | Total power | Share |
| --- | ---: | ---: |
| `u_fused_array` | 620.086 mW | 94.2% |
| `u_tile_cache` | 13.983 mW | 2.1% |
| `u_normalizer` | 12.470 mW | 1.9% |
| `u_output_buffer` | 7.236 mW | 1.1% |
| `u_regfile` | 2.227 mW | 0.3% |

The fused-array number includes local registers and persistent O-bank memory;
it is not arithmetic-only power.

## 4. ASIC Throughput and Efficiency

The sampled job contains four 32 x 32 Q/KV tile pairs. Counting QK and PV:

```text
4 tile pairs x 2 phases x 32 x 32 x 64 = 524,288 MACs
```

| Metric | Value | Convention |
| --- | ---: | --- |
| Average issue rate | 122.53 MAC/cycle | complete sampled window |
| Average throughput | 76.58 GMAC/s | 625 MHz |
| Operations throughput | 153.16 GOPS | 1 MAC = 2 operations |
| Peak array rate | 1,024 MAC/cycle | excludes fill/control overhead |
| Energy per MAC | 8.60 pJ/MAC | 4.508 uJ / 524,288 |
| Energy efficiency | 0.233 TOPS/W | 153.16 GOPS / 658.4835 mW |

The efficiency uses total power and the 2-operations-per-MAC convention. It is
not DDR-backed sustained system throughput.

## 5. FPGA Implementation

| Item | VCK190 result |
| --- | ---: |
| Platform/toolchain | `xilinx_vck190_base_202310_1`, Vivado/Vitis 2023.1 |
| Routed PL clock | **170.019 MHz** (5.882 ns) |
| Setup WNS / TNS | **0.012 / 0.000 ns** |
| Deterministic smoke | 2/2 pass; 2,942 cycles; 0 stalls; 0 errors |
| Board power | not measured |

| Routed system resource | Used | Available | Utilization |
| --- | ---: | ---: | ---: |
| LUT | 294,718 | 899,840 | 32.75% |
| FF | 295,111 | 1,799,680 | 16.40% |
| BRAM tile | 6.5 | 967 | 0.67% |
| URAM | 96 | 463 | 20.73% |
| DSP58 | 1,220 | 1,968 | 61.99% |

The `u_attention` hierarchy uses 291,543 LUTs, 292,728 FFs, four RAMB36
blocks, 96 URAMs, and 1,220 DSP58s. Reports are versioned at
`fpga/vivado/build/reports/`. The binary `power_1.rpx` also records a Vivado
estimate, but no measured board power is available and the methodology report
shows that RAM activity used a default assumption.

### 5.1 SmolLM2-135M-Instruct

The board benchmark uses batch-1 Q8_0 SmolLM2 with 30 layers, 9 Q heads,
3 KV heads, head dimension 64, and two Cortex-A72 threads. The host expands
three KV heads to nine for the MHA hardware interface.

| Sequence | PS prefill | PS+PL prefill | Full speedup | PS Attention | PL callback | Callback speedup | PL core | Core speedup |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 64 | 1582.633 ms | 1570.297 ms | **1.008x** | 92.342 ms | 65.511 ms | **1.410x** | 4.673 ms | **19.762x** |
| 1024 | 30178.154 ms | 25476.343 ms | **1.185x** | 6369.045 ms | 1648.075 ms | **3.865x** | 679.180 ms | **9.378x** |

Sequence 64 and 1024 produce matching token hashes/top-1 outputs between PS
and PS+PL paths. Each final result contains one measured repetition after a
warmup; repeat measurements are required for confidence intervals.

At sequence 64, quantization/packing/GQA expansion consumes 47.189 ms and
output conversion 11.439 ms. At sequence 1024, the same phases consume
777.785 ms and 188.388 ms. These measured software envelopes explain why the
full-model speedup is smaller than the PL-core speedup.

## 6. Implemented Optimizations

| Optimization | Hardware mechanism | Effect |
| --- | --- | --- |
| Fused local dataflow | score, P, row state, and partial O stay in/next to PE stripes | removes global score/P tile movement and very wide result buses |
| Column-overlapped softmax | rowmax, reverse subtraction, 32-lane exp, and rowsum overlap | accepts one completed score column per cycle after fill |
| Probability-stationary WS-PV | P remains in the PEs; feature-major V streams vertically | removes P reload and reuses the array for PV |
| Persistent O banks | partial O is feature-addressed and retained across KV tiles | eliminates repeated O preload |
| Ping-pong Q/K/V cache | inactive-bank refill overlaps active-bank execution | hides mover latency when compute slack is available |
| Mixed precision | INT8 Q/K/V, Q1.15 P/alpha, INT32 state | narrows storage, PE multipliers, and array wiring |
| Pipelined nonlinear arithmetic | scale, PWL exp, O rescale, reciprocal, and normalizer carry valid/tag | avoids long combinational chains while sustaining II=1 |
| Target-specific memory backend | SRAM macros for ASIC, BRAM/URAM-compatible wrappers for FPGA | preserves a common logical contract |

## 7. Remaining Optimizations

1. Add native GQA or on-chip KV multicast to remove software KV duplication.
2. Fuse quantization, packing, projection layout, and output conversion or move
   them into PL.
3. Improve K/V reuse across Q tiles and add DDR/cache-credit counters before
   increasing buffering.
4. Measure board power and complete the Re10K workload.
5. Run routed ASIC placement, CTS, extraction, and power analysis, then
   evaluate wider/deeper SRAM macros for persistent O banks.

## 8. Result Record

| Date | Workload | Area | Dynamic / leakage / total | Verification |
| --- | --- | ---: | ---: | --- |
| 2026-07-30 | 64 x 64 gate MHA, seed 301 | 2,436,075.17 | 648.6251 / 9.8584 / 658.4835 mW | zero gate UVM errors/fatals; 100% SAIF |
| 2026-07-30 | VCK190 SmolLM2 seq64/1024 | 294,718 LUT / 295,111 FF / 1,220 DSP58 | board power not measured | 170.019 MHz timing met; matching tokens; smoke 2/2 |
