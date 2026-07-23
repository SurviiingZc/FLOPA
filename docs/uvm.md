# FlashAttention UVM Verification Plan

## 1. Purpose and Scope

This document defines the system-level UVM environment for the current
`attention_accel_top` implementation. It is derived from `docs/design.md`,
`docs/rtl.md`, `docs/verification.md`, all `docs/impl/*.md` contracts, and the
active RTL under `rtl/`.

The first UVM milestone verifies the implemented 32x32 prefill-MHA datapath:

1. AXI-Lite configuration, status polling, start, clear-done, and error flow.
2. External Q/K/V cache loading through `tile_load_*` and `tile_commit_*`.
3. Scheduler phase progression: LOAD_Q, LOAD_KV, QK, SOFTMAX, PV, WRITEBACK,
   and DONE/ERROR.
4. 128-bit incrementing AXI writeback, including response and ready/valid
   backpressure.
5. The existing canonical identity-V flow: zero Q/K and constant V produces
   the same constant output after the documented scale setting.

The following are intentionally **not** accepted as current DUT capabilities:

| Item | Current RTL status | UVM treatment |
| --- | --- | --- |
| AXI read DMA for Q/K/V | No top-level read master; base/stride are not consumed for loading | Model Q/K/V through `tile_load_*`; no read-DMA coverage claim |
| Decode | START validation rejects decode | Negative configuration test only |
| GQA | START validation rejects GQA / unequal Q and KV head counts | Negative configuration test only |
| `VALUE_SCALE` and `MASK_CFG` datapath effect | Registers are latched but current datapath does not consume them | Readback coverage only; no numerical claim |
| Arbitrary numerical golden output | PWL exp, online LSE, reciprocal, saturation, and rounding must be mirrored bit-for-bit | Planned reference-model milestone before random numerical sign-off |

## 2. DUT Verification Boundary

```text
             active UVM stimulus                         active UVM observation
  +-------------------------------+                 +---------------------------+
  | AXI-Lite agent                |                 | AXI write agent           |
  | AW/W/B, AR/R                  |                 | AW/W/B monitor/responder |
  +--------------+----------------+                 +-------------+-------------+
                 |                                                    ^
                 v                                                    |
  +--------------------------------------------------------------------+-------+
  |                       attention_accel_top                          |
  |  regfile -> scheduler -> cache -> QK -> online softmax -> WS-PV   |
  |                                           -> normalize -> output   |
  +----------------------+---------------------------------------------+
                         ^
                         |
              +----------+-----------+
              | tile-loader agent    |
              | Q/K/V 256-bit words  |
              | split into two 128b  |
              | loads plus commits   |
              +----------------------+
```

The `tb_top.sv` wrapper performs only clock/reset generation, Verilog DUT
instantiation, signal-by-signal interface wiring, and virtual-interface
publication. It contains no stimulus, functional model, or checker.

### 2.1 Interface Contract

| Interface | Width / contract | Agent role |
| --- | --- | --- |
| AXI-Lite slave | 32-bit address/data, independent AW/W, B and R responses | Active driver and protocol monitor |
| Tile loader | `kind`, bank, 6-bit address, two 128-bit halves per 256-bit cache word, explicit commit | Active driver and reconstructed-word monitor |
| AXI write master | 128-bit data, INCR burst, DUT emits AW/W, testbench sends ready/B | Ready/backpressure responder and monitor |
| Debug | `irq_o`, 4-bit scheduler state | Passive phase coverage |

SVA embedded in the three interfaces checks stable payload behavior while a
valid transaction waits for ready. The write monitor also checks that W beats
follow AW and that WLAST occurs at the programmed burst end.

## 3. Delivered UVM Architecture

```text
tb/uvm/
  attention_uvm_if.sv          SV interfaces and interface assertions
  attention_uvm_pkg.sv         Compile-order package for all UVM classes
  fa_uvm_types.svh             Transactions and shared test configuration
  tb_top.sv                    Thin Verilog/SV integration wrapper
  agents/
    fa_axil_agent.svh          AXI-Lite sequencer, driver, monitor
    fa_tile_agent.svh          Q/K/V load/commit sequencer, driver, monitor
    fa_axi_write_agent.svh     AXI write responder and monitor
  env/attention_env.svh        Environment, virtual sequencer, TLM connections
  sequences/attention_sequences.svh
                               Supported-prefill, smoke, and illegal-config flows
  scoreboard/attention_scoreboard.svh
                               Protocol checker and byte-accurate output comparison
  ref_model/attention_ref_model.svh
                               Bit-accurate one-tile QK/PWL/PV/normalization oracle
  coverage/attention_coverage.svh
                               AXI-Lite, tile, writeback, scheduler, and math coverage
  tests/attention_tests.svh    smoke, random-QKV, arithmetic-corner, and negative tests
```

