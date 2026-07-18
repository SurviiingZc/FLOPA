# RTL Scalability and Physical-Design Audit

## 1. Scope and Conclusion

This document audits the active fused OS-FSA RTL for register duplication,
wide datapaths, variable-index multiplexers, high-fanout control, arithmetic
replication, and parameter scalability.

The current 32x32 implementation is suitable for functional verification, but
it must not be scaled to a monolithic 128x128 array by changing parameters
alone. Several interfaces are still fixed to 32 lanes, and two variable-index
reads reconstruct full-row multiplexers from PE-local state. The recommended
scaling method is a physically bounded 32x32 core, or several hierarchical
8x32 stripes, with larger logical tiles executed as subtiles.

## 2. PE Register Reuse

### 2.1 Merging `score_q` and `acc_q`

This change is valid and recommended.

In the active schedule, the values have disjoint lifetimes:

1. QK writes the score accumulator.
2. Rowmax and reverse `m_new` consume the score.
3. Exp writes `prob_q`, and rowsum completes before PV starts.
4. The first PV tile clears the output accumulator; later PV tiles load the
   previous O accumulator from `output_buffer` before PV MAC starts.

Therefore, one PE-local `accum_q` can hold Score during QK and O_acc during PV.
For the current default configuration, `SCORE_W == ACC_W == 32`, so the merge
saves 32 flip-flops per PE with only a small phase/enable mux.

| Array | Saving from `score_q` + `acc_q` merge |
| --- | ---: |
| 32x32 | 32,768 bits |
| 128x128 | 524,288 bits |

Implementation requirements:

- Prefer an explicit single `accum_clear_i` command instead of retaining two
  ambiguous clear ports inside the PE. If the two ports remain temporarily,
  use `clear_score_i || clear_acc_i` as the highest-priority update condition.
- `load_acc_i` must have priority over PV MAC and may only occur after softmax
  has finished using the score/delta state.
- QK MAC and PV MAC must be mutually exclusive. Add assertions in the module TB
  for clear/load/MAC conflicts and illegal phase overlap.
- For the first implementation, enforce `SCORE_W == ACC_W`. Supporting unequal
  widths with `ACCUM_W = max(SCORE_W, ACC_W)` is possible, but every load,
  compare, subtract, output, and truncation point must then use explicit signed
  extension and width checks.
- `score_o`, `acc_o`, `max_score_w`, and score subtraction must all read the
  correct `accum_q` slice. The active array does not currently use `score_o`, so
  that port should be removed unless a verification-only consumer is retained.

### 2.2 Additional Phase-Exclusive Register Reuse

Two related opportunities should be evaluated after the basic merge:

1. Overwrite `accum_q` with `score - m_new` during the reverse `m_new` pass.
   Rowmax has already consumed the original score, so `delta_q` does not need a
   separate 32-bit register. This can save another 32 bits per PE.
2. Shift `prob_q` itself during PV. Rowsum has completed before PV starts, so
   the original probability and `prob_shift_q` are not simultaneously needed.
   This can save another `PROB_W` bits per PE.

With default widths, all three changes together can remove up to 80 state bits
per PE: 81,920 bits for 32x32 and 1,310,720 bits for 128x128. These two extra
changes require separate directed tests because they alter the lifetime of
debug-visible intermediate state.

Forward max and rowsum pass registers are also phase-exclusive, but merging
them is lower priority. It can add direction/mode muxing to a timing-sensitive
nearest-neighbor path, so it should only be done after physical timing data is
available.

## 3. Packed Versus Unpacked Arrays

Using internal unpacked or two-dimensional arrays is recommended for PE and
neighbor-link code, with an important limitation: syntax does not determine
physical routing.

An internal representation such as:

```verilog
wire [DATA_W-1:0] q_link [0:ROWS-1][0:COLS];
wire [SCORE_W-1:0] delta [0:ROWS-1][0:COLS-1];
```

improves constant-index neighbor connections, removes manual flattened-index
arithmetic, and makes row/stripe ownership easier to verify. It does not remove
a mux if the code still performs a variable read such as:

```verilog
delta[prob_issue_row_q][lane]
```

That expression still synthesizes to a `ROWS:1` mux for every lane. Similarly,
changing `acc_matrix_w[(row_index_o*COLS+col)*ACC_W +: ACC_W]` to
`acc[row_index_o][col]` changes readability but not the netlist.

Rules for using unpacked arrays in this project:

- Use them internally for constant `genvar` neighbor connections.
- Do not expose whole unpacked arrays across Verilog-2001 module ports. Use
  narrow scalar/vector stream ports at row or stripe boundaries.
