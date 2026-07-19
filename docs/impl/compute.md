# Compute Datapath Design

## 1. Scope

This document defines the implementation strategy for the compute datapath:

- `rtl/compute/fsa_fused_pe.v`
- `rtl/compute/fsa_stripe.v`
- `rtl/compute/fsa_fused_array.v`
- `rtl/compute/fsa_delay_line.v`
- `rtl/compute/fsa_controller.v`
- `rtl/compute/scale_requant_unit.v`
- `rtl/compute/fsa_qk_engine.v`
- `rtl/compute/fsa_pv_engine.v`

`fsa_fused_array`, `fsa_qk_engine`, and `fsa_pv_engine` form the only
top-level compute datapath. The superseded external score/probability path and
its compatibility wrappers have been removed.

## 2. Design Basis

This design follows the common systolic-array attention pattern used in recent FlashAttention hardware work:

- FlashAttention uses tiling to avoid materializing intermediate score and probability matrices in global memory.
- FlashAttention-2 improves performance by reducing non-matmul work and improving work partitioning.
- SystolicAttention shows that rowmax, rowsum, and exp can be fused into a single systolic-array execution flow when non-matmul work is carefully scheduled.

Implications for this project:

1. Keep QK, softmax, and PV as one pipeline family.
2. Avoid external vector/SFU style softmax blocks that contend with the array.
3. Keep intermediate score and probability data on chip.
4. Preserve the original floating-point operation order at the logical level, even if the implementation is fixed-point.

## 3. High-Level Physical Strategy

The implemented physical target is a 32x32 output-stationary array.

The array is implemented as a hierarchy instead of a flat 1024-PE blob:

- Partition the 32 rows into 4 row stripes of 8 rows each.
- Keep each stripe locally regular and locally routed.
- Register selected state at every stripe boundary.
- Keep row-state broadcast local to a stripe when possible.
- Use narrow, registered control signals to cross stripe boundaries.

This preserves the 32x32 logical behavior while shortening the critical routing distance.

Recommended rule:

- If a signal must fan out to many PEs, register it first.
- If a bus must cross a large portion of the array, cut it into stripe-local segments.
- If a control decision affects the whole array, generate it in the scheduler and distribute only a registered mode bit.

## 4. PE Microarchitecture

### 4.1 Purpose

A PE is the smallest compute atom. It should be tiny, predictable, and easy to pipeline.

### 4.2 PE Modes

| Mode | Operation | Typical Use |
| --- | --- | --- |
| MAC_INT8 | `acc += a * b` | QK and PV main compute |
| SUB | `x - y` | score shift / normalization prep |
| MAX_PASS | compare and forward max | rowmax reduction |
| ADD_PASS | add and forward sum | rowsum / LSE update |
| SCALE | fixed-point multiply and shift | score scaling / requant |
| HOLD | retain state | phase gap / bubble control |

### 4.3 PE Pipeline Recommendation

A first-version PE should have a short fixed pipeline, not an ad hoc combinational datapath.

Suggested stages:

1. Input register stage.
2. Operation-select / operand-prep stage.
3. Arithmetic stage.
4. Output register stage.

If the arithmetic width or DSP mapping requires it, split the arithmetic stage further, but keep the register boundaries explicit.

### 4.4 PE Design Rules

- Keep one PE responsible for one lane pair only.
- Keep rowmax compare/pass, max restream subtraction, rowsum add/pass, score,
  probability, and output accumulation local to the fused PE.
- Keep exp outside the PE and share one registered 32-lane exp pipeline across
  the array.
- Do not let the PE talk directly to AXI or cache logic.
- Keep all control inputs registered.
- Keep the PE behavior identical for QK and PV except for mode bits and operand routing.

### 4.5 PE Reset and Gating

- Reset local state cleanly.
- Gate useless toggling when valid is low.
- Keep output stable when no new input is accepted.
- Implement MAC as signed INT8 x INT8 into the signed 32-bit accumulator; the
  wider PE operand bus is retained for SUB, MAX, ADD, and SCALE modes.
- Keep the MAC and SCALE multiplications inside their respective mode branches,
  and drive their intermediate products to zero in all inactive modes.
- Keep the INT8 multiply and 32-bit accumulation in one registered cycle unless
  mapped slow-corner timing no longer meets the target clock after placement.

### 4.6 Implemented Phase-Exclusive State

