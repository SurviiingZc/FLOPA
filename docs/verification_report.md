# Verification Plan, Test Cases, and Coverage Report

## 1. Objective and Verified Scope

The verification environment checks the current fixed-point RTL against a
bit-accurate SystemVerilog reference model. The model reproduces score scaling,
PWL exponential, the online `m/l/O` recurrence, reciprocal normalization,
rounding, saturation, masking, and output-byte packing.

The verified scope includes:

- 32 x 32 signed-INT8 MHA prefill from one tile through 512 x 512 tokens;
- single-query MHA decode with KV contexts through 256 tokens;
- causal and non-causal modes, sequence tails, ping-pong refill, and AXI stalls;
- AXI4-Lite programming, the 128-bit tile loader, and 128-bit AXI writeback;
- PWL boundaries, rounding, positive/negative saturation, error reporting, and
  recovery after an AXI write response error.

Native GQA, an integrated AXI read DMA, VCK190 hardware execution, and
post-route PPA remain outside the current verification claim.

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
| assertions | `tb/uvm/protocol_assertions.sv` | AXI ready/valid and protocol stability |
| coverage | `tb/uvm/coverage/attention_coverage.svh` | register, tile, AXI, phase, arithmetic, and shape coverage |

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
once with the ASIC SRAM model and executes 20 fixed-seed runs.

| Group | Runs | Verification purpose |
| --- | --- | --- |
| basic traffic | `smoke`, `axi_backpressure` | legal end-to-end execution and AXI ready throttling |
| prefill shapes | `random_1x1`, `prefill_causal_1x1`, `prefill_2x2`, `prefill_kv_tail` | one/two tiles, causal behavior, random INT8 data, KV tail |
| long/tail prefill | `prefill_long`, `prefill_tail_causal` | 512 x 512 ping-pong schedule, dual tail, random stalls |
| decode | `random_decode_long`, `random_decode_noncausal`, `decode_smoke` | one-query decode, 256-token multi-KV context, causal/non-causal execution |
| write addressing | `axi_4k_boundary` | one-beat boundary burst and 4-KiB split behavior |
| arithmetic | `pwl_corner`, `arith_rounding`, `positive_saturation`, `negative_saturation` | PWL segments, rounding increment, signed output rails |
| configuration/error | `decode_illegal`, `illegal_config`, `register_access`, `axi_bresp_error` | START rejection, byte strobes, RO/unknown access, write-fault recovery |

Reproduce it from the repository root:

```bash
make uvm-regression
```

The output is written below `tb/sim/build/uvm_regression/` with one log per run,
`coverage.vdb`, and the merged `urg/` report.

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
| Date | 2026-07-28 |
| Simulator | VCS V-2023.12-SP2_Full64 |
| Backend model | `ATTN_ASIC` RTL with characterized `uhdsp_256x8m4s` model |
| Result | **20/20 tests pass** |
| UVM severity | every run reports `UVM_ERROR=0`, `UVM_FATAL=0` |
| Numerical checking | every active output byte is compared with the bit-accurate model |
| Module coverage runs | 23/23 directed coverage jobs pass |

The long prefill test covers 16 Q tiles and 16 KV tiles with causal masking and
25% write backpressure. Decode tests cover a single query across eight KV tiles
for `SEQ_KV=256`. Tail, 4-KiB split, register-access, and error-recovery cases
exercise the principal control boundaries beyond numerical datapath testing.

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

| Scope | Score | Line | Condition | Toggle | Branch |
| --- | ---: | ---: | ---: | ---: | ---: |
| Full merged URG report | **88.74%** | 91.59% | 72.82% | 91.83% | 87.47% |
| `tb_top` hierarchy | **86.13%** | 92.01% | 72.92% | 91.83% | 87.76% |
| Module definitions | 78.12% | 72.78% | 68.33% | 82.28% | 89.10% |

Functional coverage is closed for the declared workload. The 95% code-coverage
target is not yet met. Remaining work is concentrated in condition/toggle
combinations in the normalizer, array controller, scheduler, register file, and
AXI write engine; no higher code-coverage claim is made.

## 7. Current Gate-Level Power Workload Check

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
the complete 20-run regression before changing a verified claim. Record the
date, RTL revision, command, seeds, pass/fail count, and new coverage report.