- Prohibit variable reads from PE-state arrays in the central controller.
- Introduce real `os_fsa_stripe` and `os_fsa_row` hierarchy; array syntax alone
  does not provide placement locality.
- Preserve row/stripe hierarchy through synthesis and apply FPGA pblocks or
  ASIC placement groups so logical neighbors remain physical neighbors.
- Compile representative configurations with VCS and DC because unpacked-net
  support and memory inference can differ between tool versions.

## 4. Consolidated P0 Findings

### P0.1 Dynamic delta-row selection

`rtl/compute/os_fsa_fused_array.v:365-368` selects one complete delta row from
`delta_matrix_w` using `prob_issue_row_q`.

- 32x32: 32 parallel 32-bit, 32:1 muxes.
- 128x128: 128 parallel 32-bit, 128:1 muxes.
- `delta_matrix_w` grows from 32,768 to 524,288 declared bits.

Fix: each row or stripe must emit a sequential `{row_id, delta_chunk}` packet.
Use a registered stripe-local arbiter or reduce `EXP_LANES` to 8/16 and stream
column chunks. Do not centrally index the complete PE matrix.

### P0.2 Dynamic accumulator-row selection

`rtl/compute/os_fsa_fused_array.v:388-392` selects one O-accumulator row from
`acc_matrix_w` using `row_index_o`.

Fix: use the natural staggered row completion order. Each row writes a local
result FIFO or sends registered column chunks directly to `output_buffer`.
Remove the random-access matrix read and the full `acc_matrix_w` consumer.

### P0.3 Exp-result broadcast to every row

`rtl/compute/os_fsa_fused_array.v:302-308` connects each exp lane to every PE in
the same column and decodes `prob_receive_row_q` across the full array.

Fix: return exp results as a row-tagged stream to the owning stripe, register
the result at the stripe edge, and move it through fixed neighbor links. Never
broadcast a probability lane down all physical rows.

### P0.4 Wide O-accumulator load broadcast

`pv_load_row_data_i` is 1,024 bits at 32 columns and 4,096 bits at 128 columns.
At every PE, `pv_load_row_index_i == pe_row` selects the destination row, while
each column slice fans out to all rows.

Fix: replace it with a chunked interface such as:

```text
acc_load_valid, row_id, col_group, acc_data[LOAD_LANES*ACC_W-1:0]
```

Use 8 or 16 load lanes and a row-local shift/load path.

### P0.5 Row-state export and variable selection

`alpha_rows_o` and `l_rows_o` export every row from the fused array. The PV
engine selects alpha with `row_count_q`, and the top selects `l` with
`norm_row_q`.

Fix: keep `(m,l,alpha)` in a row-state bank at the stripe edge and expose a
request/response or sequential stream interface:

```text
row_state_req, row_id -> row_state_valid, alpha, l
```

### P0.6 False large-array parameterization

The Q/K/V cache word is fixed at 256 bits, or 32 INT8 elements. However,
`fsa_qk_engine` and `fsa_pv_engine` iterate to `ARRAY_ROWS/ARRAY_COLS`; values
above 32 index beyond the cache word. `output_buffer` also fixes row indices to
5 bits, row width to 32 lanes, storage to 32 rows x two halves, and output
addressing to 32-lane words. The top contains fixed constants for 32 rows and
64-byte output rows.

Fix:

- Define `CACHE_LANES = CACHE_WORD_W / CACHE_ELEM_W` and reject unsupported
  configurations at elaboration/TB time.
- Separate logical tile dimensions from physical `PE_ROWS`, `PE_COLS`, and
  `LANES_PER_CYCLE`.
- Execute a logical 128x128 tile as 4x4 physical 32x32 subtiles.
- Parameterize output row index, lane count, feature groups, word count, and
  byte/beat calculation from those physical parameters.

## 5. Consolidated P1 Findings

### P1.1 Arithmetic replication outside the PE array

- `fsa_pv_engine.v:87-94` infers `ARRAY_COLS` parallel O-accumulator rescale
  multipliers.
- `os_fsa_fused_array.v:529-539` infers `ROWS` parallel `old_l * alpha`
  multipliers in one update cycle.
- `online_normalizer.v:51-107` instantiates two multiply stages per lane.
- The number of scale/PWL-exp lanes is tied directly to `COLS`.

Fix: introduce independent `EXP_LANES`, `RESCALE_LANES`, `LSE_LANES`, and
`NORM_LANES` parameters. Process rows/columns in registered groups and clock- or
operand-gate inactive groups. Scaling the PE array must not automatically
replicate every nonlinear and normalization lane.