The fused PE uses signed `accum_q` only for QK Score. During the reverse
`m_new` pass, Score is overwritten with `Score-m_new`, so no separate
`delta_q` is required. PV reuses the registered rowsum path and does not use a
PE-local output accumulator.

`prob_q` remains stationary for one continuous 64-feature PV issue stream. The
two 32-feature halves remain only as row-buffer/output-SRAM address tags; the
array no longer drains and restarts at feature 31. The obsolete `prob_shift_q`
and its right-to-left link were removed.

## 5. Array Microarchitecture

### 5.1 Logical Mapping

- Rows map to query lanes.
- Columns map to key lanes in both QK and WS-PV.
- The same logical array supports both phases.

### 5.2 Implemented Internal Partitioning

The 32x32 array is instantiated as four real 8x32 `fsa_stripe` blocks:

- Q, K, rowmax, reverse-m, rowsum, delta, probability, and accumulator links
  are unpacked constant-neighbor arrays inside a stripe.
- Probability and accumulator row load are decoded locally to at most 8 rows.
- Delta and accumulator row reads are selected locally and registered before
  leaving a stripe.
- K data and valid tags cross explicit stripe boundaries.

This reduces global congestion and helps timing closure on a large FPGA fabric.

### 5.3 Array Timing Rules

- Register inputs before they enter a PE row.
- Register outputs before they leave a stripe.
- Avoid global combinational row/column busses.
- Use local enable trees, not one giant enable net.
- Keep array control separate from row data movement.

### 5.4 Array Output Handling

For QK, score values remain in PE-local score registers. They are not exported
from the array. For PV, only one completed accumulator row is exported at a
time.

The active output path uses this staged strategy:

- QK score -> PE-local max/subtract/probability path.
- stationary probability + vertical V -> horizontal partial-sum PV path.
- each stripe owns two 32-entry row buffers. Half 0 shifts seeds during
  features 0--31 while half 1 shifts seeds during features 32--63; the emptied
  half-0 buffer can collect results while half-1 seeds are still issuing.
- completed row halves leave the stripes in natural staggered row order and
  write the existing row-major output buffer.

Do not create `ROWS*COLS*SCORE_W`, `ROWS*COLS*PROB_W`, or
`ROWS*COLS*ACC_W` ports between top-level compute blocks.

There is no central variable-index read of a complete PE matrix. During the
reverse-m wave, each stripe registers only the active column for its eight
rows. Four fixed stripe slices form the 32-row exp vector. The bounded 32:1
column selector must be split into column groups before enlarging the physical
core beyond 32 columns.

### 5.5 Implemented Systolic Schedule

- Q rows enter from the left and are delayed by row index.
- K/V columns enter from the top and are delayed by column index.
- Each PE boundary is registered, so column `c` completes one cycle before
  column `c+1` in the same row.
- The QK-last token of column `c` launches its local max compare. The registered
  partial max reaches column `c+1` when that column's final score is ready, so
  rowmax overlaps the QK tail instead of rescanning the row later.
- Rowmax propagates left to right through PE compare/pass registers.
- `m_new` propagates right to left; each PE stores `score-m_new` locally.
- The shared scale-plus-exp pipeline has seven cycles of latency (four scale
  stages plus three PWL-exp stages), accepts one 32-row column vector per cycle,
  and writes probabilities back to the tagged PE column.
- One cycle after the rightmost probability column writes `prob_q`, all rows
  start a right-to-left rowsum. The sum token follows the column writeback wave,
  so reverse-m/SUB, exp, and rowsum overlap.
- All row sums finish together and enter a 32x32-bit capture register. The
  single `old_l*alpha` multiplier then updates one row per cycle.
- Capturing the row sums pulses `softmax_pv_ready_o`; WS-PV starts while that
  serialized row-state update continues. The later `softmax_done_o` pulse
  denotes completion of all `l` writes, not probability readiness.
- During PV, probability remains stationary. Feature-major `V[:,d]` reuses the
  K column skew/vertical links, while `alpha*O_old[:,d]` enters from the left
  and the partial sum advances one registered PE column per cycle.

## 6. Array Controller

The array controller manages phase switching.

### 6.1 Responsibilities

- Select QK or PV mode.
- Drive PE mode bits.
- Track whether the array is loading, computing, or draining.
- Align compute activity with cache availability.
- Freeze mode changes at tile boundaries.

### 6.2 Control Handshake

The controller should expose a simple handshake model:

