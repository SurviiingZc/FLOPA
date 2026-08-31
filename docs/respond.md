# Review Response and P0 Evidence

This document answers the preliminary-review comments against the delivered
RTL and reports. The status is based on the current repository at commit
`1487f4f` and distinguishes implemented behavior from missing evidence and
future architectural work.

## P0 work completed in this round

Three reproducible analysis entry points were added:

```text
make precision-check       # deterministic 64x64 FP32/fixed-point comparison
make pwl-error              # exhaustive [-8,0] PWL error scan
make ppa-breakdown          # DC hierarchy and Vivado resource extraction
```

Results are kept under `docs/results/`:

- `precision_64x64.json`: causal and non-causal 64x64 comparison, including
  searched `score_scale` and `out_scale` encodings.
- `pwl_error.json`: 2,049-point scan of the implemented eight-segment PWL.
- `ppa_breakdown.json`: five valid top-level DC hierarchy entries and 3,872 Vivado
  hierarchy entries, with source report paths recorded in the JSON.

The precision script uses the exact RTL numeric contract: signed INT8 Q/K/V,
INT32 score accumulation, score-scale saturation/rounding, Q1.15 PWL
probability, reciprocal-LUT normalization, and INT8 output saturation. The
mathematical reference is IEEE double precision in the current Python 3.6
server environment. If PyTorch is installed later, the same deterministic
inputs can be used as a PyTorch FP32 cross-check; no PyTorch result is claimed
until that environment is available.

## Point-by-point response

### 1. Scheduling

**Lookahead prefetch:** Partially implemented. The VCK190 mover and UVM
sequence use consumption-driven ping-pong refill: Q starts after its last QK
consumer, K after QK, and V after PV. Audit paths are
`fpga/docs/pingpong_streaming.md`, `docs/verification_report.md` section 4.1,
`rtl/memory/qkv_tile_cache.v`, and `tb/uvm/sequences/attention_sequences.svh`.
There is no explicit next-next descriptor or deadline/credit scheduler in the
RTL FSM. Follow-up work is to add a lookahead descriptor register and cache
credit/deadline checks without changing the PE protocol.

**Online inference:** Partially implemented. Single-query MHA decode is
implemented and verified through 256 KV tokens. Audit paths are
`rtl/control/accel_scheduler.v`, `rtl/attention_accel_top.v`,
`docs/verification_report.md`, and `tb/uvm/tests/attention_tests.svh`.
Full autoregressive integration, KV append, and native GQA decode remain open.

**Priority scheduling:** Not implemented. The accelerator is a single-job
engine; no multi-request QoS or arbitration requirement exists in the current
interface. It is lower priority than decode/GQA and board evidence.

### 2. MAC/PE optimization

**INT16/BF16 mixed precision:** Not implemented and not a small extension.
The delivered PE is INT8 with one phase-shared 17x9 multiplier, Q1.15
probabilities, and INT32 state. BF16 would require exponent alignment,
normalization, rounding, and a separate verification contract. A separate
compile-time precision branch should only be considered after the INT8 design
is frozen.

**Multi-stage pipeline:** Already implemented. `score_scale_pipe.v`,
`pwl_exp_unit.v`, `fa_*_mult_pipe2.v`, and `online_normalizer.v` break the
critical arithmetic into registered stages while retaining II=1. The ASIC TT
logical target is 1.60 ns; further stages should be justified by post-route
timing, not added speculatively.

**Zero-value skip:** Only invalid/padded/causal lanes are suppressed today.
Actual numeric zero operands are not dynamically skipped. The safe follow-up
is tile-level all-zero detection and operand isolation/clock enable; individual
PE bubbles would disrupt the fixed systolic schedule.

### 3. Precision

**BF16/FP16 path:** Not implemented; same high-risk assessment as item 2.

**Calibration and error analysis:** Implemented as a first reproducible pass in
`scripts/precision/attention_precision.py`. It searches only `score_scale` and
`out_scale`; RTL widths, PWL coefficients, and formats are unchanged. The
fixed-point path models the RTL score-scale saturation and rounding, Q1.15 PWL
probability, 32-token online recurrence, reciprocal LUT, output scaling, and
signed INT8 saturation. The selected 64x64, seed-301 results are:

| Mode | Selected score scale | Selected output scale | MAE | RMSE | Max error | Cosine |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| non-causal | `0x00080400` | `0x000f0001` | 1.948 LSB | 2.326 LSB | 4 LSB | 0.999943 |
| causal | `0x00080800` | `0x000f0001` | 1.974 LSB | 2.349 LSB | 4 LSB | 0.999941 |

These results show that, at this deterministic 64x64 test point, the fixed-point
output preserves the high-precision Attention direction very closely and every
INT8 output differs by at most four codes. The companion RTL run
`fa_random_qkv_test`, seed 301, also completed 128/256/256 Q/K/V loader words
and 4,096 output bytes with zero UVM errors and fatals. That UVM result proves
the DUT remains bit-exact to its SystemVerilog fixed-point reference; the
floating-point comparison separately quantifies algorithmic approximation.

The result does not establish accuracy for every random seed, sequence length,
activation distribution, or real model. The different best causal and
non-causal score scales also show that this is dataset-specific calibration,
not yet a universal deployment scale. A multi-seed calibration set and a
held-out validation set are required before freezing one shared register value.