### 3.1 Component Responsibilities

| Component | Responsibility | TLM output / input |
| --- | --- | --- |
| `fa_axil_agent` | Drives independent AXI-Lite channels, captures accepted writes and reads | `fa_axil_item` analysis port |
| `fa_tile_agent` | Converts one 256-bit item into two handshaken 128-bit loads; emits commits | `fa_tile_item` analysis port |
| `fa_axi_write_agent` | Randomizes DUT-side ready, returns OKAY B responses, captures individual output beats | `fa_axi_write_item` analysis port |
| `fa_virtual_sequencer` | Coordinates AXI-Lite programming and tile population | Owns AXI-Lite/tile sequencer handles |
| `attention_scoreboard` | Reconstructs Q/K/V words, invokes golden calculation at START, checks every output byte; records input/output counts | Analysis FIFOs from all three monitors |
| `attention_ref_model` | Bit-accurate first-tile fixed-point golden model | Used only by scoreboard |
| coverage subscribers | Sample transactions and debug phases without affecting checking | Analysis connections from monitors |

No component reaches into DUT hierarchy. This preserves the black-box
verification boundary; white-box checks already present in module testbenches
remain module-level verification, not system-level scoreboarding.

## 4. Reference-Model Plan

The reference model is deliberately staged. A test must only enable a checker
whose oracle is implemented for its data class.

| Stage | Oracle | Status / enablement |
| --- | --- | --- |
| R0 | AXI protocol, cache load reconstruction, write byte count/order | Implemented in monitors and scoreboard |
| R1 | Zero Q/K plus constant V canonical flow | Implemented; enabled by `fa_smoke_test` and `fa_axi_backpressure_test` |
| R2 | Exact integer QK, score-scale shift, causal mask, and PWL-exp table | Implemented for one 32x32x64 tile |
| R3 | Bit-exact one-tile `(m,l,O)`, reciprocal LUT, final normalization, saturation and rounding | Implemented for one 32x32x64 tile; gates random numerical output comparison |
| R4 | External vector replay and tolerance metrics (`max_abs_error`, MAE, cosine similarity) | Optional integration/regression layer after R3 |

R2/R3 must use the same constants, arithmetic widths, signedness, shifts, PWL
segments, reciprocal LUT contents, and saturation behavior as RTL. Floating
point softmax is useful as a secondary quality metric, but it is not an RTL
golden model and cannot replace R3.

## 5. Test Plan

### 5.1 UVM Tests Delivered in This Milestone

| Test | Class | Stimulus | Primary checks |
| --- | --- | --- | --- |
| Smoke | `fa_smoke_test` | 32x32x64 prefill; Q=0, K=0, V=constant 1; full ready | Register program, Q/K/V commit, phase completion, constant writeback bytes |
| AXI backpressure | `fa_axi_backpressure_test` | Same canonical tile, 50% random low probability for AWREADY/WREADY | Valid stability SVA, no dropped beat, WLAST position, completion after B response |
| Illegal configuration | `fa_illegal_config_test` | `SEQ_Q=0`, then START and error clear | Sticky error status and clear-error control behavior |
| Random Q/K/V | `fa_random_qkv_test` | Reproducible signed Q/K in [-4,4] and V in [-96,96], output backpressure | Exact QK/PWL/PV/normalization byte comparison |
| PWL segments | `fa_pwl_corner_test` | Score deltas on 256-point boundaries through PWL segment 0-7 and exp-zero clamp | Segment, exp-zero, score-saturation and output-byte checks |
| Arithmetic rounding | `fa_arith_rounding_test` | Q/K score deltas 0/-1/-2/-3 with score-scale mantissa=5, shift=2 | Guard/sticky score-round event plus exact byte check |
| Positive saturation | `fa_positive_saturation_test` | Q=K=0, V=127 | Final INT8 positive saturation and writeback check |
| Negative saturation | `fa_negative_saturation_test` | Q=K=0, V=-128 | Final INT8 negative saturation and writeback check |
| Causal random | `fa_causal_random_test` | Random Q/K/V with causal mask and output backpressure | Causal lane count (528), mask, and exact byte comparison |

Run with a recorded seed, for example:

```bash
cd tb/sim
vcs -full64 -sverilog -ntb_opts uvm -timescale=1ns/1ps \
  -f filelists/rtl.f -f filelists/uvm.f -top tb_top -o build/uvm_smoke/simv
build/uvm_smoke/simv +UVM_TESTNAME=fa_smoke_test +ntb_random_seed=1
```

The `-ntb_opts uvm` option is required because existing module test scripts do
not link the UVM library. `filelists/uvm.f` is intentionally separate from the
directed-module filelist.

### 5.2 Planned Functional Tests and Entry Criteria