- `phase_start`
- `phase_busy`
- `phase_done`
- `phase_error`
- `tile_last`

Keep these signals registered and stable for at least one cycle around phase boundaries.

Softmax has two distinct registered completion events. `softmax_pv_ready`
allows the scheduler to launch current-tile PV as soon as probability and all
row sums are ready. `softmax_done` indicates that every serialized `l` update
has committed. Tile advance and final normalization use the latter condition;
they must not infer row-state completion from the earlier PV-ready event.

### 6.3 Timing Rule

The controller should not create combinational feedback from the output stage back into the input stage. Any phase decision based on a downstream done condition must be registered first.

## 7. QK Wrapper

### 7.1 Function

The active QK wrapper stages Q and K tile data and drives the fused array. It
does not emit scores.

### 7.2 Design Strategy

- Keep tile input buffering separate from array control.
- Use explicit tile start and tile done events.
- Allow the wrapper to absorb small bubbles while the scheduler loads the next tile.
- Wait for the registered systolic tail token from the fused array.
- Do not expose score or matrix ports on the active wrapper.

### 7.3 Timing Rule

The QK wrapper is the cache-to-array boundary. Softmax starts only after the
registered QK tail event.

## 8. PV Wrapper

### 8.1 Function

The active PV wrapper restores/rescales both old-O row halves into stripe-local
buffers, then streams all 64 feature-major V vectors into the fused array in a
single invocation. Probability remains stationary in each PE.

### 8.2 Design Strategy

- Do not expose a beta input port.
- Reload old output accumulation one row at a time rather than loading a full
  matrix.
- Feed V through the same tile cache family used by Q and K.
- Keep output accumulation local until the tile is complete.
- Send only tile-complete data to the output buffer or writeback stage.
- Read alpha through the fused array's narrow synchronous row-state
  request/response port; do not export an alpha vector.
- Hold rescale multiplier operands at zero unless a row load is accepted.

### 8.3 Timing Rule

Start PV only after PE probability registers and the row-state update are
complete. A row seed advances only when a valid feature-major V word is
accepted.

### 8.4 Implemented Probability-Stationary WS-PV

The preferred future PV mapping keeps `P[i,k]` in `prob_q` and reuses the PE
rowsum register/link as a horizontal partial-sum pipeline:

```text
sum_out = sum_in + P[i,k] * V[k,d]
sum_in at row edge = alpha[i] * O_old[i,d]
```

This mode is active. V cache address `d=0..63` stores `V[0:31,d]`. O remains
row-major in two 32-feature halves. Each stripe preloads both halves, issues 64
features without a half-boundary restart, and collects each completed half into
the corresponding emptied buffer. The issue time is 64 cycles; complete-tile
latency also includes the registered column accumulation and row skew drain.
This avoids an additional feature-major O SRAM and final transpose.

## 9. Fixed-Point Scaling and Requantization

The scaling unit is the bridge between the INT8 array and the softmax/output fixed-point domain.

### 9.1 Required Operations

- signed multiply,
- arithmetic shift,
- rounding to nearest,
- saturation,
- optional zero-point add.

### 9.2 Design Rules

- Keep scale mantissa and shift width explicit.
- Use one scale representation everywhere.
- Do not bury scale logic inside PE mode control.
- Verify scale conversions with dedicated module TBs.

### 9.3 Timing Rule

The requant unit must be pipelined if it sits on a critical path. Do not allow a multiply -> shift -> saturate chain to sit in a single unregistered stage if 312.5 MHz is being targeted.

## 10. First-Version Implementation Order

Recommended order:

1. `scale_requant_unit.v`
2. `fsa_fused_pe.v`
3. `fsa_delay_line.v`
4. `fsa_stripe.v`
5. `fsa_fused_array.v`
6. `fsa_controller.v`
7. `fsa_qk_engine.v`
8. `fsa_pv_engine.v`

This order closes the PE-local state and arithmetic first, then the registered
array links, phase controller, and stream wrappers.

## 11. Verification Hooks

- Each PE mode must be individually testable.
- The array must have a deterministic one-tile smoke test.
- QK and PV wrappers must be independently verifiable.
- The compute path must be able to run with softmax stubbed for early bring-up.

## 12. References

- FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness.
- FlashAttention-2: Faster Attention with Better Parallelism and Work Partitioning.
- SystolicAttention: Fusing FlashAttention within a Single Systolic Array.
