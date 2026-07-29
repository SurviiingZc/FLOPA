# SmolLM2 PS+PL End-to-End Data Flow

## Execution Boundary

The benchmark runs the full SmolLM2 prefill graph at a runtime-selected sequence length. The PS
executes tokenization, embedding, projections, RoPE, normalization, MLP, residual operations, and
final logits. PL replaces the 30 `GGML_OP_FLASH_ATTN_EXT` nodes only.

The pinned llama.cpp scheduler has three callback modes:

- the upstream observer callback computes a node on CPU before calling the user;
- the project override callback excludes a selected node and requires the callback to produce
  its output.
- the project profile callback isolates a selected CPU node and brackets only its synchronized
  backend execution.

PL mode uses only the override callback. For every attention node, the scheduler computes and
synchronizes the preceding CPU subgraph so Q, K, V, and mask inputs are ready. It does not send
the attention node to the CPU backend. After PL writes the node output, the scheduler continues
with the following CPU subgraph.

Pure PS mode uses the profile callback for `GGML_OP_FLASH_ATTN_EXT`. It does not replace any node
or change Attention arithmetic. Isolating the 30 nodes adds scheduler boundaries so the reported
pure Attention interval excludes projections and other preceding graph work. The benchmark uses a
separate unprofiled PS context for prefill latency, so those boundaries do not inflate the PS
end-to-end baseline.

## Per-Node Host Work

The model contract uses `seq=32..1024` in steps of 32, `head_dim=64`, nine Q heads, and three KV
heads. The PS expands K and V to nine heads for the MHA-only RTL interface. At `seq=64`, one
144 KiB XRT BO contains:

| Region | Heads | Bytes |
| --- | ---: | ---: |
| Packed Q | 9 | 36 KiB |
| Packed K | 9 | 36 KiB |
| Packed V | 9 | 36 KiB |
| Output O | 9 | 36 KiB |

The host scans the nine Q heads and three model K/V heads to choose one INT8 scale per tensor.
It quantizes and packs 32-row tiles in `[tile][feature][local_row]` order while copying each
model K/V head into three adjacent accelerator heads. A node-global Q scale and K scale allow
all heads to share one score-scale register. A node-global V scale allows one output conversion.

The host synchronizes the 108 KiB expanded input region once, then resets the hardware and writes
the node-specific score scale. Static addresses, dimensions, strides, and modes are programmed
once when the PL context is created. It starts the loader using a persistent HLS mover run object.
After the loader commits the first Q0/K0/V0 working set, the host sends one RTL `START`.

## PL Work

At `seq=64`, the mover reads 90 tiles in one command. Each Q head uses ten transfers:

```text
Q0 K0 V0 K1 V1 Q1 K0 V0 K1 V1
```

For a general tile count `T=seq/32`, one mover command emits
`9 * T * (1 + 2 * T)` tiles. It sends each Q tile once and follows it with all `T` K/V pairs.
Global Q and K/V transaction numbers select alternating banks. AXIS `TREADY` provides
cache-credit backpressure, so the mover can fill a free bank while PL consumes the other one and
no PS polling or command submission occurs between tiles or heads.

The PS performs this GQA-to-MHA expansion before launching the mover:

```text
accelerator KV0 KV1 KV2 <- model KV0
accelerator KV3 KV4 KV5 <- model KV1
accelerator KV6 KV7 KV8 <- model KV2
```

The host programs `num_q_heads=9` and `num_kv_heads=9`. The RTL scheduler traverses nine heads,
two Q tiles, and two KV tiles after one `START`, for 36 compute tiles. It writes each 4 KiB
output head consecutively and raises `done` only after the ninth head.

## Return To PS

After mover completion and RTL `done`, the host synchronizes the output region once. It
converts INT8 output with the V scale and writes FP32 values directly into the skipped ggml
attention node tensor. Downstream CPU nodes then consume that tensor normally.

The benchmark times the complete `llama_decode` call. It separately records the PL callback,
hardware cycles, and PS-side quantization, input sync, setup, hardware wait, output sync, and
dequantization intervals. The PL callback includes all work required to replace CPU Attention;
the cycle counter contains only accelerator work. Historical per-element CPU comparison remains
excluded because it is not part of inference.

Across one prefill, the current path issues 30 mover commands and 30 RTL starts. The previous
per-head path issued 270 of each, and the original per-tile path issued still more mover
commands.

## Final Board Measurements

| Sequence | PS Attention | PL callback | PL interval | Core speedup | Callback speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| 64 | 92.342 ms | 65.511 ms | 4.673 ms | 19.762x | 1.410x |
| 1024 | 6369.045 ms | 1648.075 ms | 679.180 ms | 9.378x | 3.865x |

These results show that the Attention accelerator is effective. The approximately `20x`
short-sequence core result and `9.378x` long-sequence core result are both much larger than the
complete callback gains. At 1024 tokens, the PS adapter adds `968.89 ms` around the PL interval:
`777.785 ms` for quantization, packing, and GQA expansion, plus `188.388 ms` for output
conversion. BO synchronization and register setup together remain below one millisecond.

The full model retains about `23.81 s` of non-Attention PS execution at 1024 tokens. Optimizing
the Attention adapter is the immediate integration priority; accelerating the remaining PS graph
is the separate requirement for a larger full-model gain.

## Remaining Bottlenecks

Priority order for the next changes:

1. Replace scalar scale selection, quantization, and tile packing with persistent AArch64 NEON
   workers, or move packing into PL and fuse it with Q/K/V projection.
2. Replace PS-side KV expansion with verified native GQA or on-chip K/V multicast. At `seq=64`,
   current mover ingress is 180 KiB and the expanded input BO is 108 KiB, while unique model
   Q/K/V data is 60 KiB. This requires an explicit RTL feature rather than relaxed checks.
3. Remove output conversion by making PL write a downstream-compatible tensor layout, or move
   the immediately following projection/residual operators into PL.
4. Add mover, loader, cache-wait, and compute counters. Separate DDR starvation from occupied
   bank waits before changing buffering or clocks.
5. Consider a device-resident descriptor ring while retaining cache-credit backpressure. Sequence
   length is already runtime-configurable without one PS launch per tile; a ring would instead
   reduce per-node command setup and make more dimensions configurable.
6. Consider a persistent mover across multiple attention nodes only after handling inter-layer
   dependencies. A node cannot start until the preceding layer has produced its Q/K/V tensors,
   so simply queueing all 30 nodes is not currently valid.
7. Improve K/V reuse across Q tiles before raising the PL clock. The current long-sequence mover
   rereads K/V for every Q tile, so frequency alone cannot remove its quadratic traffic.
