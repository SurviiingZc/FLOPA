# UVM Verification Plan

## Scope

`fa_random_qkv_test` is the single configurable positive random workload. It
drives the full prefill/decode path, tile loader, ping-pong cache, scheduler,
fused array, normalizer, AXI writeback, reference model, and scoreboard.

The UVM tensor and bit-exact model support sequence lengths through 512. The
sequence preloads two physical banks, then refills the released Q/KV bank from
the scheduler's observed `q_tile_index` and `kv_tile_index`. This covers all
32-token tile transitions instead of a fixed two-tile hand-written flow.

## Runtime Configuration

The random test accepts the following plusargs:

| Plusarg | Meaning | Default |
| --- | --- | --- |
| `+FA_SEQ_Q=<n>` | Prefill query length, 1..`seq_kv` | 512 |
| `+FA_SEQ_KV=<n>` | KV context length, 1..512 | 512 |
| `+FA_READY_LOW_PCT=<n>` | AXI write ready deassertion probability, 0..75 | 0 |
| `+FA_CAUSAL_EN=0|1` | Causal masking | 0 |
| `+FA_DECODE_EN=0|1` | MHA decode mode; Q length must be 1 | 0 |
| `+FA_O_BASE=<hex>` | AXI output base address; must be 16-byte aligned | 0 |

For example:

```sh
make uvm-test UVM_TEST=fa_random_qkv_test UVM_SEQ_Q=512 UVM_SEQ_KV=512 UVM_CAUSAL_EN=1 UVM_READY_LOW_PCT=25
```

## Stimulus and Checkers

Q, K, and V values are independently generated over the signed INT8 domain.
Six sign/rail anchors (`-128`, `-64`, `-1`, `0`, `1`, `127`) are placed on
random active rows so each random run proves negative, zero, positive, and
rail traffic reached all three operands. Directed PWL, rounding, positive
saturation, negative saturation, illegal-config, and decode smoke tests remain
separate because they target distinct arithmetic or control requirements.

The scoreboard checks every AXI output byte against the fixed-point reference
model and verifies output byte count, no duplicate addresses, no missing bytes,
and expected Q/K/V feature-word load counts. It also validates Q cache payload
ordering, independently checking the long-sequence Q ping-pong schedule.

## Functional Coverage

The math covergroup records:

- prefill/decode and causal/non-causal modes;
- Q/KV one, two, medium (3..8), and long (9..16) tile counts;
- aligned, Q-tail, KV-tail, and dual-tail shapes;
- stalled and unstalled AXI writeback;
- full negative/zero/positive Q/K/V input-domain observation;
- PWL segments, exp zero/one, score/normalizer rounding, score saturation,
  output saturation, and valid lane totals.

The regression matrix runs a basic `1x1` smoke, one `512x512` long causal
prefill with backpressure, a causal dual-tail prefill, long decode, and directed
corner tests. Normal prefill rejects `seq_q > seq_kv`; standard self-attention
prefill uses `seq_q == seq_kv`, while decode fixes `seq_q == 1`.
Code coverage is collected with VCS line, condition, toggle, and branch modes.

## Current Baseline

The long prefill regression uses full-range signed INT8 random Q/K/V data and
checks every output byte against the bit-exact model. The `512x512` case is the
single schedule-stress test for Q/KV ping-pong, multi-tile control, and AXI
writeback; it replaces the redundant `Nx1`, `NxN`, and invalid `512x256`
prefill shapes.

## Regression Matrix and Results

The authoritative integration coverage database is
`tb/sim/build/uvm_regression/coverage.vdb`.  It is rebuilt from an empty
directory by `tb/sim/scripts/run_uvm_regression.sh`; individual test coverage
databases are named with `-cm_name` and merged by VCS in that location.

The 2026-07-24 clean regression completed all 20 tests with `UVM_ERROR=0` and
`UVM_FATAL=0`:

