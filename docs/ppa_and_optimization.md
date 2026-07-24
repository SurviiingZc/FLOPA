# PPA Baseline and Optimization Record

## 1. Reporting Policy

This document reports the latest available implementation evidence without
promoting pre-layout estimates to sign-off data. Every future PPA entry must
record RTL revision, test workload, tool version, PVT, clock period,
constraints, and report path. A new result replaces a baseline only after the
associated functional test passes.

The current numbers are a **28 nm TT logical-synthesis and gate-SAIF baseline**.
They are useful for design comparison and for showing optimization direction,
but do not establish post-route Fmax, FPGA timing closure, board power, or ASIC
sign-off.

## 2. Current Implementation Baseline

| Item | Value | Conditions / interpretation |
| --- | ---: | --- |
| RTL top | `attention_accel_top` | 32 x 32 PEs, four 8 x 32 stripes, 64 features |
| Standard-cell library | TSMC 28 nm `tcbn28hpcplus...tt0p9v25c_ccs` | 0.9 V, 25 C, typical corner |
| SRAM model | `uhdsp_256x8m4s_tt0p9v25c` | 480 instantiated macros in this configuration |
| Target period | 1.60 ns | 625 MHz target; logical-only result |
| Setup WNS/TNS/failing paths | 0.000 ns / 0.000 ns / 0 | passes with no setup margin |
| Worst hold / hold TNS / failing paths | -0.0953 ns / -403.35 ns / 5,923 | open issue; not timing clean |
| Critical path | 58 levels, 1.4918 ns | normalizer accumulator-to-reciprocal multiplier cone |
| Design area | 2,429,697.55 library area units | excludes routed interconnect/core utilization |
| Fused array area | 2,038,750.40 (83.9%) | principal area optimization target |
| SRAM macro area | 656,746.70 (27.0%) | logical macro area in the synthesis report |
| Leaf cells | 1,515,587 | includes 240,584 sequential cells |
| Buffer/inverter cells | 250,647 | indicates substantial physical/control distribution work remains |
| DRCs | 1 max-fanout violation; zero max-transition/cap violations | report also identifies 16 high-fanout nets in timing analysis |

Sources:

- `asic/dc/work/synth/tt/system/attention_accel_top/reports/qor.rpt`
- `asic/dc/work/synth/tt/system/attention_accel_top/reports/area.rpt`
- `asic/dc/work/synth/tt/system/attention_accel_top/reports/timing.rpt`
- `asic/dc/work/synth/tt/system/attention_accel_top/reports/timing_min.rpt`

The run uses zero-wireload/pre-layout assumptions and `physical_aware=0`.
Neither its zero setup slack nor its derived 625 MHz target may be used as a
claim that the design can run at that frequency after placement and routing.

## 3. Activity-Based Power Baseline

The gate-level SAIF run uses `fa_two_tile_pingpong_test`, seed 301, with random
Q/K/V data, two Q tiles, two KV tiles, no AXI writeback stalls, and max SDF.
The capture window is cycles 41 to 4321, or 4,280 cycles / 6,848 ns at 1.6 ns.
All nets, ports, and pins in the target hierarchy were user annotated.

| Power metric | Value | Qualification |
| --- | ---: | --- |
| Total power | 1.9032 W | pre-route, gate-SAIF estimate |
| Dynamic power | 1.8932 W | activity-derived, not board-measured |
| Leakage power | 9.9848 mW | TT library estimate |
| Clock network | 1.8325 W (96.29%) | dominates because mapped ICG count is zero |
| Combinational | 37.7293 mW (1.98%) | includes active data paths |
| Registers | 16.7061 mW (0.88%) | excludes clock contribution listed above |
| Memories | 16.2513 mW (0.85%) | functional macro model/activity estimate |
| Sampled job energy | 13.033 uJ | gross energy for the 2 x 2 prefill job |

The hierarchy report identifies `u_fused_array` as 1.61 W (84.6%),
`u_output_buffer` as 164.435 mW (8.6%), and `u_normalizer` as 101.115 mW
(5.3%). These values include the clock network below each block and must not
be interpreted as data-path-only power.

Source: `asic/docs/gate_saif_power_report.md`, with detailed artifacts under
`asic/dc/work/power/` and
`tb/sim/build/saif_gate_fa_two_tile_pingpong_random_seed301/`.

### 3.1 Derived Workload Metrics

The two-Q-tile/two-KV-tile job executes four 32 x 32 QK tiles and four 32 x 32
PV tiles. The arithmetic count is therefore:

```text
4 tile pairs x 2 phases x 32 x 32 x 64 = 524,288 INT8 MACs
```

This derives a workload average of 122.5 MAC/cycle and 76.6 GMAC/s at the
1.6 ns simulation clock. The gross energy corresponds to approximately
24.9 pJ/MAC. These are workload-derived provisional values, not hardware
performance-counter measurements and not a sustained DDR-backed throughput
claim. The theoretical array bound is 1,024 MAC/cycle, or 640 GMAC/s at 625
MHz, before pipeline, memory, and control overhead.

## 4. Architecture-Level Optimization Evidence

