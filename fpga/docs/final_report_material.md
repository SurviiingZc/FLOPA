# FLOPA VCK190 Evaluation Report

## Executive Summary

FLOPA has a measured `19.762x` Attention-core speedup on the final 64-token SmolLM2 workload.
The isolated two-thread PS Attention time is `92.342 ms`, while the complete PL cycle-counter
interval is `4.673 ms` across all 30 layers at 170 MHz. This approximately `20x` result is the
primary accelerator result.

The current 64-token full-model speedup is only `1.008x`. Required PS quantization, packing,
GQA-to-MHA expansion, output conversion, and the non-Attention model graph hide most of the core
gain. The result identifies a software-integration bottleneck, not a failure of the Attention
datapath. Removing these conversions and accelerating the remaining graph can turn a much larger
fraction of the demonstrated core speedup into end-to-end throughput.

At 1024 tokens, Attention occupies a larger fraction of execution. The measured core, callback,
and full-prefill speedups are `9.378x`, `3.865x`, and `1.185x`, respectively.

## Test Configuration

| Item | Configuration |
| --- | --- |
| Board | AMD VCK190 |
| OS | PetaLinux 2023.1 |
| Platform | `xilinx_vck190_base_202310_1` |
| Toolchain | Vivado/Vitis 2023.1 |
| PL clock | 170 MHz |
| Model | SmolLM2-135M-Instruct, Q8_0 GGUF |
| Model dimensions | 30 layers, 9 Q heads, 3 KV heads, head dimension 64 |
| CPU configuration | 2 Cortex-A72 threads |
| PL Attention interface | 9 Q heads and 9 PS-expanded KV heads |
| Tile shape | 32 rows by 64 elements, INT8 |

The boot image and xclbin come from one Vitis link against the common platform. Runtime loading
uses the xclbin metadata that matches the design already configured by `BOOT.BIN`; it does not
attempt to replace the full PL image dynamically.

## Measurement Boundary

The benchmark uses three contexts in one process:

1. An unprofiled PS context measures uncontaminated full-model prefill.
2. A profiled PS context isolates the 30 `GGML_OP_FLASH_ATTN_EXT` nodes.
3. A PS+PL context excludes each CPU Attention node and writes PL output into its tensor.

The PS+PL path does not calculate CPU Attention and does not perform an element-wise comparison
inside the timed interval. Numerical comparison was completed during earlier qualification and
was removed before throughput measurement.

The reported intervals have distinct meanings:

| Interval | Contents |
| --- | --- |
| PS prefill | Complete unprofiled `llama_decode` |
| PS Attention | Synchronized CPU execution of the 30 Attention nodes |
| PS+PL prefill | Complete model with all Attention nodes replaced by PL |
| PL callback | Quantization through output conversion for all 30 nodes |
| PL core | RTL performance-counter cycles divided by 170 MHz |

The generated Vitis files retain the legacy `dit_fa_*` prefix for build and
runtime compatibility; all such artifacts in this repository implement FLOPA.

## Runtime-Configurable Streaming

The model host and HLS mover accept a sequence length from 32 through 1024 in steps of 32. For
`T = sequence_length / 32`, one Attention node uses:

```text
mover tiles  = 9 * T * (1 + 2 * T)
compute tiles = 9 * T * T
```

For each Q tile, the mover emits the Q tile once and then all K/V pairs required by that query.
Q and K/V transaction numbers select alternating cache banks. AXIS backpressure acts as a credit
signal, allowing the mover to fill a free bank while PL consumes the other bank. One mover run and
one RTL `START` cover a complete Attention node, so tile count does not increase XRT launch count.

Ping-pong hides mover-to-PL refill latency when compute provides enough slack. It cannot hide the
PS work that produces the next transformer's Q/K/V tensors because that work depends on the
current layer's Attention output.

## Measured Results

### Sequence Length 64

This final test used one warmup and one measured repetition. Both paths used token hash
`0x9cdc34b8ae228dac` and produced top-1 token 198.

| Metric | PS | PS+PL | Speedup |
| --- | ---: | ---: | ---: |
| Full prefill | 1582.633 ms | 1570.297 ms | 1.008x |
| Attention callback | 92.342 ms | 65.511 ms | 1.410x |
| Attention core | 92.342 ms | 4.673 ms | 19.762x |

The PS+PL callback breakdown is:

| Phase | Time | Callback share |
| --- | ---: | ---: |
| Quantize, pack, and expand KV | 47.189 ms | 72.03% |
| Input BO synchronization | 0.456 ms | 0.70% |
| Register and run setup | 0.207 ms | 0.32% |
| Host-observed hardware wait | 6.145 ms | 9.38% |
| Output BO synchronization | 0.072 ms | 0.11% |
| Dequantize and write output | 11.439 ms | 17.46% |

Software work around the core is approximately `60.84 ms`, or `13.02x` the PL core interval.
This is why the `19.762x` arithmetic result becomes only a `1.008x` full-model result at 64
tokens.

### Sequence Length 1024

This test used one warmup and one measured repetition. Both paths used token hash
`0x4cc59f650e91370c` and produced top-1 token 15595. One Attention node used 18,720 mover tiles
and 9,216 compute tiles.

