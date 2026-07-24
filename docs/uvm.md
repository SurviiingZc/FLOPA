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