| ID | Test | Scenario | Scoreboard / coverage gate | Entry criterion |
| --- | --- | --- | --- | --- |
| UVM-01 | `config_readback` | Every RW/RO register, byte strobe, W1C, start while busy | Exact register model and illegal-write coverage | R0 |
| UVM-02 | `tile_pingpong` | Q lifetime across KV tiles; K/V bank switch after consume | Tile bank/action cross; phase ordering | R0, two-tile loader sequence |
| UVM-03 | `writeback_tail` | 1, 15, 16, 17, 31, 32 valid Q rows | Address, strobe, byte-count checker | RTL must expose / support tail contract |
| UVM-04 | `causal_mask` | diagonal, first/last query rows, masked positions | R2 exact QK/mask/softmax checking | R2 and causal path review |
| UVM-05 | `softmax_extreme` | maximum change, exp clamp, near-zero sum, saturation | R2/R3 exact model, softmax bins | R3 |
| UVM-06 | `multi_kv_tile` | 32x64 and 32x96 KV sequences | Online state and WS-PV/l-update ordering | R3 and loader data model |
| UVM-07 | `random_prefill` | Supported MHA dimensions/data/scales/backpressure | Bit-exact output and planned crosses | R3 |
| UVM-08 | `perf_counter` | idle/load/compute/stall/writeback counters | Exact counter equations | Counter specification freeze |
| UVM-09 | `decode_reject` | Decode bit set | Error-code coverage | Current RTL only |
| UVM-10 | `gqa_reject` | unequal Q/KV heads or GQA selected | Error-code coverage | Current RTL only |
| UVM-11 | `read_dma` | Q/K/V read transactions | Not applicable yet | Add only with AXI read master RTL |

The current `tile_boundary` and multi-KV `random_regression` concepts from
`docs/verification.md` remain plan items. The numerical oracle is intentionally
limited to the active 32x32x64 single-KV-tile prefill path; multi-KV online-LSE
state is not claimed as covered.

### 5.3 Module-to-System Test Allocation

| Layer | Ownership | Examples |
| --- | --- | --- |
| Module TB | Existing `tb/module_tb/` | SRAM conflict policy, PWL/reciprocal numeric table points, PE wavefronts, output buffer packing |
| UVM interface / integration | New `tb/uvm/` | AXI channel independence, tile commit protocol, scheduling, writeback response/backpressure |
| Full numerical UVM | New reference model plus UVM | Multi-KV online softmax and final output equality |

This separation avoids repeating PE microarchitecture tests in a slow top-level
regression while ensuring integrated control and data movement are exercised.

## 6. Functional Coverage Plan

### 6.1 Implemented Covergroups

| Covergroup | Current coverpoints | Current crosses |
| --- | --- | --- |
| `fa_axil_coverage` | read/write, control/dimension/scale/perf address classes, response | direction x address class |
| `fa_tile_coverage` | Q/K/V kind, bank 0/1, load/commit, first/middle/last cache address | kind x bank x action |
| `fa_axi_write_coverage` | burst length, size, burst type, WLAST, strobe | burst length x WLAST |
| `fa_phase_coverage` | all scheduler states, IRQ level | state x IRQ |
| `fa_math_coverage` | stimulus class, causal enable, PWL segment bitmap, exp zero/one, score/output saturation, score/final-normalizer rounding, valid-lane count | stimulus x causal; stimulus x output saturation; stimulus x score rounding |

### 6.2 Required Additions Before Sign-off

| Coverage group | Mandatory bins and crosses |
| --- | --- |
| Configuration | prefill/causal/mode request, legal/illegal head configuration, scale encodings, start-while-busy; configuration class x error code |
| Tile/cache | full/tail tile, Q/K/V each bank, consume-to-switch, commit before/after active work; cache phase x QK/PV |
| Softmax | causal mask, row max unchanged/updated, alpha range, PWL segment, exp zero/saturation, rowsum/LSE update, normalizer saturation; tile type x softmax class |
| AXI write | aligned base, burst 1/16/tail, gaps, AW/W independent stalls, B response; ready-backpressure x burst length |
| Scheduler | every legal transition, DONE and ERROR recovery, Q/KV tile last/run last; phase x ping-pong state |
| Errors | zero length, unsupported head dim, decode, GQA, alignment, repeated start; illegal request x returned error code |

Coverage is only meaningful after tests drive legal values. Unsupported decode,
GQA, and AXI read-DMA bins are error/absence coverage for the current design,
not feature coverage.

### 6.3 Collection and Current Result

Run the reproducible numerical suite with:

```bash
cd tb/sim
scripts/run_uvm_regression.sh
```