| Metric | PS | PS+PL | Speedup |
| --- | ---: | ---: | ---: |
| Full prefill | 30178.154 ms | 25476.343 ms | 1.185x |
| Attention callback | 6369.045 ms | 1648.075 ms | 3.865x |
| Attention core | 6369.045 ms | 679.180 ms | 9.378x |

The PS+PL callback breakdown is:

| Phase | Time | Callback share |
| --- | ---: | ---: |
| Quantize, pack, and expand KV | 777.785 ms | 47.19% |
| Input BO synchronization | 0.567 ms | 0.03% |
| Register and run setup | 0.242 ms | 0.01% |
| Host-observed hardware wait | 680.993 ms | 41.32% |
| Output BO synchronization | 0.097 ms | 0.01% |
| Dequantize and write output | 188.388 ms | 11.43% |

The non-Attention model interval remains approximately `23.81 s` in both paths. Conversion and
host overhead add `968.89 ms` around the `679.18 ms` core interval, explaining why the full-model
gain remains lower than the isolated Attention speedup.

## Interpretation

The core speedup and end-to-end speedup answer different questions. The `19.762x` result at 64
tokens and `9.378x` result at 1024 tokens show that the implemented Attention engine performs the
selected work much faster than two PS cores. The smaller callback and full-model gains show that
the current integration still pays PS conversion costs and leaves projections, normalization,
feed-forward layers, residual operations, and scheduling on the PS.

The 64-token result also has a strict Amdahl-law limit. Replacing `92.342 ms` of PS Attention with
an ideal `4.673 ms` core, while leaving the rest of the PS prefill unchanged, gives only about a
`1.06x` upper bound before integration overhead. At 1024 tokens, the measured Attention fraction
increases from about 6% to 21%, so the demonstrated full-model gain rises to `1.185x`. The PL core
speedup falls at the longer sequence because the CPU flash-Attention kernel becomes more efficient
at larger matrices while the current mover repeats external K/V reads for every Q tile.

Within the Attention replacement itself, the immediate bottleneck is the PS adapter. At 1024
tokens, quantization, packing, GQA expansion, and output conversion account for almost all of the
`968.89 ms` difference between the `1648.075 ms` callback and `679.180 ms` PL interval. Removing
that envelope would let the complete Attention path approach the demonstrated core acceleration.
The remaining `23.81 s` non-Attention PS graph is a separate full-model optimization target.

## Optimization Roadmap

1. Replace scalar packing with persistent AArch64 NEON workers, combining scale selection,
   quantization, tile transpose, and KV duplication where possible.
2. Add native GQA or on-chip KV multicast so three model KV heads do not become nine PS copies.
3. Move packing into PL or fuse it with Q/K/V projection to remove PS tensor scans and input
   layout conversion.
4. Produce the downstream tensor layout directly or fuse the output projection, eliminating the
   FP32 output scatter.
5. Add mover, DDR-wait, cache-credit, and scheduler-stall counters before increasing buffering.
6. Improve K/V reuse across Q tiles to reduce the current repeated external-memory reads.
7. Profile and accelerate non-Attention operators that dominate short-prefill model latency.

The first four items directly attack the measured `60.84 ms` and `968.89 ms` software envelopes.
A descriptor ring or persistent command processor may reduce per-node setup, but it cannot remove
true inter-layer dependencies and should not be presented as a substitute for packing and graph
integration.

## Reproducible Artifacts

| Artifact | Repository-relative location |
| --- | --- |
| Matched boot image, xclbin, and deterministic host | generated under `fpga/vitis/build/runtime` |
| Routed timing, HLS, build, and xclbin evidence | generated under `fpga/vitis/build/reports/release-20260729` |
| AArch64 model host, prompts, runner, and checksums | `fpga/model/deploy` |
| Pinned model manifest and downloader | `fpga/models` |
| Sequence-64 raw board result | `fpga/model/results/compare-seq64-20260729.json` |
| Sequence-1024 raw board result | `fpga/model/results/compare-seq1024-20260729.json` |

Run `sha256sum -c SHA256SUMS` inside each deployable directory before copying it to the SD card.
The model weights remain a separate, hash-pinned file to avoid duplicating the 135 MB GGUF in the
small model payload.

## Evidence And Limitations

- The 64-token raw JSON and console log are retained under `fpga/model/results`.
- The 1024-token raw JSON and console log are retained under `fpga/model/results`.
- Both final results have one measured repetition and should be repeated for variance analysis.
- Final routed LUT/FF/DSP/BRAM/URAM totals and board power were not retained as reportable evidence.
- The deterministic hardware test must pass after every matched boot-image/xclbin deployment.
- Earlier numerical qualification compared more than one million values and matched top-1 output.
- Final-logit agreement is a sanity check, not an exhaustive replacement for tensor-level tests.
- One ZOCL boot warning about interrupt index 63 remains documented; the device reports ready and
  every exercised kernel completes, so it is a residual risk rather than a demonstrated failure.
- Results describe batch-1 prefill on the stated model, clock, software, and board configuration.
