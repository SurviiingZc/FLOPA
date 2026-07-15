# Softmax Datapath Design

## 1. Scope

This document defines the implementation strategy for the softmax path:

- `rtl/softmax/softmax_engine.v`
- `rtl/softmax/row_reduce_unit.v`
- `rtl/softmax/row_broadcast.v`
- `rtl/softmax/causal_mask.v`
- `rtl/softmax/pwl_exp_unit.v`
- `rtl/softmax/block_lse_update.v`
- `rtl/softmax/reciprocal_lut.v`
- `rtl/softmax/online_normalizer.v`

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
5. Keep the softmax path fully pipelined and separated from the array datapath.

## 3. High-Level Organization

The softmax path should be a separate pipeline, not a random collection of combinational helpers.

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
- Broadcast the current row state using registered fanout.
- Do not let row state be recomputed combinationally from a distant stage.

## 5. Mask Stage

### 5.1 Purpose

The mask stage removes illegal score positions before any max or exp operation.

### 5.2 Design Rules

- Apply causal masking before row max.
- Masked elements must not participate in rowsum.
- Represent masked values using a safe minimum fixed-point pattern.
- Keep the mask stage simple and fully combinational or one-stage pipelined.

### 5.3 Timing Rule

The mask stage should be a short local stage with no large fanout. It should not sit on the critical reduction path.

## 6. Row Reduction

### 6.1 Purpose

Row reduction computes row maximum and row sum.

### 6.2 Preferred Structure

Use a balanced tree, not a long serial chain.

Recommended implementation:

- Local lane reduction inside a stripe.
- Registered local reduction output.
- Final merge stage across stripes if needed.

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

Suggested pipeline:

1. Sign/range decode.
2. Segment selection.
3. Slope/intercept or LUT read.
4. Multiply/add.
5. Output register.

### 7.3 Design Rules

- Optimize only the non-positive input domain.
- Keep the segment count modest and synthesis-friendly.
- Do not instantiate a general-purpose floating-point exp.
- Keep the same approximation policy for every lane.

### 7.4 Timing Rule

Exp should be a dedicated multi-cycle or multi-stage pipe. It should never sit directly after a wide reduction with no register cut.

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

## 9. Beta Streaming

Beta is the softmax probability stream feeding PV.

### 9.1 Rules

- Beta should be emitted as a stream or narrow buffered tile.
- Beta should be aligned to the same row ordering as the array output.
- Beta should not require a full matrix buffer.

### 9.2 Timing Rule

Beta must be registered before entering PV.

## 10. Reciprocal and Final Normalization

### 10.1 Reciprocal Seed

Use a small LUT or seed table for reciprocal estimation.

### 10.2 Final Normalization

The final normalization stage should compute `O_acc / l_final` with one of the following:

- reciprocal seed + multiply,
- reciprocal seed + one refinement stage,
- or a small fixed-point divide approximation.

### 10.3 Design Rules

- Keep the final normalization path short and explicit.
- Do not place it on the same critical path as the array MAC tree.
- Use the same rounding and saturation rules as the rest of the design.

## 11. Softmax Engine Top-Level

The softmax engine should orchestrate the submodules but not absorb all logic into one monolithic always block.

Recommended structure:

- input register / lane aligner,
- mask,
- reduction stage,
- exp stage,
- update stage,
- normalize stage,
- output register.

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
