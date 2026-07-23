# FlashAttention Merged Coverage Report

## 1. Run Record

This report records the current passing merged UVM coverage database after the
normalizer O-bank response/tag and two-tile writeback completion fixes. The
database contains 15 fixed-seed tests: smoke, AXI backpressure, random Q/K/V,
PWL corners, arithmetic rounding, positive/negative saturation, causal random,
two-tile ping-pong, two-tile random/backpressure, decode
smoke/backpressure/random, and two illegal-configuration tests.

| Item | Value |
| --- | --- |
| Date | 2026-07-23 |
| Simulator | VCS V-2023.12-SP2_Full64 |
| Database | `tb/sim/build/uvm_two_tile_random_pingpong/coverage.vdb` |
| HTML/text report | `tb/sim/build/uvm_two_tile_random_pingpong/urg/` |
| Result | 15/15 tests pass, UVM error/fatal counts are zero |
| Metrics | line, condition, toggle, branch, and UVM covergroups |

Reproduce the report with:

```bash
cd tb/sim
OUT_DIR=build/uvm_two_tile_random_pingpong scripts/run_uvm_regression.sh
```

The script applies `-cm line+cond+tgl+branch` at compile and simulation time,
uses a distinct `-cm_name` for each test, and invokes `urg` on the shared VDB.

## 2. Merged Summary

| Scope | Score | Line | Condition | Toggle | Branch | Functional group |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Composite report | 80.75% | 85.49% | 68.08% | 83.41% | 85.36% | 81.44% |
| `tb_top.dut` hierarchy | 80.79% | 85.90% | 68.19% | 83.42% | 85.65% | N/A |
| Module definitions | 73.65% | 68.03% | 64.57% | 75.94% | 86.08% | N/A |
| UVM functional covergroups | 81.44% | N/A | N/A | N/A | N/A | 81.44% |

The composite score includes the Verdi UVM recorder instance, which has 3.09%
code coverage and is not DUT logic. Use the `tb_top.dut` row for this UVM
top-level RTL baseline. No code-coverage waiver is included in this report.

## 3. Functional Coverage

| Covergroup | Merged score | Main covered scope | Principal open bins |
| --- | ---: | --- | --- |
| AXI-Lite | 67.50% | Read/write direction, control/status/scale register classes, OKAY and SLVERR | `perf_cfg`, scale 1.00, DECERR, additional write/address crosses |
| Tile loader | 100.00% | Q/K/V, bank0/bank1 preload, first/middle/last addresses, phase-aware refills | No open bin in this covergroup |
| AXI write | 83.33% | INCR, 16-byte data, full 16-beat burst, WLAST/strobe | One-beat burst and its WLAST cross; decode's four-beat burst is currently excluded by the bin model |
| Scheduler phase | 77.78% | IDLE through DONE, IRQ high/low | ERROR state and phase/IRQ combinations |
| Math / softmax | 78.57% | Prefill/decode, causal on/off, all PWL segments, rounding, valid-lane classes | Non-unity exp bin, positive/negative score saturation, dual output saturation, stimulus saturation/rounding crosses |

The missing bins are active coverage debt, not waivers. Bank1 and multi-KV
temporal coverage is closed by the two-tile loader sequences. Tail AXI
writeback needs an RTL-supported tail contract and a coverpoint that represents
the legal four-beat decode burst rather than excluding it.

## 4. RTL Hierarchy Coverage

The direct children of `tb_top.dut` identify the highest-value code-coverage
closure work.

| Instance | Score | Line | Condition | Toggle | Branch |
| --- | ---: | ---: | ---: | ---: | ---: |
| `u_array_controller` | 65.83% | 65.12% | 66.67% | 70.00% | 61.54% |
| `u_axi_write` | 71.92% | 81.71% | 76.19% | 63.12% | 66.67% |
| `u_fused_array` | 80.90% | 85.93% | 68.14% | 83.72% | 85.82% |
| `u_normalizer` | 74.88% | 88.80% | 51.40% | 77.15% | 82.15% |
| `u_output_buffer` | 89.12% | 92.39% | 82.35% | 95.25% | 86.49% |
| `u_perf` | 62.78% | 77.78% | 66.67% | 16.67% | 90.00% |
| `u_pv_engine` | 83.21% | 80.95% | 78.26% | 99.56% | 74.07% |
| `u_qk_engine` | 81.05% | 77.94% | 74.36% | 98.84% | 73.08% |
| `u_regfile` | 47.87% | 73.22% | 67.59% | 8.69% | 41.96% |
| `u_scheduler` | 59.17% | 74.44% | 71.23% | 17.67% | 73.33% |
| `u_tile_cache` | 90.14% | 91.88% | 82.64% | 98.28% | 87.78% |

## 5. Closure Status

Numerical correctness is closed for the 15-test fixed-seed suite: prefill,
decode, and two-tile random tests match the bit-accurate reference model.
Coverage sign-off is not yet closed.

| Goal | Current status | Required work |
| --- | --- | --- |
| 95% RTL code coverage | Not met; `tb_top.dut` hierarchy score is 80.79% | Cover error, busy/restart, perf-counter, and tail/writeback control paths; then merge coverage-enabled module TB databases with the UVM VDB |
| 100% planned functional coverage | Not met; merged covergroup score is 81.44% | Add missing register response, scheduler ERROR, legal short-burst, saturation, and cross-combination tests |
| Numerical correctness | Met for this 15-test fixed-seed suite | Two-tile online oracle, address map, and random-backpressure checks pass |

No unsupported feature is waived solely to improve a metric. Each future waiver
must identify its RTL source, justification, owner, and expiry/review date.

## 6. Two-Tile Extension Result

The two-tile UVM extension was rerun on 2026-07-23 after the AXI write-done
pulse fix. The passing 15-test regression is at
`tb/sim/build/uvm_two_tile_random_pingpong/urg/`.

| Item | Result |
| --- | --- |
| Regression result | 15/15 tests pass, including `fa_two_tile_pingpong_test` and `fa_two_tile_random_backpressure_test` |
| Data oracle | Both 2x2 tests have exact data/address agreement after modeling online `m/L/O` recurrence |
| Input scheduling | Both report Q/K/V word counts of `128/256/256` |
| Ping-pong coverage | `fa_tile_coverage` is 100%; bank0/bank1 preload, bank0 refill after switch in QK, and bank1 refill during WRITEBACK are all hit |
| Writeback address check | Second Q tile starts at byte 2048; the complete `0..4095` range has no missing, duplicate, or invalid byte |
| Merged score | 80.75% composite: line 85.49%, condition 68.08%, toggle 83.41%, branch 85.36%, functional groups 81.44% |

The root cause was that the level-held AXI completion was consumed twice. The
top level now derives one `axi_write_done_pulse_w`, shared by scheduler
completion, Q-bank consume, and writeback/head address advancement. The UVM
address-map checker remains enabled to prevent regression of this contract.
