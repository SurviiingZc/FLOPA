# SmolLM2 PS+PL End-to-End Data Flow

## Execution Boundary

The benchmark runs the full 64-token SmolLM2 prefill graph. The PS executes tokenization,
embedding, projections, RoPE, normalization, MLP, residual operations, and final logits. PL
replaces the 30 `GGML_OP_FLASH_ATTN_EXT` nodes only.

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

The model contract is fixed at `seq=64`, `head_dim=64`, nine Q heads, and three KV heads. The PS
expands K and V to nine heads for the MHA-only RTL interface. One 144 KiB XRT BO contains:

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

The mover reads 90 tiles in one command. Each Q head uses ten transfers:

```text
Q0 K0 V0 K1 V1 Q1 K0 V0 K1 V1
```

The first five transfers supply and prefetch the two KV tiles for Q0. Q1 is prefetched before
Q0 finishes. The final four transfers refill K/V banks after their consumers release them.
AXIS `TREADY` provides cache-credit backpressure, so no PS polling or command submission occurs
between heads.

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

After mover completion and RTL `done`, the host synchronizes the 36 KiB output region once. It
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

## Remaining Bottlenecks

Priority order for the next measurements and changes:

1. Replace PS-side KV expansion with verified native GQA or on-chip K/V multicast. Current mover
   ingress is 180 KiB and the expanded input BO is 108 KiB, while unique model Q/K/V data is
   60 KiB. This requires an explicit RTL feature rather than relaxing configuration checks.
2. Add mover, loader, cache-wait, and compute counters. Separate DDR starvation from occupied
   bank waits before changing buffering or clocks.
3. Use the new phase counters to decide whether quantization needs persistent two-thread or NEON
   packing. Dense tensors already avoid generic per-element addressing and division, but scale
   selection still requires one scan before the quantization/packing pass. A packing CU or fusion
   with Q/K/V projections can remove those PS passes entirely.
4. Remove output repacking by making the PL write a downstream-compatible tensor layout, or by
   moving the immediately following projection/residual operators into PL.
5. Replace the fixed mover schedule with a device-resident descriptor ring while retaining
   cache-credit backpressure. This generalizes sequence length and head count without one PS
   launch per tile.
6. Consider a persistent mover across multiple attention nodes only after handling inter-layer
   dependencies. A node cannot start until the preceding layer has produced its Q/K/V tensors,
   so simply queueing all 30 nodes is not currently valid.
7. Raise the PL clock only after the node-batched board run identifies compute as the limiting
   interval. If DDR or cache waits dominate, frequency alone will not improve throughput.
