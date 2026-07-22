# Compute Datapath Design

## 1. Scope

This document defines the implementation strategy for the compute datapath:

- `rtl/compute/fsa_fused_pe.v`
- `rtl/compute/fsa_stripe.v`
- `rtl/compute/fsa_fused_array.v`
- `rtl/compute/fsa_delay_line.v`
- `rtl/compute/fsa_controller.v`
- `rtl/compute/fsa_qk_engine.v`
- `rtl/compute/fsa_pv_engine.v`
- `rtl/common/fa_clear_replica.v`

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

The QK score clear is one such local control. Each stripe instantiates one
`fa_clear_replica` per eight columns, so a replicated output drives only eight
PE columns. The leaf hierarchy may be preserved against cross-group merging,
but its internal flop must remain technology-mappable; applying `dont_touch` to
an unmapped generic register is forbidden.

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

- Reset valid, phase, counter, and externally observable state. Datapath
  payload registers protected by a valid bit are intentionally not
  asynchronously reset; no payload may be consumed until its valid token has
  traversed the same pipeline.
- Gate useless toggling when valid is low.
- Keep output stable when no new input is accepted.
- Keep Q/K/V storage and links at native signed INT8 width. At the shared
  multiplier only, form a signed 17-bit A operand from signed Q or unsigned
  Q1.15 P, and a signed 9-bit B operand from signed K/V.
- The resulting 17x9 multiplier produces an exact 16-bit QK product or exact
  24-bit PV product before sign extension into the signed 32-bit datapath.
- Verilog result sizing is made explicit by extending one operand to the
  product context at the multiplier boundary. The other operand stays 9 bit;
  synthesis must be checked to ensure repeated sign bits fold to an effective
  17x9 implementation.
- Drive multiplier operands to zero whenever neither QK nor PV is active.
- Keep the INT8 multiply and 32-bit accumulation in one registered cycle unless
  mapped slow-corner timing no longer meets the target clock after placement.

### 4.6 Implemented Phase-Exclusive State

The fused PE uses signed `accum_q` only for QK Score. During the reverse
`m_new` pass, Score is overwritten with `Score-m_new`, so no separate
`delta_q` is required. PV reuses the registered rowsum path and does not use a
PE-local output accumulator.

`prob_q` remains stationary for one continuous `HEAD_DIM`-feature PV issue
stream. A full feature tag accompanies the horizontal partial sum. Physical
feature groups are O-memory banks only; the array does not drain or restart at
a group boundary. The obsolete `prob_shift_q` and its right-to-left link were
removed. QK and WS-PV select one explicitly shared PE multiplication expression.

The old-O rescale is an exact latency-2, II=1 signed 32x17 multiply, and the serialized LSE
update is an exact unsigned 32x16 multiply. Operands are not pre-expanded to a
common wide width before multiplication, avoiding accidental 48x48 hardware.

The O-bank response, alpha, feature ID, seed-zero, and valid are first captured
at the stripe boundary. They feed the two-stage rescale wrapper, while V and its
feature/valid token are delayed by the same two stages before column skew. Thus
the array receives matched `{alpha*O_old[:,d], V[:,d], d}` tokens without a
single-cycle SRAM-Q-to-multiply-to-skew path.

## 5. Array Microarchitecture

### 5.1 Logical Mapping

- Rows map to query lanes.
- Columns map to key lanes in both QK and WS-PV.
- The same logical array supports both phases.

### 5.2 Implemented Internal Partitioning

The 32x32 array is instantiated as four real 8x32 `fsa_stripe` blocks:

- Q, K, rowmax, reverse-m, rowsum, delta, probability, and accumulator links
  are unpacked constant-neighbor arrays inside a stripe.
- Probability column IDs are decoded locally to one-hot enables with fanout
  bounded to 8 rows.
- Delta columns use a registered 8-column-group hierarchy before leaving a
  stripe.
- Each stripe owns persistent row-banked O storage; no accumulator row load or
  result bus crosses the stripe boundary.
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
from the array. For PV, each right-edge result writes its row-local O bank at
the propagated feature address.

The active output path uses this staged strategy:

