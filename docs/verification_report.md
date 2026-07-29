# FLOPA Verification Plan, Test Cases, and Coverage Report

## 1. Objective and Verified Scope

The verification environment checks the current fixed-point RTL against a
bit-accurate SystemVerilog reference model. The model reproduces score scaling,
PWL exponential, the online `m/l/O` recurrence, reciprocal normalization,
rounding, saturation, masking, and output-byte packing.

The verified scope includes:

- 32 x 32 signed-INT8 MHA prefill from one tile through 512 x 512 tokens,
  including a two-head scheduling transition;
- single-query MHA decode with KV contexts through 256 tokens;
- causal and non-causal modes, sequence tails, ping-pong refill, and AXI stalls;
- AXI4-Lite programming, the 128-bit tile loader, and 128-bit AXI writeback;
- PWL boundaries, rounding, positive/negative saturation, error reporting,
  malformed tile protocol, busy-register rejection, and recovery through
  CLEAR_ERROR, soft reset, DONE restart, and AXI write-response errors.

Native GQA remains outside the RTL functional claim. VCK190 execution and
SmolLM2 measurements are qualified separately by deterministic board smoke,
token-hash/top-1 agreement, and the board reports under `fpga/`; they are not
substitutes for the bit-accurate UVM checks in this document.

## 2. Environment

```text
AXI-Lite agent --------+                         +---- AXI4 write agent
Tile-loader agent -----+--> attention_accel_top -+---- status/IRQ monitor
                       |                         |
                       +--> scoreboard <---------+
                              |          |
                              |          +--> functional coverage
                              +--> bit-accurate reference model
```

| Component | Location | Responsibility |
| --- | --- | --- |
| module testbenches | `tb/module_tb/` | directed self-checking tests and default FSDB generation |
| UVM top/environment | `tb/uvm/tb_top.sv`, `tb/uvm/env/` | agents, virtual interfaces, sequencing, and run control |
| tests/sequences | `tb/uvm/tests/`, `tb/uvm/sequences/` | random, directed, backpressure, tail, decode, and error stimulus |
| reference model | `tb/uvm/ref_model/attention_ref_model.svh` | byte-exact fixed-point expected output |
| scoreboard | `tb/uvm/scoreboard/attention_scoreboard.svh` | payload, address, count, and loader-accounting checks |
| assertions | `tb/uvm/protocol_assertions.sv`, compute RTL SVA | AXI protocol stability, mutually exclusive phases, and replicated valid-lane alignment |
| coverage | `tb/uvm/coverage/attention_coverage.svh` | register, tile, AXI, phase, arithmetic, and shape coverage |
| code-coverage waivers | `tb/sim/coverage/` | reviewed hierarchy/expression exclusions and raw-versus-waived report policy |

The synthesizable DUT remains Verilog. UVM packages and interfaces are confined
to the verification hierarchy.

## 3. Module-Level Verification

| RTL area | Primary tests | Main checks |
| --- | --- | --- |
| AXI | `tb_axi4_slave_if`, `tb_axi4_master_write` | independent AW/W, responses, burst splitting, WLAST, backpressure, recovery |
| control | `tb_accel_regfile`, `tb_accel_scheduler`, `tb_perf_counter` | configuration snapshot, prefill/decode legality, state transitions, counters |
| memory | `tb_qkv_tile_cache`, `tb_pingpong_buffer`, `tb_banked_sram`, `tb_asic_sram_backend` | bank ownership, half-word assembly, macro composition, read/write behavior |
| compute | `tb_fsa_fused_array`, `tb_fsa_stripe`, `tb_fsa_fused_pe` | QK, rowmax, delta, P writeback, rowsum, WS-PV, O-bank feature tags |
| nonlinear path | `tb_score_scale_pipe`, `tb_pwl_exp_unit`, `tb_online_normalizer`, `tb_reciprocal_lut` | boundaries, latency, tag alignment, rounding, saturation |
| integration | `tb_attention_accel_top` | complete load-to-writeback transaction |

Run the directed suite with:

```bash
make -C tb/sim syntax
make -C tb/sim run
make -C tb/sim asic-sram
make -C tb/sim lint-rtl
make -C tb/sim module-cov
```

Each retained module testbench generates an FSDB by default.

## 4. UVM Regression Matrix

The authoritative script is `tb/sim/scripts/run_uvm_regression.sh`. It compiles
once with the ASIC SRAM model and executes 21 fixed-seed runs.