| Area | Test or configuration | Verification intent |
| --- | --- | --- |
| Baseline / traffic | `smoke`, `axi_backpressure` | Basic end-to-end result; AXI W-channel ready throttling. |
| Prefill shapes | random 32x32, causal 32x32, 64x64, 64x65 | One and two tiles, causal mask, Q/K/V full-domain random values, and a KV tail. |
| Ping-pong schedule | random 512x512 causal, 25% write backpressure | 16 Q tiles and 16 KV tiles; exercises preload, consume, refill, and writeback scheduling. |
| Tail and 4KB boundary | causal 65x65 with 50% backpressure; 32x32 at `O_BASE=0x00000ff0` | Dual tail, partial output strobe, one-beat burst at a 4KB boundary, and split burst. |
| Decode | causal and non-causal random decode with KV length 256; decode smoke | Q length one, long-context decode, causal mode selection, and data checking. |
| Arithmetic | `pwl_corner`, `arith_rounding`, positive/negative saturation | All PWL segments, rounding increments, score-negative clamp, and signed output saturation. |
| Invalid programming | `illegal_config`, `decode_illegal`, `register_access` | Reject illegal prefill/decode start conditions, AXI-Lite error response, partial byte strobe, read-only and unknown register behavior. |
| Write fault / recovery | `axi_bresp_error` | One injected `BRESP=SLVERR`, scheduler error reporting, error clear, and a return to IDLE. |
| PV seed bypass | `tb_fsa_stripe` | Per-row no-valid-key bypass preserves the O-bank seed instead of applying alpha rescale. |

All normal prefill shapes obey `seq_q <= seq_kv`; the generic random test is
the configurable implementation for 32, 64, 65, 256, and 512 token cases.
There is no redundant dedicated two-tile ping-pong test.

### Functional Coverage Result

```sh
urg -dir build/uvm_regression/coverage.vdb \
  -report build/uvm_regression/urg_gap_analysis -format text \
  -group maxmissing 100 -group show_bin_values
```

This command produced the following signoff result:

| Covergroup | Result |
| --- | ---: |
| AXI-Lite register access | 100.00% |
| Tile load / commit / ping-pong phase | 100.00% |
| AXI write burst and strobe behavior | 100.00% |
| Scheduler phase and IRQ behavior | 100.00% |
| Arithmetic and configuration shapes | 100.00% |
| Total functional coverage | **100.00%** |

Functional-coverage signoff is therefore complete for the declared supported
workload and the approved waivers below.

## Coverage Waivers

The following bins are explicitly marked `ignore_bins`.  They are design
invariants, not stimulus gaps; changing an invariant requires removing the
corresponding waiver and adding a test.

| ID | Waived bin | Justification and evidence |
| --- | --- | --- |
| FCOV-AXIL-RESP | AXI-Lite responses `2'b01` and `2'b11` | AXI4-Lite has no EXOKAY, and `accel_regfile` only drives OKAY (`00`) or SLVERR (`10`). Both reachable values are tested. |
| FCOV-AXIL-READ-ADDR | read direction crossed with write-address bins | The address coverpoint deliberately samples only writes; reads are checked directly by `register_access`. |
| FCOV-PHASE-IRQ | nonterminal IRQ-high and terminal IRQ-low pairs | `irq_o` is the scheduler done/error indication. A terminal state asserts it and nonterminal states cannot; valid terminal and error paths are covered. |
| FCOV-AXI-ONE-BEAT | `AWLEN=0` crossed with non-last W beat | A one-beat AXI burst has exactly one `WLAST` beat. The 4KB-boundary test covers the legal one-beat transaction. |
| FCOV-PREFILL-QGTKV | prefill many-Q / one-KV tile shape | The supported prefill contract is `seq_q <= seq_kv`; the random sequence rejects the inverse shape before programming the DUT. Decode is represented separately as Q=1. |
| FCOV-EXP-ONE | no `exp(score-max)=1` sample | Every valid softmax row contains at least one maximum-score lane, which produces `exp(0)=1`; empty rows are not legal attention rows. |
| FCOV-SCORE-POSITIVE-SAT | positive or dual score saturation | The score scaler receives `score-max` or `m_old-m_new`, both non-positive by construction. Negative clamp and unsaturated cases are exercised. |

