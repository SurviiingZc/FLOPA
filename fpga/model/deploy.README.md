# FLOPA Model Test Payload

Verify this payload and the separately installed model before running it:

```bash
sha256sum -c SHA256SUMS
sha256sum /path/to/SmolLM2-135M-Instruct-Q8_0.gguf
```

Compare the model hash with `model_manifest.json`. Boot the matching runtime first, then run the
default 1024-token test with one warmup and one measured repetition:

```bash
MODEL_PATH=/path/to/SmolLM2-135M-Instruct-Q8_0.gguf ./run_board_compare.sh
```

The first positional argument selects another supported sequence length. Environment variables
configure paths and measurement settings without rebuilding the host. The long prompt is used by
default and truncated to the selected length. Set `PROMPT_PATH=prompt_64.txt` to reproduce the
final 64-token input:

```bash
MODEL_PATH=/path/to/SmolLM2-135M-Instruct-Q8_0.gguf \
PROMPT_PATH=prompt_64.txt WARMUPS=1 REPETITIONS=1 ./run_board_compare.sh 64
```

Supported variables are `BENCH_PATH`, `XCLBIN_PATH`, `MODEL_PATH`, `PROMPT_PATH`, `OUTPUT_DIR`,
`THREADS`, `WARMUPS`, `REPETITIONS`, `PL_CLOCK_MHZ`, and `SEQUENCE_LENGTH`. Results and full logs
are written under `results/` with sequence length and timestamp in each filename.