| Group | Runs | Verification purpose |
| --- | --- | --- |
| basic traffic | `smoke`, `axi_backpressure` | legal end-to-end execution and AXI ready throttling |
| prefill shapes | `random_1x1`, `prefill_causal_1x1`, `prefill_2x2`, `prefill_kv_tail`, `multihead_underflow` | one/two tiles, causal behavior, random INT8 data, KV tail, two-head transition, delayed Q/K/V refill |
| long/tail prefill | `prefill_long`, `prefill_tail_causal` | 512 x 512 ping-pong schedule, dual tail, random stalls |
| decode | `random_decode_long`, `random_decode_noncausal`, `decode_smoke` | one-query decode, 256-token multi-KV context, causal/non-causal execution |
| write addressing | `axi_4k_boundary` | one-beat boundary burst and 4-KiB split behavior |
| arithmetic | `pwl_corner`, `arith_rounding`, `positive_saturation`, `negative_saturation` | all PWL segments, all 16 reciprocal seed indices, score guard/sticky rounding, negative normalizer half-tie, and signed output rails |
| configuration/error | `decode_illegal`, `illegal_config`, `register_access`, `axi_bresp_error` | all shape/mode START rejection; Q/K/V duplicate commit; missing-low and kind/bank/address half-word mismatch; full/partial/zero WSTRB; legal busy START rejection; busy PERF write acceptance; ordinary busy-config rejection; write-fault recovery, CLEAR_ERROR, soft reset, and DONE restart/clear |

Reproduce it from the repository root:

```bash
make uvm-regression
```

The output is written below `tb/sim/build/uvm_regression/` with one log per run,
`coverage.vdb`, the unmodified merged `urg/` report, and the separately generated
`urg_waived/` sign-off view. Both reports are retained for auditability.

### 4.1 Consumption-driven tile prefetch

`fa_random_qkv_vseq` treats all `(Q tile, KV tile)` operations as one continuous
ping-pong stream; bank parity does not restart at a Q-tile boundary. Three
workers share the 128-bit loader:

- Q[t] starts after Q[t-2] completes its final QK;
- K[g] starts after K[g-2] completes QK;
- V[g] starts after V[g-2] completes PV.

The K and V ownership states are independent, so K transfer can overlap the
preceding softmax/PV interval. Coverage explicitly samples Q refill after final
QK, K refill after QK, and V refill after PV. The scoreboard still requires the
exact Q/K/V word counts and byte-accurate output, so early refill cannot hide a
missing, duplicated, or reordered logical tile.

Targeted checks for this change on 2026-07-28:

| Test | Result | Loader words Q/K/V | Output |
| --- | --- | ---: | ---: |
| random prefill 64 x 64, seed 72802 | pass, 0 error/fatal | 128 / 256 / 256 | 4,096 bytes |
| random prefill 96 x 96, seed 72804 | pass, 0 error/fatal | 192 / 576 / 576 | 6,144 bytes |
| causal decode 1 x 96, seed 72805 | pass, 0 error/fatal | 64 / 192 / 192 | 64 bytes |

The 96 x 96 run exercises the third Q/K/V tile and reports 100% tile covergroup
coverage. These directed results do not replace the complete regression and
merged code-coverage data recorded below.

## 5. Latest Regression Result

| Item | Recorded result |
| --- | --- |
| Date | 2026-07-29 |
| Simulator | VCS V-2023.12-SP2_Full64 |
| Backend model | `ATTN_ASIC` RTL with characterized `uhdsp_256x8m4s` model |
| Result | **21/21 tests pass** |
| UVM severity | every run reports `UVM_ERROR=0`, `UVM_FATAL=0` |
| Numerical checking | every active output byte is compared with the bit-accurate model |
| Module coverage runs | 23/23 directed coverage jobs pass |

The long prefill test covers 16 Q tiles and 16 KV tiles with causal masking and
25% write backpressure. Decode tests cover a single query across eight KV tiles
for `SEQ_KV=256`. Tail, 4-KiB split, register-access, and error-recovery cases
exercise the principal control boundaries beyond numerical datapath testing.
The added two-head case checks 128 Q, 128 K, and 128 V loader words and 4,096
output bytes while deliberately withholding the next bank until the relevant
QK/PV consumption event. Its output is checked byte-for-byte for both heads.

## 6. Coverage Analysis

### 6.1 Functional Coverage

| Covergroup | Result |
| --- | ---: |
| AXI-Lite register access | 100.00% |
| tile load/commit/ping-pong | 100.00% |
| AXI write burst/strobe behavior | 100.00% |
| scheduler phase/IRQ behavior | 100.00% |
| arithmetic and configuration shapes | 100.00% |
| **total functional coverage** | **100.00%** |