| Optimization | Implementation evidence | Expected benefit | Current evidence / status |
| --- | --- | --- | --- |
| Local fused QK-softmax-PV dataflow | `fsa_fused_array.v` retains score, delta, and P in PE-local state | removes full-tile score/P traffic and global wide buses | implemented; needs post-route congestion comparison |
| Online row state | PE rowmax, reverse `m_new`, rowsum, streamed `l` update | no materialized score/P matrix; supports KV blocking | implemented and exercised in 2 x 2 UVM oracle |
| Probability-stationary WS-PV | `prob_q` remains in each PE while `V[:,d]` streams vertically | reuses P without a reload; arrays pipeline by feature | implemented and tested with tag-alignment checks |
| Persistent O bank | stripe-local `O_old` read, alpha rescale, direct tagged writeback | eliminates non-first-KV O preload | implemented; storage/timing still need physical closure |
| Q/K/V ping-pong | two banks per tensor with phase-aware consume/refill | overlaps computation and tile refill | bank0/1 and writeback-refill covered by UVM |
| Mixed precision | INT8 Q/K/V, Q1.15 P/alpha, INT32 score/L/O, INT8 output | reduces storage and MAC/link width | implemented; numerical behavior checked against bit-exact SV model |
| Pipeline partitioning | scale/PWL, O-rescale, normalizer multiplier stages | shortens long multiply/control cones while preserving II=1 | implemented; nominal setup is still at zero margin |
| Parameterized implementation | width/geometry parameters and runtime sequence/head registers | supports controlled elaboration variants | fixed 32 x 32 x 64 remains the verified physical point |
| ASIC clock-gate abstraction | `fa_clock_gate` wrappers in array, normalizer, output buffer | intended clock-power reduction | RTL present, but latest mapped report shows zero ICG cells; **open** |

## 5. PPA Closure Plan

### 5.1 Timing and Hold

1. Run physical-aware synthesis, CTS, and routed min/max STA with fast cells,
   fast SRAM Liberty, min RC, propagated clocks, OCV, and extracted parasitics.
2. Repair the register-to-SRAM early paths using legal cell delay insertion,
   useful skew, or local retiming based on physical min-delay analysis. Do not
   insert arbitrary RTL delay chains merely to silence a logical hold report.
3. Split or retime the normalizer critical cone only if the physical max path
   remains limiting after real interconnect is available.
4. Repeat gate simulation with timing checks enabled; `+no_notifier` is not a
   hold-closure substitute.

### 5.2 Clock Power

1. Determine why the current mapped netlist contains no clock-gating elements
   despite the RTL clock-gate abstraction and enabled synthesis setting.
2. Constrain and preserve legal ICG inference, including test-enable behavior,
   then verify `report_clock_gating` on the mapped design.
3. Compare idle, random prefill, and decode SAIF workloads. Report gated-clock
   activity and functional behavior under reset, drain, and backpressure.
4. Do not claim clock-power savings until a matched ungated/gated comparison
   uses identical workload, PVT, netlist stage, and power settings.

### 5.3 FPGA PPA Placeholder

| FPGA metric | Current value | Required final evidence |
| --- | --- | --- |
| Device | VCK190 / VC1902 target | Vivado project and exact part/speed grade |
| PL Fmax | TBD | post-route timing summary, WNS/TNS, clock uncertainty |
| LUT/FF/DSP/BRAM/URAM | TBD | post-route utilization report and RAM/DSP inference evidence |
| Board power | TBD | measured rail or approved board-monitor method, workload and temperature |
| Bandwidth | TBD | DMA/NoC counters for input, output, and sustained kernel operation |
| End-to-end throughput | TBD | PS-only, PL-kernel-only, and PS+PL E2E results for the same model inputs |

## 6. Result Update Template

Append, rather than overwrite, each accepted run in this table.

| Revision/date | Platform and PVT | Workload | Frequency | Area/resources | Power | Timing | Functional status | Report paths |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-07-23 baseline | 28 nm TT, 0.9 V, 25 C; pre-layout | gate 2 x 2 random prefill, seed 301 | 1.60 ns target | 2,429,697.55 library units; 480 SRAM macros | 1.9032 W | setup 0.000 ns; hold -0.0953 ns | UVM error/fatal = 0 | `asic/dc/work/...`, `asic/docs/gate_saif_power_report.md` |
| Future FPGA run | VCK190 | specify layer/model/sequence | TBD | TBD | TBD | TBD | required | link report/log |
| Future ASIC physical run | specify corner/RC/OCV | specify SAIF | TBD | TBD | TBD | required | required | link report/log |

## 7. Submission Interpretation

The design already demonstrates the architectural bonus directions: configurable
compile-time structure, high data reuse, quantization, ping-pong buffering,
and an automated randomized verification environment. It must not yet claim
VCK190 deployment, closed clock gating, physical hold closure, or final FPGA
PPA. The softmax contest requirement is already met: 32 score-scale/PWL-exp
lanes evaluate a full 32-element score column in parallel, exceeding the
required parallelism of 16. Q1.15 and the eight PWL intervals are numerical
implementation choices, not an unfulfilled contest precision requirement.