The script compiles with the VCS-supported `-cm line+cond+tgl+branch` database
options, uses fixed seeds, emits a per-test UVM coverage summary, creates
`build/uvm_regression/coverage.vdb`, and merges it with `urg` into
`build/uvm_regression/urg`. It deliberately returns nonzero if
the UVM report contains an error or fatal; simulator process status alone is
not used as a pass criterion.

The first merged nine-test database reports 76.85% total functional coverage:
AXI-Lite 67.50%, tile-loader 80.00%, AXI write 83.33%, scheduler phase 77.78%,
and numerical/softmax coverage 75.64%. The captured report is available on the
server under `tb/sim/build/uvm_regression_rounding/urg/`; a normal script run
uses the default `tb/sim/build/uvm_regression/urg/` output directory.

The initial fixed-seed execution establishes the following baseline:

| Test | Seed | Result | Math coverage in isolated run |
| --- | ---: | --- | ---: |
| `fa_smoke_test` | 1 | PASS | 28.50% |
| `fa_axi_backpressure_test` | 19 | PASS | 28.50% |
| `fa_arith_rounding_test` | 106 | PASS | 30.77% |
| `fa_positive_saturation_test` | 103 | PASS | 28.50% |
| `fa_negative_saturation_test` | 104 | PASS | 28.50% |
| `fa_illegal_config_test` | 7 | PASS | 0.00% (no numerical model event) |
| `fa_random_qkv_test` | 101 | FAIL: byte-exact mismatch | 31.00% |
| `fa_pwl_corner_test` | 102 | FAIL: byte-exact mismatch | 37.25% |
| `fa_causal_random_test` | 105 | FAIL: byte-exact mismatch | 31.00% |

The three failing tests are not waived: their first row shows the DUT output
byte for feature `d` matching the mathematical result for `d+1`, with the
final feature uncomputed. Constant-V tests cannot expose this permutation. The
scoreboard intentionally retains the mathematical feature ordering so that the
failure remains visible to RTL owners. The likely inspection area is the
WS-PV `pv_rescale_cols_*` data pipeline and its feature/tag alignment in
`rtl/compute/fsa_fused_array.v`.

## 7. Code Coverage and Closure

The project target remains 100% planned statement, branch, condition, and
toggle coverage, with every exclusion reviewed and documented. Closure proceeds
in this order:

1. Keep module-level code coverage in the module regression, where localized
   branches can be reproduced quickly.
2. Collect top-level UVM coverage for `attention_accel_top`, scheduler, regfile,
   cache protocol, output buffer, and AXI write engine.
3. Merge only compatible compile/elaboration databases and record tool version,
   RTL commit, UVM test list, random seeds, and exclusion file version.
4. Classify each uncovered item as missing test, unreachable defensive logic,
   unsupported current feature, or tool artifact. A waiver must cite RTL file,
   line, reason, owner, and planned expiry/review date.
5. Do not waive an item merely because a planned feature is unimplemented. Its
   configuration must instead be rejected and covered by the negative plan.

Numerical sign-off additionally requires no unresolved scoreboard error, no
fatal assertion, no deadlock/timeout in random prefill regression, 100% planned
functional bins, and bit-exact R3 comparisons across the agreed seed list.

## 8. Regression Matrix

| Tier | Contents | Run condition |
| --- | --- | --- |
| PR smoke | `fa_smoke_test`, `fa_illegal_config_test`, selected module TBs | Every RTL/UVM change |
| Nightly protocol | Smoke plus 20+ seeds of `fa_axi_backpressure_test`, AXI/cache module tests | After interface/control change |
| Numerical | UVM-04 through UVM-07 plus softmax/array module tests | Only after R3 completion |
| Release | Merged module/UVM code coverage and full functional coverage report | Before integration handoff |

Every run must print UVM test name, random seed, generated configuration,
first failing output address/byte, expected and actual value, and captured
debug scheduler state. Waveforms are diagnostic artifacts, not pass criteria.

## 9. Assumptions, Risks, and Next Work

1. The environment treats each tile-loader transaction as one 256-bit cache
   word, which the driver sends as low then high 128-bit halves. This mirrors
   the active top-level port exactly.
2. The UVM testbench is currently configured for the default 64-feature cache
   address width. Parameterized compilation requires updating the item address
   width and re-running compile/elaboration checks.
3. Backpressure currently randomizes output AWREADY and WREADY. AXI-Lite and
   tile-loader response-side randomization should be added after their DUT-side
   ready behavior is exposed/controlled in the testbench.
4. The bit-accurate data checker supports exactly one full 32x32x64 KV tile.
   Extend the reference model with the online-LSE recurrence before enabling
   multi-KV or tail-tile data comparison.
5. Random Q/K/V tests expose a feature-ordering RTL bug; resolve it before
   numerical sign-off or using their coverage as closure evidence.
6. Add assertion coverage and liveness bounds once the expected per-tile latency
   envelope is frozen; no timeout value should be used as a performance claim.