The ignored bins document architectural invariants: unsupported AXI response
encodings, impossible phase/IRQ pairs, illegal one-beat/non-last combinations,
unsupported prefill `SEQ_Q > SEQ_KV`, and mathematically unreachable positive
score-delta saturation. They are not stimulus gaps in the declared interface.

### 6.2 Code Coverage

| Scope | Score | Line | Condition | Toggle | Branch | Assert |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Raw full merged report | **95.66%** | 94.95% | 94.10% | 92.16% | 92.89% | 99.88% |
| Raw `tb_top` hierarchy | **95.01%** | 95.42% | 94.37% | 92.16% | 93.21% | 99.92% |
| Raw module definitions | 88.52% | 76.18% | 91.66% | 84.30% | 91.60% | 98.87% |
| Waived DUT-scoped report | **96.00%** | 95.53% | 94.48% | 92.65% | 93.35% | 100.00% |
| Waived module definitions | 94.51% | 95.23% | 94.87% | 84.87% | 97.61% | 100.00% |

These are the final 2026-07-29 merged results from 21 passing tests. Functional
coverage remains 100%, and the reviewed DUT-scoped signoff view now exceeds the
95% aggregate code-coverage target. The module-definition score remains below
95% because it weights parameter guards and every definition independently;
the principal remaining metric is toggle coverage rather than a functional
condition gap.

The final expansion adds byte-enable/no-op control writes, legal busy START,
busy PERF access, all three tile-half metadata mismatches, Q/K/V duplicate
commits, reciprocal seed coverage, and a negative normalizer half-tie. The
`accel_regfile` now reaches 100% line and 91.84% condition coverage. All five
functional covergroups report 100% in the merged database.

The earlier dominant condition deficit was caused by redundant logic, not
missing stimulus. WS-PV O-seed and V tokens are launched through row/column
skews with equal total delay at every PE. The RTL now uses the O-seed token as
the canonical `pv_mac_valid_i` and checks the former three-input contract with
SVA. The same rule is applied to replicated stripe delta/PV-seed valids, exp
lanes, normalizer reciprocal/multiply lanes, and the l-update product/metadata
pipeline. Consequently `fsa_stripe` condition coverage increased from 62.67%
to 99.14%, and `fsa_fused_pe` increased from 76.74% to 94.74%, without excluding
either module.

Assertion coverage reports 5,133 successful assertions, zero failures, and six
uncovered assertions out of 5,139. All DUT assertions are covered in the scoped
signoff report. The six raw-report gaps are four testbench interface properties
whose failure branches correctly never occur and two unused UVM-library
properties; they are outside DUT ownership. In particular, every generated
WS-PV alignment assertion has real successful attempts in the long prefill
workload.

`online_normalizer` condition coverage is now 61.45%. Its remaining deficit
is dominated by conservative arithmetic overflow/clamp expressions, not the
removed replicated-lane valid reductions. Those conditions require numeric
range proofs before any further RTL deletion or waiver.

### 6.3 Formal Waiver Policy

The maintained waiver manifest is `tb/sim/coverage/README.md`. It records the
excluded source expression, rationale, review requirement, and the RTL checksum
used when the waiver was created. A checksum change invalidates the affected
waiver until it is reviewed again. Current exclusions are limited to:

- `W-HIER-001`: third-party DesignWare multiplier and SRAM-model internals;
- `W-RTL-001`: fixed-parameter fatal guards that cannot fire in this build;
- `W-RTL-002`: scheduler START combinations blocked by the register file;
- `W-RTL-003`: defensive FSM defaults reachable only by corrupt state;
- `W-RTL-004`: a top-level wait path unreachable at the fixed head dimension
  and pipeline latencies;
- `W-MATH-001`: PWL interpolation clamps excluded by the input-domain proof.

The regression compiles and runs with `line+cond+tgl+branch+assert`, emits the
raw report first, and applies `uvm_dut.hier` plus the reviewed
line/condition/branch exclusion files only to the second report. Toggle gaps
are intentionally not waiver-filtered at this stage.

### 6.4 Remaining Gap Disposition