The corrected long causal valid-lane bin is `512 * 513 / 2 = 131328`; it is
covered and is not a waiver.

## Code Coverage Status and Closure Plan

The same clean integration VDB reports the following code coverage on the
`tb_top` DUT hierarchy:

| Metric | Coverage |
| --- | ---: |
| Line | 92.03% |
| Condition | 71.71% |
| Toggle | 92.22% |
| Branch | 87.67% |
| Combined DUT score | **85.91%** |

The 95% code-coverage target is **not yet met**.  The 100% functional result
must not be used as a substitute for that target.  The report-wide score
(88.56%) also includes testbench instrumentation, while the module-definition
summary (77.28%) contains uninstantiated or parameter-generic definition
artifacts; neither is the DUT signoff scope.

### Direct Module Coverage Collection

`make -C tb/sim module-cov` runs 23 module TBs with line, condition, toggle,
and branch instrumentation. It writes an independent report below
`tb/sim/build/module_coverage/<test>/urg` for each test; the concise measured
summary is `tb/sim/build/module_coverage/summary.txt`. The 2026-07-24 run had
23 passes and no failures.

These are diagnostic module reports, not an automatic supplement to the
`tb_top` hierarchy. Several unit TBs deliberately use reduced parameters, so
blind URG `-map` merging produces shape-mismatch exclusions. A future merge
must use a reviewed instance mapfile whose source and destination parameters
are identical. Until then `uvm_regression/coverage.vdb` remains the only
authoritative integration VDB.

The module reports identify the next directed-test priorities:
`qkv_tile_cache` is 36.25% condition and 6.25% toggle, `fsa_stripe` is 50.00%
condition and 3.68% toggle, and the AXI master is 69.74% condition and 13.91%
toggle. The AXI master line coverage is already 89.08%; its missing cases are
primarily ready/response state combinations rather than unexecuted lines.

Closure work is ordered as follows:

1. Use `make -C tb/sim module-cov` to retain code-instrumented reports for
   `accel_regfile`, `accel_scheduler`, `axi4_master_write`,
   `pingpong_buffer`, `qkv_tile_cache`, output/O banks, `fsa_controller`, and
   `perf_counter`. Add ready/response permutations, error inputs, empty/full
   transitions, register error branches, and SRAM port behavior that legal
   top-level traffic cannot activate.
2. Add directed module fault cases for cache protocol error, fused-array
   controller error, softmax error, scheduler abort/recovery, counter clear,
   and AXI ready/response permutations. Retain the top-level `axi_bresp_error`
   test as the end-to-end recovery proof.
3. Review the remaining line/condition/toggle/branch exclusions one by one.
   Waive only reset-only, parameter-disabled, synthesis-only, or formally
   unreachable logic with RTL references and an owner approval; do not waive a
   legal data-path or bus protocol transition.
4. Create an explicit parameter-compatible URG instance mapfile, then re-run
   the clean regression and mapped URG report. Code signoff requires each
   scoped metric (line, condition, toggle, branch) to be at least 95%,
   functional coverage to remain 100%, and no unreviewed exclusions.

## AXI Write Error Recovery

`axi4_master_write` now accepts `clear_error_i`.  In its error state a clear
or new start returns the engine to IDLE and deasserts its sticky error.  The
top level propagates register-file clear/soft-reset to this input and masks the
write-error contribution to `fatal_error_w` during the clear pulse; otherwise
the scheduler would be forced straight back into ERROR.  This is covered both
by `fa_axi_bresp_error_test` and by `tb/module_tb/axi/tb_axi4_master_write.sv`,
which checks normal bursts, a 4KB split, SLVERR, and recovery.