**PyTorch FP32 comparison:** The deterministic floating-point baseline is now
available, but the server lacks `torch`. Install PyTorch and rerun
`make precision-check` in a PyTorch-enabled environment before claiming a
PyTorch result in a paper or presentation. The current JSON explicitly records
`reference_backend=python-ieee754-fallback`; it is valid as a mathematical
high-precision baseline but is not presented as a PyTorch execution result.

### 4. Softmax

**LSE-Softmax:** Functionally, the design already uses the numerically stable
online recurrence `(m,l,O)` with max subtraction and cross-tile rescaling.
Audit paths are `rtl/compute/fsa_fused_array.v`,
`rtl/softmax/online_normalizer.v`, and `docs/design_specification.md` section
2. The RTL does not expose an explicit `LSE = m + log(l)` output, so the safe
claim is “LSE-equivalent online softmax,” unless an optional LSE output is added.

**Approximation precision:** The current eight-segment PWL is scanned by
`make pwl-error`; the result is `docs/results/pwl_error.json`. Across all 2,049
Q8 input codes on `[-8,0]`, the current unit-width interpolation has a maximum
absolute error of 2,555.11 Q1.15 LSB and an RMSE of 708.01 LSB. The largest
error occurs in segment 0, nearest zero, while the absolute error falls in the
later low-probability segments.

The end-to-end Attention error is much smaller than this standalone worst case
because row normalization and final INT8 quantization attenuate part of the PWL
error. This does not mean the PWL itself is already optimal. The next
approximation revision should prioritize segment 0, compare non-uniform
breakpoints or refitted coefficients, and accept a change only if it improves
both the exhaustive exp scan and held-out end-to-end Attention results without
reducing II=1 or increasing the current three-cycle PWL latency. Every accepted
coefficient set must also pass `tb_pwl_exp_unit` and the complete UVM regression.

**Post-CTS signoff:** Not yet available. Current ASIC evidence is DC logical
synthesis; current FPGA evidence is Vivado post-route. A real ASIC claim
requires placement, CTS, SPEF extraction, propagated-clock STA, and signoff
reports.

### 5. Data reuse

**Cache capacity:** The default cache already contains 4 KiB Q, 4 KiB K, and
4 KiB V storage, with 8 KiB combined K/V capacity, satisfying the stated
capacity requirement. Expansion should follow measured DDR refill stalls, not
capacity alone.

**Cross-tile state persistence and block merge:** Implemented. Persistent
feature-addressed O banks and online `m/l/O` state perform
`l_new=alpha*l_old+block_l` and `O_new=alpha*O_old+PV` across KV tiles. Audit
paths are `rtl/memory/o_accumulator_bank.v`, `rtl/compute/fsa_fused_array.v`,
`docs/design_specification.md` sections 2 and 3.

### 6. Extensibility

**Native GQA:** Not implemented. START validation currently rejects unequal Q
and KV head counts; the VCK190 host expands 3 KV heads to 9 MHA heads. The
follow-up design is a runtime `q_head -> kv_head` mapping with KV multicast and
verification for prefill and decode.

**VCK190 board power:** Not measured. `fpga/vivado/build/reports/power_1.rpx`
is a Vivado estimate container and must not be presented as board measurement.
The required follow-up is PMBus/XRT rail sampling for idle, prefill, decode,
and DMA-only windows.

**Larger batch/head:** Geometry is parameterized at elaboration, but the
delivered runtime contract is batch-1, 32x32 tiles, and head dimension 64.
Larger configurations require compile-time builds and additional bandwidth and
cache validation.

### 7. Engineering规范

**Post-CTS report:** Missing for the same reason described in item 4.

**Per-module area:** Completed in this round. `ppa_breakdown.py` parses the DC
hierarchy and the Vivado post-route hierarchy. The principal DC areas are:

| Module | Global cell area | Share |
| --- | ---: | ---: |
| `u_fused_array` | 2,047,098.32 | 84.0% |
| `u_tile_cache` | 272,167.50 | 11.2% |
| `u_normalizer` | 56,122.75 | 2.3% |
| `u_output_buffer` | 53,423.63 | 2.2% |

The raw machine-readable breakdown is `docs/results/ppa_breakdown.json`; the
source is `asic/dc/.../reports/area.rpt`.

**Vector-based power:** Substantially implemented through mapped-netlist
gate-SAIF and Power Compiler. The reportable workload result is documented in
`docs/ppa_and_optimization.md`; the DC `power.rpt` parsed by this round is
vectorless and is retained only as a diagnostic baseline. Multiple-mode SAIF
and board measurements remain follow-up work.

### 8. File completeness

The FSA implementation guide already exists at `docs/rtl.md`, and the PPA,
verification, register, and FPGA reports are linked from `README.md` and
`docs/README.md`. Missing artifacts are the real post-CTS report and a native
GQA design/verification document. This response file and the machine-readable
P0 results are now added to close the review traceability gap.

## Priority decision

1. **P0:** PyTorch-enabled 64x64 comparison, calibration/error report, PWL
   error evidence, per-module area/power tables, native GQA design and RTL,
   complete autoregressive decode, VCK190 board power, and ASIC post-CTS flow.
2. **P1:** Explicit lookahead descriptors, bandwidth-driven cache expansion,
   tile-level zero skip, and multi-mode SAIF campaigns.
3. **P2:** INT16/BF16/FP16 datapaths, multi-job priority scheduling, and fully
   variable batch/head runtime support.
