# SmolLM2 Full-Model Benchmark

This directory pins a full `SmolLM2-135M-Instruct` Q8_0 model and llama.cpp revision for
repeatable 64-token prefill tests. Downloaded weights, third-party sources, and build products
remain under `fpga/` and are ignored by Git.

## Prepare

```bash
fpga/models/download_model.sh
fpga/model/scripts/build_aarch64.sh
```

The fetch script checks out the pinned llama.cpp revision and applies
`patches/llama-eval-override.patch`. The patch adds one callback that replaces a graph node and a
second callback that isolates a CPU node between synchronized begin/end profiling events. The
AArch64 executable is written to:

```text
fpga/model/build-aarch64/dit_fa_model_bench
```

The script uses `/usr/bin/cmake` because the CMake bundled with Vitis 2023.1 is too old for the
pinned llama.cpp project.

## Pure PS Baseline

```bash
./dit_fa_model_bench \
    --backend ps \
    --model models/SmolLM2-135M-Instruct-Q8_0.gguf \
    --prompt prompt.txt \
    --threads 2 \
    --warmups 1 \
    --repetitions 5 \
    --output ps.json
```

The runner tokenizes one fixed prompt, uses exactly the first 64 tokens, executes the complete
model, and records prefill latency and the five largest final-token logits. PS mode isolates each
`GGML_OP_FLASH_ATTN_EXT` node in the CPU scheduler and records its synchronized execution time.
Q/K/V projection, RoPE, and output projection are outside this pure Attention interval.

The measured two-thread VCK190 PS baseline has token hash `0x9cdc34b8ae228dac`. Its best and
mean prefill latencies are `1582.531520 ms` and `1584.368627 ms`, for a best rate of
`40.441533 tokens/s`.

## PS+PL Throughput Path

PL mode replaces each `GGML_OP_FLASH_ATTN_EXT` node. The scheduler computes and synchronizes
the Q/K/V-producing graph segment, excludes the attention node from CPU execution, calls PL,
then resumes the downstream CPU graph. CPU attention is not calculated in this path.

SmolLM2 supplies nine Q heads and three KV heads. The host copies each model KV head three
times, programs the MHA-only accelerator as 9Q/9KV, and includes that expansion in the measured
prefill interval.

Each of the 30 attention nodes performs:

- one packed-input BO synchronization;
- one HLS mover XRT `run` containing all 90 input tiles;
- one RTL attention `START` containing all nine Q heads;
- one output BO synchronization and FP32 writeback to the ggml tensor.

The throughput runner does not calculate a CPU attention reference or compare individual
attention values. Those checks were intentionally removed after functional qualification. The
measured `llama_decode` interval still includes required quantization, packing, XRT/PL work,
output conversion, and all non-attention CPU operators.

See `../docs/model_dataflow.md` for the complete path and optimization priorities.

Run PL mode only after booting the `BOOT.BIN` that matches the xclbin:

```bash
sudo ./dit_fa_model_bench \
    --backend compare \
    --xclbin /run/media/mmcblk0p1/dit_fa.xclbin \
    --model models/SmolLM2-135M-Instruct-Q8_0.gguf \
    --prompt prompt.txt \
    --threads 2 \
    --warmups 1 \
    --repetitions 5 \
    --pl-clock-mhz 170 \
    --output results/compare.json
```

`compare` uses three contexts in one process: an unprofiled PS context for an uncontaminated
prefill baseline, a profiled PS context for pure CPU Attention, and a PS+PL context. The terminal
prints only aggregate latency and speedup. JSON retains every repetition and all 30 per-layer
measurements. The reported PL intervals are:

- `attention_end_to_end_ms`: quantization, KV expansion, BO transfers, XRT/MMIO, PL execution,
  and output conversion;
- `attention_core_ms`: accelerator cycle counters divided by `--pl-clock-mhz`;
- per-layer quantization, input sync, setup, hardware wait, output sync, and dequantization.

The hardware clock argument must match the linked xclbin. It is not inferred from the PS clock or
the device maximum clock.

## PS Host Optimizations

The current host keeps one mapped BO for the lifetime of the PL context, reuses one configured
XRT run object, writes static accelerator registers once, and writes only the score scale and
performance reset registers per node. Dense FP32 tensors use direct contiguous access during
quantization and output conversion; quantization also replaces per-element division with a
precomputed reciprocal. These changes preserve the RTL and HLS interfaces.

The next PS-only decisions should be driven by the new phase counters. If quantization dominates,
use two persistent worker threads or an AArch64 NEON tile packer. If BO synchronization dominates,
the useful change is a PL packing CU or projection/packing fusion; double buffering cannot overlap
different transformer layers because the next layer depends on the current Attention output.

## Historical Qualification

The earlier observer-callback implementation calculated CPU attention and then overwrote it
with PL output. It compared 1,105,920 values over 30 nodes and 270 Q heads. At 170 MHz it
reported MAE `0.016733`, RMSE `0.025836`, maximum error `0.842937`, and the same top-1 token 198
as the pure PS result. This is useful numerical evidence but is not a throughput result.

The current node-batched path changes scheduling and data movement, not attention arithmetic.
It must still pass the deterministic hardware test and final-logit sanity check after a matched
runtime rebuild.
