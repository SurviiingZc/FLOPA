# Ping-Pong Tile Streaming

## Scope

The current protocol implements the SmolLM2 prefill attention node:

- `seq=32..1024` in steps of 32 and `head_dim=64`;
- nine Q heads and nine PS-expanded KV heads at the accelerator interface;
- 32-row Q and KV tiles;
- one HLS mover command and one RTL `START` per attention node;
- `9 * (seq / 32)^2` compute tiles per attention node.

The change affects data movement and multi-head control. The attention arithmetic datapath is
unchanged.

## Node Schedule

The HLS mover and RTL loader use a 128-bit AXIS interface. At the routed
170.019 MHz clock, its peak interface bandwidth is 2.720 GB/s. One 32-by-64
INT8 tile is 2048 bytes, or 128 AXIS beats. HLS requests one 128-beat
AXI burst per tile and sustains an inner-loop initiation interval of one.

At `seq=64`, each Q head emits this ten-tile sequence:

| Position | Tile | Role |
| --- | --- | --- |
| 0 | Q0 | Initial Q working set |
| 1 | K0 | Initial K working set |
| 2 | V0 | Initial V working set and `START` watermark |
| 3 | K1 | Prefetch during Q0 compute |
| 4 | V1 | Prefetch during Q0 compute |
| 5 | Q1 | Prefetch before Q0 completes |
| 6 | K0 | Refill after the first QK consumes K0 |
| 7 | V0 | Refill after the first PV consumes V0 |
| 8 | K1 | Refill after the second QK consumes K1 |
| 9 | V1 | Final refill for the Q head |

The complete node is 90 tiles and 180 KiB of mover reads. Before synchronization, the PS
duplicates model KV head 0 into accelerator heads 0-2, head 1 into heads 3-5, and head 2 into
heads 6-8. The packed input BO is 108 KiB. The mover then reads Q, K, and V with matching head
indices, so the RTL remains a nine-head MHA design.

The PS arms the loader and launches the mover once. After Q0/K0/V0 for the first head commit,
it sends one RTL `START`. The RTL scheduler advances all nine heads internally and asserts
`done` only after the final head. No PS command is issued between heads.

## Stream Protocol

Each AXIS beat carries four `TUSER` bits:

| Bits | Meaning |
| --- | --- |
| `[1:0]` | Cache kind: Q=0, K=1, V=2 |
| `[2]` | Ping-pong bank |
| `[3]` | Last tile in the complete mover job |

`TLAST` marks the final beat of each 128-beat tile. The loader rejects partial `TKEEP`, early
or missing `TLAST`, invalid kinds, and metadata changes within a tile. Loader version
`0x00020000` identifies this self-describing protocol.

The loader tile counter advances only when the cache samples the commit pulse. A PS-visible
watermark therefore guarantees that the corresponding bank-valid state is visible to the
scheduler.

## Ownership And Backpressure

Each Q, K, and V ping-pong controller exposes both bank-valid bits. The cache accepts writes
only when the target bank is invalid. If the mover reaches a live bank, `TREADY` goes low and
the HLS pipeline pauses without losing or reordering data.

The scheduler releases banks at their actual last use:

- K is released after QK;
- V is released after PV;
- Q is released after all KV tiles for that Q tile.

This is a hardware credit protocol. Correctness does not depend on a fixed DDR or compute-cycle
estimate.

## Verification Status

The loader/cache integration test covers the ten-tile per-head schedule and occupied-bank
backpressure. The scheduler test covers one-`START` multi-head MHA traversal. Run both tests
with:

```bash
make -C fpga pingpong-sim
```

The Vitis 2023.1 HLS build reports `II=1` and estimates 232.89 MHz for the mover loop.
The AArch64 model and deterministic hosts compile with warnings as errors, and both kernels
package as XO files. The final 170 MHz runtime passed the deterministic four-tile test twice with
2942 cycles, zero stalls, ten loaded tiles, and byte-for-byte output agreement.

The full-model board test measured `19.762x` PL-core acceleration at 64 tokens and `9.378x` at
1024 tokens. The lower long-sequence ratio reflects both improved CPU flash-Attention efficiency
and repeated K/V mover traffic; it is still a strong accelerator result. The larger immediate
gap is in PS adaptation: at 1024 tokens, the callback is `968.89 ms` longer than the PL interval
because quantization, packing, GQA expansion, and output conversion remain on the PS.

## Generalization

Sequence length and Q/KV tile counts are runtime arguments. The mover emits
`9 * T * (1 + 2 * T)` tiles for `T=seq/32`, while the RTL scheduler performs `9 * T^2`
compute tiles. Further generalization should retain the same ownership protocol and may replace
the nested schedule with descriptors:

1. Describe tensor kind, bank, DDR offset, beat count, and job boundary.
2. Start compute at the minimum valid working-set watermark.
3. Order prefetches by the next consumer deadline.
4. Use bank-valid credits rather than PS timing or sleeps.
5. Keep DDR, mover, AXIS, and loader widths aligned to maximum-length bursts.
6. Count accepted AXIS beats, cache waits, DDR waits, scheduler stalls, and compute separately.

A persistent mover or descriptor ring could reduce the remaining one command per attention node.
Add buffering only after counters show producer jitter exceeds the available compute slack.