### P1.2 Full-grid mask comparators

`os_fsa_fused_array.v:230-239` creates query/key bounds and causal comparison
logic for every PE. At 128x128 this becomes 16,384 comparison sites driven by
the same configuration signals.

Fix: generate row-valid and column-valid vectors at stripe boundaries. Generate
causal validity as a diagonal/shifted one-bit token propagated through local
links instead of recomputing global indices in every PE.

### P1.3 High-fanout phase and clear control

`clear_i`, `clear_score_i`, `clear_acc_i`, `mac_is_pv_i`, row-load index, and
probability-write index reach most or all PEs. Synthesis buffering limits fanout
per cell but does not remove the global network or routing demand.

Fix: register phase/control once per stripe and distribute it locally. Prefer
valid/epoch state over clearing wide data registers when stale data is already
protected by valid bits.

### P1.4 Physical stripes are not implemented

`STRIPE_ROWS` exists at the top level but is not used to build hierarchy. The
active RTL is one nested `ROWS x COLS` generate block, so the documented four
8-row stripes do not constrain synthesis or placement.

Fix: instantiate four real `os_fsa_stripe` modules for 32 rows. Each stripe must
own its skew boundary, row state, local result queue, and local control register.

### P1.5 Wide output memories and unnecessary switching

The output accumulator memory reads or writes a complete 1,024-bit row. Its
ASIC wrapper composes a very wide macro bank, and the FPGA model requests a
wide BRAM/URAM word. This activates all lanes even when later stages are
serialized.

Fix: bank output storage by 128 or 256-bit column groups, enable only the active
group, and align `NORM_LANES` with the bank width.

## 6. Consolidated P2 Findings

### P2.1 Quadratic skew-register growth

The input boundary instantiates delay lines of depth 1 through `ROWS/COLS`.
Delay storage therefore grows quadratically with array dimension.

Fix: keep skew local to a bounded stripe. On FPGA, explicitly infer SRLs or
small distributed RAM where appropriate; on ASIC, use placed boundary shift
register chains with clock enables.

### P2.2 Multiplier operand isolation

The fused PE forms its product combinationally without an explicit MAC enable.
Upstream registers hold data on invalid cycles, which reduces some switching,
but this is not a robust power contract.

Fix: isolate multiplier operands with `q_valid_i && k_valid_i` and the active
MAC phase. Apply the same rule to PV rescale and other shared multipliers so
unused arithmetic inputs remain constant.

### P2.3 Wide-vector declarations obscure locality

`max_node_data_w`, `m_node_data_w`, `sum_node_data_w`, and most neighbor links
use constant generate slices, so their wide declarations do not automatically
create giant muxes. They are still difficult to audit and do not force physical
locality after hierarchy flattening.

Fix: convert constant-index internal links to unpacked arrays inside real row
and stripe modules. Do not treat this conversion as a replacement for removing
variable indexing or for physical floorplanning.

## 7. Recommended Target Organization

```text
attention_accel_top
  qkv_cache: fixed 256-bit words
  fsa_core
    stripe[0..3]: 8x32 PEs
      row-local accum/prob state
      nearest-neighbor max/m/sum links
      local row-state bank
      registered delta/result packet queue
    shared exp lanes: independently parameterized
    registered stripe arbiter
  chunked O-accumulator banks
  independently parameterized normalizer lanes
```

For a logical 128x128 operation, schedule 16 physical 32x32 subtiles. If more
throughput is required, replicate bounded 32x32 cores with independent local
SRAM ports instead of constructing one monolithic 128x128 routing domain.

## 8. Implementation Order

1. Merge `score_q` and `acc_q`; add phase-conflict tests.
2. Evaluate overwriting `accum_q` with delta and reusing `prob_q` for PV shift.
3. Add legal-configuration guards and remove remaining hard-coded 32-lane
   output assumptions.
4. Build real 8x32 stripe hierarchy and convert local links to unpacked arrays.
5. Replace delta-row and accumulator-row dynamic selectors with registered row
   or chunk streams.
6. Replace full alpha/l and acc-load buses with indexed/chunked interfaces.
7. Decouple exp, LSE, rescale, and normalizer lane counts from array dimensions.
8. Add stripe-level control distribution, mask propagation, clock enables, and
   physical placement constraints.

Each structural step must retain the fused dataflow: QK score accumulation,
column-staggered rowmax, reverse `m_new` subtraction, shared exp, PE-local
probability/rowsum, and probability-V accumulation.