| Classification | Remaining gap | Disposition |
| --- | --- | --- |
| approved waiver | third-party DW/SRAM internals, fixed-parameter guards, corrupt-state FSM defaults, scheduler combinations blocked by the register file, fixed-latency `PV_FLOW_WAIT_L`, proven PWL clamps | already encoded in `tb/sim/coverage/`; retain raw and waived reports together |
| module-level covered | scheduler/controller error arcs, AXI `READY=1` while response `VALID=0`, parameterized output-buffer partial final group | checked by `tb_accel_scheduler`, `tb_fsa_controller`, `tb_axi4_slave_if`, `tb_accel_regfile`, and `tb_output_buffer`; top UVM cannot force several of these without violating the public protocol |
| unwaived arithmetic gap | conservative `online_normalizer` reduced-product overflow and saturation combinations | retain in the score until interval/formal range proof establishes unreachable expressions; do not waive from percentage alone |
| unwaived integration gap | `fsa_qk_engine`/`fsa_pv_engine` defensive timeout/error branches and some AXI write abort ordering | inject only through an explicit internal fault campaign or prove unreachable from legal cache/controller handshakes |
| non-functional toggle gap | constant configuration bits, sign-extension/high multiplier bits, per-lane reciprocal seeds, and long delay-line stages | not a functional failure; analyze per-instance toggle only for power intent, not by adding illegal traffic |

The reciprocal functional model observes every seed index across the merged
regression. Lower per-instance LUT toggle scores mean a particular generated
lane does not see every seed value; they do not indicate a missing reciprocal
algorithm case. Likewise, the two zero-head MC/DC rows in `start_cfg_valid_w`
cannot independently toggle while the required Q/KV head-equality term remains
true. They remain visible in raw condition coverage pending a formal expression
waiver rather than being hidden by a contrived illegal sequence.

## 7. Gate-Level Power Workload Check

The 2026-07-27 power workload independently validates the exact mapped netlist
used for the current power number:

| Field | Result |
| --- | --- |
| Test | `fa_random_qkv_test`, seed 301, `SEQ_Q=64`, `SEQ_KV=64` |
| Gate result | `UVM_ERROR=0`, `UVM_FATAL=0` |
| SAIF capture | cycles 57 to 4336, 4,279 sampled cycles |
| Loader accounting | Q/K/V words = 128/256/256 |
| Output accounting | 256 beats / 4,096 bytes |
| SAIF annotation | 100% nets, ports, and pins |

Log: `tb/sim/build/saif_gate_ungated_random_qkv_64x64_seed301/fa_random_qkv_test.log`.

## 8. Required Waveform Figures

The final presentation should capture the following four panels. Waveforms are
verification evidence, not substitutes for scoreboard results.

### W1. Top-Level Load, Execution, and AXI Writeback

- Generate: `make -C tb/sim top`
- File: `tb/sim/build/tb_attention_accel_top/tb_attention_accel_top.fsdb`
- Signals: `debug_state_o`, tile-loader valid/ready/kind/bank/address/half,
  `m_axi_awaddr`, AW/W valid-ready, `m_axi_wlast`, B valid-ready, and `irq_o`.
- Show: two 128-bit halves per cache word, legal scheduler order, continuous
  output addressing, and completion after the write response.

### W2. PE-Local Softmax and WS-PV

- Generate: `make -C tb/sim compute`
- File: `tb/sim/build/tb_fsa_fused_array/tb_fsa_fused_array.fsdb`
- Signals: `qk_valid_i`, `qk_last_o`, `softmax_start_i`,
  `softmax_pv_ready_o`, `softmax_done_o`, `pv_start_i`, `pv_valid_i`,
  `pv_feature_i`, `pv_done_o`, `norm_rd_en_i`, `norm_rd_feature_i`,
  `norm_rd_valid_o`, `norm_rd_feature_o`, and `norm_rd_acc_o`.
- Show: column-overlapped softmax, WS-PV launch, and matching O-bank feature tags.

### W3. Normalizer Tag and Rounding Pipeline

- Generate: `make -C tb/sim softmax`
- File: `tb/sim/build/tb_online_normalizer/tb_online_normalizer.fsdb`
- Signals: `valid_i`, `acc_rows_i`, `l_rows_i`, `out_scale_i`, `tag_i`,
  reciprocal/multiply valid stages, `valid_o`, `tag_o`, and `out_rows_o`.
- Show: payload/tag alignment through bubbles, rounding, and both saturation rails.

### W4. Long Ping-Pong Refill

- Generate the UVM regression with an FSDB hook enabled for `prefill_long`.
- Suggested file: `tb/sim/build/uvm_regression/prefill_long.fsdb`.
- Signals: scheduler state/tile indices, tile load/commit, Q/K/V active bank IDs,
  independent Q/K/V consume/switch pulses, pending-switch bits, AXI write
  completion pulse, and writeback address.
- Show: Q refill after final QK, K refill during softmax/PV, V refill after PV,
  ordered ownership advances, and continuous multi-Q-tile writeback.

## 9. Update Rule

After an RTL change, rerun the affected module test, the relevant UVM case, and
the complete 21-run regression before changing a verified claim. Record the
date, RTL revision, command, seeds, pass/fail count, and new coverage report.
