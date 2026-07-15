# Compute Datapath Design

## 1. Scope

This document defines the implementation strategy for the compute datapath:

- `rtl/compute/os_fsa_pe.v`
- `rtl/compute/os_fsa_array.v`
- `rtl/compute/os_fsa_controller.v`
- `rtl/compute/scale_requant_unit.v`
- `rtl/compute/qk_engine.v`
- `rtl/compute/pv_engine.v`

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

The logical target is a 32x32 output-stationary array.

For timing closure, implement the array as a hierarchical structure instead of a flat 1024-PE blob:

- Partition the 32 rows into 4 row stripes of 8 rows each.
- Keep each stripe locally regular and locally routed.
- Register every stripe boundary.
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
- Do not embed row reduction or exp logic inside the PE.
- Do not let the PE talk directly to AXI or cache logic.
- Keep all control inputs registered.
- Keep the PE behavior identical for QK and PV except for mode bits and operand routing.

### 4.5 PE Reset and Gating

- Reset local state cleanly.
- Gate useless toggling when valid is low.
- Keep output stable when no new input is accepted.

## 5. Array Microarchitecture

### 5.1 Logical Mapping

- Rows map to query lanes.
- Columns map to key lanes for QK, and output feature lanes for PV.
- The same logical array supports both phases.

### 5.2 Recommended Internal Partitioning

For the first version, the 32x32 logical array should be implemented with stripe-local data movement:

- Each 8-row stripe has a local row broadcast path.
- Each 8-row stripe has a local control slice.
- Each stripe can feed a local reduction stage.
- Row-state values are distributed to stripes through registered fanout buffers.

This reduces global congestion and helps timing closure on a large FPGA fabric.

### 5.3 Array Timing Rules

- Register inputs before they enter a PE row.
- Register outputs before they leave a stripe.
- Avoid global combinational row/column busses.
- Use local enable trees, not one giant enable net.
- Keep array control separate from row data movement.

### 5.4 Array Output Handling

For QK, the array outputs score values.
For PV, the array outputs partial output accumulation values.

The output path should use a staged gather strategy:

- local PE outputs -> stripe local register -> array output register -> downstream block.

Do not forward a full wide score/beta bus combinationally into softmax or memory.

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

### 6.3 Timing Rule

The controller should not create combinational feedback from the output stage back into the input stage. Any phase decision based on a downstream done condition must be registered first.

## 7. QK Wrapper

### 7.1 Function

The QK wrapper stages Q and K tile data, drives the array, and emits scores.

### 7.2 Design Strategy

- Keep tile input buffering separate from array control.
- Use explicit tile start and tile done events.
- Allow the wrapper to absorb small bubbles while the scheduler loads the next tile.
- Emit scores as a stream or staged register block, not as a direct combinational bus from the array to softmax.

### 7.3 Timing Rule

The QK wrapper should be the point where tile-level data is aligned and registered before entering softmax.

## 8. PV Wrapper

### 8.1 Function

The PV wrapper consumes beta and V tiles and produces output accumulation.

### 8.2 Design Strategy

- Feed beta through a narrow, registered path.
- Feed V through the same tile cache family used by Q and K.
- Keep output accumulation local until the tile is complete.
- Send only tile-complete data to the output buffer or writeback stage.

### 8.3 Timing Rule

Do not connect the softmax output directly to the array without a register slice.

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
2. `os_fsa_pe.v`
3. `os_fsa_array.v`
4. `os_fsa_controller.v`
5. `qk_engine.v`
6. `pv_engine.v`

This order lets you close a tiny PE first, then the array, then the wrappers.

## 11. Verification Hooks

- Each PE mode must be individually testable.
- The array must have a deterministic one-tile smoke test.
- QK and PV wrappers must be independently verifiable.
- The compute path must be able to run with softmax stubbed for early bring-up.

## 12. References

- FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness.
- FlashAttention-2: Faster Attention with Better Parallelism and Work Partitioning.
- SystolicAttention: Fusing FlashAttention within a Single Systolic Array.