- QK score -> PE-local max/subtract/probability path.
- stationary probability + vertical V -> horizontal partial-sum PV path.
- non-first KV tiles synchronously read one old-O feature from all row banks,
  rescale it by row alpha, and inject the results at the left edge;
- returned features write their exact tagged addresses without whole-buffer
  shifts or row-wide transfers;
- final normalization reads one 8-row stripe and one feature per cycle.

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
- QK completion no longer propagates as `q_last`, `k_last`, and `mac_last`
  registers through every PE. One array-level `ROWS+COLS` sideband shift
  tracks the diagonal wavefront. Fixed tap `row+1` launches each stripe row's
  first max compare, while the final tap generates the registered QK tail.
- QK clear is replicated inside each stripe by 8-column group. The QK engine
  spends one cycle in `ST_CLEAR` and one in `ST_CLEAR_LOCAL` before issue, so
  the global clear token ends at four local registers per stripe rather than
  directly driving all PE accumulator clear pins. These intentional equivalent
  register copies are preserved from synthesis merging.
- The registered partial max reaches column `c+1` when that column's final
  score is ready, so rowmax overlaps the QK tail instead of rescanning the row.
- Rowmax propagates left to right through PE compare/pass registers.
- `m_new` propagates right to left; each PE stores `score-m_new` locally.
- The shared scale-plus-exp pipeline has eight cycles of latency (five scale
  stages, including a two-stage II=1 multiplier, plus three PWL-exp stages),
  accepts one 32-row column vector per cycle,
  and writes probabilities back to the tagged PE column.
- One cycle after the rightmost probability column writes `prob_q`, all rows
  start a right-to-left rowsum. The sum token follows the column writeback wave,
  so reverse-m/SUB, exp, and rowsum overlap.
- All row sums finish together and enter a 32x32-bit capture register. The
  captured sums, saved old sums, and alpha values are consumed as fixed-low-port
  shift streams. A latency-2, II=1 unsigned multiplier updates one row per cycle;
  the row counter is metadata only and never selects a wide packed operand.
- Completed `l_new` values enter the fixed high end of the `l_rows` shift
  register. This removes the former 32:1 operand muxes and decoded 1024-bit
  dynamic write while preserving row order after all 32 commits.
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

The active PV wrapper streams `HEAD_DIM` feature-major V vectors into the fused
array in one invocation. The fused array reads and rescales old O directly from
persistent stripe banks. Probability remains stationary in each PE.

### 8.2 Design Strategy

- Do not expose a beta input port.
- Do not preload or shift old-O rows; carry a full feature ID with every issue.
- Feed V through the same tile cache family used by Q and K.
- Keep output accumulation local until the tile is complete.
- Keep intermediate O in stripe-local banks until the last KV tile.
- Hold rescale multiplier operands at zero unless an old-O seed is requested.

### 8.3 Timing Rule

Start PV when PE probability and alpha are complete. The serialized `l` update
may overlap PV; the top-level sticky completion guard prevents tile advance or
final normalization before all `l` writes commit.

The reverse `m_new` wave starts from registered `m_rows_q`. `SM_ALPHA_WAIT`
commits the combinational `m_pending_q` result first and only then advances to
`SM_M_START`; using `m_rows_q` therefore adds no cycle while isolating block-max
selection from the PE `Score-m_new` subtraction path.

### 8.4 Implemented Probability-Stationary WS-PV

The implemented PV mapping keeps `P[i,k]` in `prob_q` and reuses the PE
rowsum register/link as a horizontal partial-sum pipeline:

```text
sum_out = sum_in + P[i,k] * V[k,d]
sum_in at row edge = alpha[i] * O_old[i,d]
```

V cache address `d` stores `V[0:31,d]`. O is persistent and address-indexed as
`O[stripe][row][feature]`. Every returning result carries `d` and writes that
address directly. The issue interval is `HEAD_DIM` cycles; complete-tile latency
also includes registered column accumulation and row skew. No half state,
feature-major O transpose, or 1024-bit accumulator interface is used.

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

1. `fsa_fused_pe.v`
2. `fsa_delay_line.v`
3. `fsa_stripe.v`
4. `fsa_fused_array.v`
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
