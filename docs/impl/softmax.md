# Softmax Datapath Design

## 1. Scope

This document defines the implementation strategy for the softmax path:

- `rtl/softmax/pwl_exp_unit.v`
- `rtl/softmax/reciprocal_lut.v`
- `rtl/softmax/online_normalizer.v`
- `rtl/compute/fsa_fused_pe.v`
- `rtl/compute/fsa_fused_array.v`

The online-softmax control, row maximum, score subtraction, probability
writeback, row sum, and `(m,l)` update are integrated into
`fsa_fused_array`. Only the 32-lane PWL exp pipeline is shared outside the
PEs; final reciprocal normalization remains a separate pipelined output stage.

## 2. Design Basis

The softmax path should follow the FlashAttention online-softmax recurrence and the systolic-array-friendly implementation style described in recent hardware work.

Key observations:

- FlashAttention tiles attention so that intermediate score and probability matrices are not written out.
- Online softmax updates row max and row sum block by block.
- SystolicAttention shows that rowmax and rowsum can be implemented as reduction operations and that exp inputs are always non-positive after max subtraction.

Implications:

1. Do not materialize full S or P matrices.
2. Keep row state in registers.
3. Use block-wise recurrence.
4. Make the exp domain explicit and limited.
5. Keep reductions and score/probability storage inside the array, with only the
   shared exp and final normalizer as separate registered pipelines.

## 3. High-Level Organization

The softmax schedule is controlled as a registered array phase. Data remains in
the PE fabric except while a row is passing through the shared exp pipeline.

Recommended macro stages:

1. Mask.
2. Row max.
3. Score shift.
4. Exp approximation.
5. Row sum.
6. LSE update.
7. Beta stream formatting.
8. Final normalization.

Each stage should have clear input/output registers.

## 4. Row State

Each query row needs a small persistent state structure, typically including:

- `m`: running maximum.
- `l`: running normalizer sum.
- optional mode / scale / mask flags.

### 4.1 Design Rules

- Keep row state in registers, one entry per active row lane.
- Update row state only at documented boundaries.
- Read current row state through the registered narrow request/response port.
- Do not let row state be recomputed combinationally from a distant stage.

The implemented interface returns one row's `alpha` and `l` one cycle after a
tagged request. PV and final normalization arbitrate the port at the top level;
the full row-state vectors do not leave the fused array.

## 5. Mask Stage

### 5.1 Purpose

The mask stage removes illegal score positions before any max or exp operation.

### 5.2 Design Rules

- Apply causal masking before row max.
- Masked elements must not participate in rowsum.
- Represent masked values using a safe minimum fixed-point pattern.
- Precompute and register one bounded thermometer mask per query row during QK
  setup; do not replicate full-width key/query comparisons in every lane.

### 5.3 Timing Rule

The mask stage should be a short local stage with no large fanout. It should not sit on the critical reduction path.

## 6. Row Reduction

### 6.1 Purpose

Row reduction computes row maximum and row sum.

### 6.2 Preferred Structure

Use the registered PE-to-PE row path. It is a systolic reduction, not a
single-cycle combinational chain.

Implemented structure:

- column `c` receives the registered partial max/sum from column `c-1`;
- each column completes one cycle later than its left neighbor;
- the path is cut by a register at every PE;
- all rows reduce in parallel.

This style matches the common systolic-array pattern and keeps timing manageable.

### 6.3 Shared Hardware Option

The max and sum paths may share the same physical tree skeleton, with the operation selected by mode bits.

### 6.4 Timing Rule

Do not compute rowmax and rowsum in one long combinational path. Insert a register cut between reduction levels if needed.

## 7. Exp Approximation

### 7.1 Range Assumption

After subtracting row max, the input to exp is non-positive. This is a core simplification and should be used directly in the implementation.

### 7.2 Recommended Hardware Shape

Use a small pipelined PWL or LUT-plus-interpolation unit.

Implemented three-stage pipeline:

1. Absolute value, range/segment decode, endpoint selection, and registered
   `base_lo-base_hi` plus fraction.
2. Isolated registered 16x8 interpolation multiply.
3. Shift, 32-bit endpoint subtraction, saturation, and output register.

### 7.3 Design Rules

- Optimize only the non-positive input domain.
- Keep the segment count modest and synthesis-friendly.
- Do not instantiate a general-purpose floating-point exp.
- Keep the same approximation policy for every lane.

### 7.4 Timing Rule

Exp should be a dedicated multi-cycle or multi-stage pipe. It should never sit directly after a wide reduction with no register cut.

The implemented exp source is a registered 32-row delta-column assembled from
four fixed eight-row stripe slices. An eight-stage column tag travels with the
scale/exp data. Each result slice returns to its owning stripe, where a local
column decode writes `prob_q`; no complete score/probability tile is exported.

The implemented scale-plus-exp latency is eight cycles: five registered stages
in dedicated `score_scale_pipe` (including the exact two-stage, II=1 signed multiplier)
followed by three registered stages in `pwl_exp_unit`.
This is pipeline latency, not initiation interval; the 32-lane path accepts one
complete score column every cycle.

## 8. Block LSE Update

### 8.1 Purpose

The block LSE update maintains numerical stability across tile iterations.

### 8.2 State

Per row:

- running max `m`
- running normalizer `l`

### 8.3 Update Rule

The recurrence should follow the online-softmax formula used by FlashAttention.

