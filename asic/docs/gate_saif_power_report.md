# Gate SAIF Power and Synthesis Review

## Run status

This report records a gate-level activity power run of the TT mapped
`attention_accel_top` netlist. It is an implementation optimization baseline,
not a post-route timing or power sign-off result.

| Item | Result |
| --- | --- |
| Workload | `fa_two_tile_pingpong_test`, random Q/K/V, seed 301, two Q tiles and two KV tiles, no AXI write backpressure |
| Gate simulation | VCS V-2023.12-SP2 with the TT mapped netlist, SRAM functional model, and max SDF |
| PVT and clock | TT, 0.9 V, 25 C, 1.6 ns (625 MHz) |
| SAIF window | cycle 41 through 4321; 4280 cycles; 6848 ns |
| Functional result | UVM error = 0, UVM fatal = 0; 256 output beats, 4096 output bytes |
| SAIF annotation | nets 1,612,983 / 1,612,983, ports 495 / 495, pins 5,999,481 / 5,999,481; all 100% user annotated |
| Total power | 1.9032 W = 1.8932 W dynamic + 9.9848 mW leakage |
| Energy in sampled job | 13.033 uJ gross for the 6848 ns two-tile job |

Artifacts:

- SAIF: `asic/dc/work/power/saif/8392ddeaee48cbb71a0c852aabc17546caf6ad98f6aed6d97c69ace8fdfa9868/gate_fa_two_tile_pingpong_random_seed301.saif`
- Metadata: `asic/dc/work/power/saif/8392ddeaee48cbb71a0c852aabc17546caf6ad98f6aed6d97c69ace8fdfa9868/gate_fa_two_tile_pingpong_random_seed301.json`
- Power reports: `asic/dc/work/power/reports/8392ddeaee48cbb71a0c852aabc17546caf6ad98f6aed6d97c69ace8fdfa9868/gate_fa_two_tile_pingpong_random_seed301/tt/`
- Gate UVM log: `tb/sim/build/saif_gate_fa_two_tile_pingpong_random_seed301/fa_two_tile_pingpong_test.log`

## Power breakdown

| Power group | Power | Share |
| --- | ---: | ---: |
| Clock network | 1.8325 W | 96.29% |
| Combinational | 37.7293 mW | 1.98% |
| Register | 16.7061 mW | 0.88% |
| Memory | 16.2513 mW | 0.85% |
| Leakage, all groups | 9.9848 mW | 0.52% |
| Total | 1.9032 W | 100.00% |

The top hierarchy hotspots are `u_fused_array` at 1.61 W (84.6%),
`u_output_buffer` at 164.435 mW (8.6%), and `u_normalizer` at 101.115 mW
(5.3%). The hierarchy values include the active clock network below each
block, so the 84.6% result must not be interpreted as data-path-only power.

`report_clock_gating` finds zero clock-gating elements and zero gated
registers. It reports 240,097 ungated registers. This directly explains why
the clock network dominates this busy, 625 MHz workload. The older vectorless
report of 23.4249 mW is not comparable: it uses default activity rather than
the gate-level workload SAIF.

## Timing and synthesis assessment

The active TT synthesis result meets max-delay timing only at the boundary:

| Metric | Result |
| --- | ---: |
| Setup WNS / TNS / violating paths | 0.000 ns / 0.000 ns / 0 |
| Worst hold slack / hold TNS / violating paths | -0.0953 ns / -403.35 ns / 5923 |
| Critical max path | `u_normalizer/acc_s2_q_reg[145]` to lane 4 reciprocal-multiplier `hi_product_s1_q_reg[45]` |
| Critical max logic depth / delay | 58 levels / 1.4918 ns |
| Design area | 2,429,697.55 library area units |
| Fused-array area | 2,038,750.40 (83.9%) |
| SRAM macros | 480; macro area 656,746.70 (27.0%) |
| Buffer/inverter cells | 250,647 (16.5% of leaf cells) |

The min-delay failure is not theoretical. The worst path is a PE
`sum_data_o_reg` directly driving an O-bank SRAM data input: 45.1 ps arrival
against a 140.4 ps requirement, for -95.3 ps slack. The SDF simulation reports
525,397 SRAM hold violations across repeated memory accesses. `+no_notifier`
keeps these violations from corrupting functional data, allowing the UVM
scoreboard to complete, but this does not constitute timing-clean gate
simulation.

The reports are pre-layout: `physical_aware=0`, `logical_hold_repair=0`, and
the power report uses `ZeroWireload` with low analysis effort. Clock-tree,
routing parasitics, OCV, IR drop, and post-CTS skew are absent. The measured
power is therefore a high-quality activity baseline, but not a sign-off value.

## Optimization priorities

1. **Close hold before changing the microarchitecture.** Run physical-aware
   synthesis and CTS using the SRAM min library/RC, then repair the O-bank
   write paths with legal delay insertion, useful skew, or local retiming.
   Re-run min STA with extracted parasitics and a timing-check-enabled gate
   simulation. Do not add arbitrary RTL delay; the repair must be driven by
   physical min-delay analysis. This clears the 5923 failing hold paths and
   makes the SAIF workload time-valid.

2. **Add phase-local integrated clock gating.** The power result makes this
   the highest-return change. Derive stable enables for Q/K/V load, QK, PV,
   normalizer, output writeback, and inactive ping-pong banks; configure
   synthesis to infer or insert ICG cells, and preserve test/reset behavior.
   Gate each leaf domain only when its state is not architecturally required.
   Re-run the two-tile ping-pong, backpressure, decode, and reset tests, then
   require `report_clock_gating` to show gated-register coverage and SAIF to
   show stopped clocks during idle phases.

3. **Pipeline the normalizer critical cone.** The 58-level critical path from
   `acc_s2_q_reg[145]` into the reciprocal multiplier leaves effectively zero
   setup margin before placement. Split the accumulator-to-reciprocal
   preparation at a registered boundary, with valid/tag/feature metadata
   delayed together. This costs one pipeline stage and registers, but protects
   the recent feature-tag alignment fixes and gives physical implementation
   useful setup margin.

4. **Reduce fused-array active state only after clock gating.**
   `u_fused_array` dominates both area and active power. Evaluate selective
   PE/stripe clock enables first; then compare narrower accumulator/score
   widths, fewer concurrently active stripes, or resource sharing against
   throughput and numerical-error targets. Do not trade away the two-tile
   ping-pong throughput without measuring energy per completed attention tile.

5. **Treat memory as a timing issue before a power issue.** The 480 SRAM
   macros are 27.0% of cell area but only 0.85% of measured total power. Bank
   gating can still reduce load/store activity, but O-bank write timing and
   macro placement need priority. Keep the macro data/control paths local to
   their PE stripes and constrain/review write-enable and address min paths.

6. **Resolve fanout and buffering during physical implementation.** There is
   one max-fanout DRC violation, 16 high-fanout nets in the power readback, and
   250,647 buffer/inverter cells. Replicate low-activity control drivers or
   build structured enable trees only after placement; avoid buffering the
   global clock in RTL. Compare post-CTS buffer area and clock power against
   this baseline.

## Re-run commands

```bash
make gate-saif
make gate-saif-power
```

Both commands default to the same random 512x512 workload at 1.6 ns. The
second command first requires a clean gate UVM run, then reads the generated
gate SAIF into the matching mapped DDC. Override `GATE_SAIF_SEED`,
`GATE_SIM_CLOCK_PERIOD`, `GATE_NETLIST`, or `GATE_SDF` only as a matched set
and retain the generated JSON sidecar with every reported number.
