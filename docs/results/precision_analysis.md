# 64x64 Precision and PWL Analysis

Run from the repository root:

```bash
make precision-check PRECISION_SEED=301
make pwl-error
```

`precision_64x64.json` contains causal and non-causal 64x64 deterministic
random comparisons. The fixed-point path follows the RTL score-scale
saturation/rounding, eight-segment Q1.15 PWL, reciprocal LUT, tile recurrence,
and signed INT8 output saturation. Only `score_scale` and `out_scale` are
searched; no RTL width or coefficient is changed.

`pwl_error.json` exhaustively scans all 2,049 signed Q8 input codes from -8 to
0 and reports maximum absolute LSB error, RMSE, relative error, and per-segment
error. The reference is mathematical `exp(x)` in the current standard-library
Python environment. A PyTorch FP32 run can reuse the same seed and shape after
installing PyTorch; until then the result must be described as an IEEE floating
point fallback, not a PyTorch measurement.