Implementation rule:

- compute the new row max;
- rescale the old sum using the max delta;
- accumulate the new exponentials;
- write back updated `m` and `l`.

### 8.4 Timing Rule

The recurrence should be registered. Do not make block LSE a single long datapath with exp, multiply, add, and compare chained in one combinational block.

The rightmost probability column launches one right-to-left rowsum token per
row. Probability columns write back in reverse order and remain one cycle ahead
of that sum token, so local subtraction, exp, and rowsum overlap as one column
wavefront. All 32 row sums finish together and are captured in 1 Kbit of bounded
state. Saved `old_l`, captured block sums, and a private alpha copy become three
shift streams whose fixed low slices feed one latency-2, II=1 unsigned
`old_l*alpha + block_sum` datapath. Results are inserted at the fixed high end
of the `l_rows` shift register. The row counter only tags tokens, so no 32:1
wide operand mux or 1024-bit decoded dynamic write remains. Capturing all sums
also raises the PV-ready event, so probability-stationary WS-PV overlaps these
serialized row-state writes.

PV-ready and row-state-done are different contracts. The former requires
complete `prob_q`, `alpha`, and captured block sums; the latter requires all new
`l` values to be committed. The next tile's softmax and final normalization
must wait for row-state-done even when the current WS-PV has already started or
finished.

## 9. Stationary Probability

Probability is stored in the PE that owns the corresponding score and remains
stationary throughout one continuous `HEAD_DIM`-feature WS-PV stream. Full
feature tags address persistent O storage; there is no half control state.

### 9.1 Rules

- Do not expose a full beta matrix port.
- Load shared-exp results back into PE-local probability registers.
- Send feature-major V down the existing K links and horizontal partial sums
  through the rowsum links only when the matching V word is valid.
- Keep beta/probability off external SRAM and BRAM.

### 9.2 Timing Rule

Probability does not hop during PV. V-valid and partial-sum-valid tokens remain
aligned through the column/row skew pipelines; a bubble advances neither the
row seed nor the feature tag. WS-PV may run concurrently with the central
one-row-per-cycle `l` updater because it reads stationary probability and
`alpha`, but it does not consume the newly written `l`.

## 10. Reciprocal and Final Normalization

### 10.1 Reciprocal Seed

Use a small LUT seed table. The implementation pipelines input capture,
leading-zero/normalization, and LUT/output shift and accepts one value per cycle.

### 10.2 Final Normalization

The final normalization stage computes `O_acc / l_final` for eight rows at the
same feature each cycle using eight reciprocal lanes and two multiplier stages
per lane. A stripe/feature tag is delayed with the arithmetic.

The bounded 30-bit reciprocal is explicitly converted to a positive signed
31-bit operand. The resulting signed 32x31 product uses the common latency-2,
II=1 partial-product wrapper: stage 1 computes 16x31 and 17x31 products in parallel, and
stage 2 combines them. After the result is arithmetically shifted by 15, the
implementation checks that the discarded upper bits are a sign extension and
passes a conservative signed 48-bit value into a second latency-2, II=1 exact
48x16 output-scale multiplier. Scale, tag, and valid metadata cross both
pipelines, so back-to-back feature tokens remain aligned.

Under `ATTN_ASIC`, every variable-by-variable multiplier is instantiated through
`fa_signed_mult_comb` or `fa_unsigned_mult_comb`, whose implementation is an
explicit `DW02_mult`; simulation and FPGA builds use the equivalent portable `*`
branch. Parameter-constant address arithmetic remains eligible for synthesis
strength reduction and does not force a physical multiplier.

Within a PE, the QK score update, WS-PV update, and rowsum update share one
operand-isolated 33-bit adder. `accum_q` remains the stationary score register;
`sum_data_o` remains the horizontal token register, so only the arithmetic cone
is shared and the systolic dataflow is unchanged.

- reciprocal seed + multiply,
- reciprocal seed + one refinement stage,
- or a small fixed-point divide approximation.

### 10.3 Design Rules

- Keep the final normalization path short and explicit.
- Do not place it on the same critical path as the array MAC tree.
- Use the same rounding and saturation rules as the rest of the design.

## 11. Softmax Engine Top-Level

`fsa_fused_array` orchestrates the phase and row-state control. Arithmetic
and data storage remain in the PE or dedicated lane pipelines.

Recommended structure:

- PE-local score and mask state;
- registered rowmax pass;
- reverse `m_new` restream and local subtraction;
- shared scale/exp lane pipeline;
- PE-local probability writeback and rowsum pass;
- row-state update;
- probability-stationary WS-PV using the rowsum links;
- separately pipelined final normalizer.

## 12. First-Version Strategy

For a first version that is likely to close timing:

1. Keep the softmax path fully tile-based.
2. Separate reduction, exp, and normalization by registers.
3. Keep row state on chip.
4. Use a limited PWL domain.
5. Avoid storing S or P matrices in RAM.
6. Keep the lane count fixed at 32.

## 13. Verification Hooks

- Test rowmax and rowsum independently.
- Test mask behavior independently.
- Test exp approximation independently.
- Test the full online-softmax recurrence on block tiles.
- Test extreme values and tail tiles.

## 14. References

- FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness.
- FlashAttention-2: Faster Attention with Better Parallelism and Work Partitioning.
- SystolicAttention: Fusing FlashAttention within a Single Systolic Array.
