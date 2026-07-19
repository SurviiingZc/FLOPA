# RTL Scalability and Physical-Design Audit

## 1. Scope and Current Conclusion

This audit covers the active fused OS-FSA implementation after the stripe and
PE-state refactor. The physical compute core remains intentionally bounded to
32x32 PEs, implemented as four 8x32 stripes. A logical 128x128 operation must
be scheduled as physical 32x32 subtiles; changing only `ROWS` and `COLS` to 128
is not a supported implementation method.

The following high-risk structures were removed in this round:

- the complete `ROWS*COLS*SCORE_W` delta matrix and its central variable row
  selector;
- the complete `ROWS*COLS*ACC_W` accumulator matrix and its central variable
  row selector;
- array-wide exp-result row decode;
- full-vector alpha/l row-state ports;
- parallel per-row LSE-update multipliers;
- duplicated PE score, delta, and PV accumulator registers.

The remaining wide ports are bounded physical-row transfers, not complete
array-state exports. They still require physical banking before a larger core
is attempted.

## 2. PE State-Lifetime Refactor

### 2.1 Implemented `accum_q` reuse

`score_q` and `acc_q` were merged into one signed `accum_q`. Their lifetimes
are disjoint in the active schedule:

1. QK MAC stores Score in `accum_q`.
2. Rowmax consumes Score.
3. The reverse `m_new` pass overwrites `accum_q` with `Score - m_new`.
4. Exp and rowsum consume the delta and write `prob_q`.
5. The current output-stationary PV phase clears or loads `accum_q`, then uses
   it as the output accumulator.

The implementation enforces `SCORE_W == ACC_W` in simulation. Supporting
different widths requires explicit `ACCUM_W=max(SCORE_W,ACC_W)` policies at
every compare, subtract, load, and output boundary, so it is deliberately not
advertised as a supported configuration.

The merge saves 32 bits per PE at the default width. Overwriting Score with
delta saves another 32 bits per PE by removing `delta_q`.

| Physical array | State removed |
| --- | ---: |
| 32x32 | 65,536 bits |
| 128x128 monolith, unsupported | 1,048,576 bits |

The PE multiplier operands are isolated unless both Q and K/V valids are
asserted. Clear has highest priority, followed by accumulator load, reverse-m
overwrite, and active MAC.

### 2.2 Why `prob_shift_q` is retained in the current OS-PV path

`prob_q` cannot replace `prob_shift_q` in the current implementation. A
32-column physical array computes the 64-dimensional V tile in two feature
halves. The same PE-local probability must be reloaded at the beginning of
both halves. Destructively shifting `prob_q` in the first half would lose the
source probability needed by the second half.

`prob_shift_q` may be removed only if one of these contracts is implemented:

- all 64 feature lanes are computed in one probability shift; or
- the probability is re-created/reloaded before each half; or
- PV changes to the probability-stationary WS schedule evaluated in Section 3.

## 3. Confirmed Probability-Stationary WS-PV Dataflow

### 3.1 Exact interpretation

The clarified mapping is correct and has no matrix-dimension mismatch.

The PE coordinate is `(query row i, key column k)`. After softmax, PE `(i,k)`
keeps `P[i,k]` stationary in `prob_q`. The V tile is `V[0:31][0:63]`:

- the 32 V rows are the 32 key lanes and map one-to-one to the 32 PE columns;
- cycle `d` presents the vector `V[:,d]`, one INT8 value for every PE column;
- `V[k,d]` enters the top of PE column `k`;
- column `k` is delayed by `k` cycles, exactly like the current K input;
- V advances downward through registered PE links, not through a combinational
  32-row broadcast net;
- a signed partial sum advances from left to right across each PE row;
- PE `(i,k)` performs `psum += P[i,k] * V[k,d]`;
- the right edge emits 64 results for every query row, one feature per cycle
  after pipeline fill.

The computation is therefore:

```text
O_new[i,d] = alpha[i] * O_old[i,d]
           + sum(k=0..31) P[i,k] * V[k,d]
```

For the first KV tile, `O_old=0` and the left-edge seed is zero. For subsequent
KV tiles, the left-edge seed is `alpha[i]*O_old[i,d]`. This seed is essential;
omitting it produces a correct first tile and incorrect online accumulation.

### 3.2 Systolic alignment

Both inputs use registered skew so they meet at the same PE in the same cycle:

- top V input for column `k`: boundary delay `k+1`, then one vertical PE hop
  per query row;
- left partial-sum seed for row `i`: boundary delay `i+1`, then one horizontal
  PE hop per key column.

At PE `(i,k)`, both operands therefore arrive after `i+k+1` boundary/hop
stages. A bubble must propagate in both the V-valid and partial-sum-valid paths;
the PE updates only when both valid tokens are present.

The raw right-edge outputs are row-skewed: row 0 completes before row 31. Add a
registered right-edge de-skew delay of `ROWS-1-i` stages for row `i`. Then all
32 rows for the same feature `d` become aligned at the stripe-bank write edge.

With `ROWS=COLS=32` and the current one-register boundary convention:

```text
aligned latency = ROWS + COLS = 64 registered stages
feature d output = cycle 64 + d
last feature d=63 = approximately cycle 127
```

The raw row-0 value is observable earlier, but it is not yet a complete
32-query feature vector. The architecturally useful output stream begins after
the 64-cycle aligned latency. The controller must use propagated feature-valid
and feature-ID tags rather than a hard-coded delay counter; the exact reported
cycle number can differ by one depending on whether the accepting edge is
called cycle 0 or cycle 1.

### 3.3 PE implementation

The existing softmax rowsum register and horizontal link are phase-exclusive
with PV and can be reused as the WS partial-sum path. No additional PE-local PV
accumulator is required.

During softmax rowsum:

```text
sum_data_o <= sum_data_i + zero_extend(prob_q)
```

During WS-PV:

```text
pv_product = unsigned(prob_q) * signed(V_pipe)
sum_data_o <= signed(sum_data_i) + sign_extend(pv_product)
```

Implementation rules:

- treat `prob_q` as non-negative fixed point, not as a signed negative value
  when bit `PROB_W-1` is set;
- treat V as signed INT8 and explicitly sign-extend it before multiplication;
- retain the 32-bit signed partial-sum width and the existing final fixed-point
  normalization convention;
- register the multiply-add at every PE column, matching the current MAC timing
  shape;
- make softmax rowsum and WS-PV mutually exclusive PE modes;
- gate multiplier operands unless both V-valid and partial-sum-valid are set;
- keep `prob_q` unchanged for all 64 feature cycles and both feature halves.

`accum_q` is still required for QK Score/delta storage, so WS-PV does not remove
that register. It does remove `prob_shift_q` and the complete right-to-left
probability shift network. Probability no longer travels left and then back
through the Q path.

### 3.4 V input format and cache path

The existing 256-bit cache word is exactly the required WS issue width:
`32 keys * INT8 = 256 bits`. Its logical layout must change.

```text
WS V-cache address d -> {V[31,d], ..., V[1,d], V[0,d]}
d = 0..63
```

The current V cache is key-major, where one word contains 32 features from one
key. The physical capacity is already sufficient: both layouts store 2048
bytes per 32x64 V tile. Only the ordering changes.

Two supported load strategies are:

1. FPGA bring-up: the VCK190 PS transposes each 32x64 V tile before writing the
   accelerator cache. This requires no extra PL transpose hardware and is the
   fastest validation path.
2. Standalone/ASIC path: insert a bounded 32x32 transpose buffer for each
   feature half between the row-major load stream and V cache. It accepts 32
   key-major words and emits 32 feature-major words.

After feature-major issue, `fsa_pv_engine` sends one 256-bit `V[:,d]` vector per
cycle into the existing column-skew delay lines. The K vertical PE links are
reused without a new V broadcast network.

### 3.5 Online O storage and seed path

The natural WS result is feature-major: after right-edge de-skew, one cycle
contains the 32 query-row results for one feature. Do not merge these into one
global 1024-bit cross-array routing domain. Store them in four stripe-local
banks:

| Bank | Rows | Width | Depth | Payload at address `d` |
| --- | --- | ---: | ---: | --- |
| stripe 0 | 0-7 | 256 bits | 64 | `O[0:7,d]` |
| stripe 1 | 8-15 | 256 bits | 64 | `O[8:15,d]` |
| stripe 2 | 16-23 | 256 bits | 64 | `O[16:23,d]` |
| stripe 3 | 24-31 | 256 bits | 64 | `O[24:31,d]` |

The total accumulator capacity remains 64x1024 bits = 8 KB; it is physically
partitioned to match the stripes.

For a later KV tile, each stripe reads its 8 old O values at feature address
`d`, multiplies them by the 8 row-local alpha values, and injects the resulting
8 seeds into the corresponding PE rows. This needs eight rescale lanes per
stripe to sustain one feature per cycle. A lower-area option can share fewer
lanes, but it must pre-rescale O in a separate pass and will increase PV
latency.

After the final KV tile, normalization/AXI require row-major order. Use a
bounded 32x32 reorder for each feature half, or an equivalent banked reader;
never expose the complete 32x64 accumulator as a flat combinational matrix.

### 3.6 Concrete RTL implementation path

Implement WS-PV as one coherent replacement, in this order:

1. Add a feature-major V-cache contract and a module TB that proves the mapping
   `address d -> V[0:31,d]`. Keep PS-side transpose for the first FPGA test.
2. Add four 256-bit x 64 stripe-local O accumulator banks with independent
   enables and no inactive-bank switching.
3. Extend `os_fsa_fused_pe` with a WS-PV mode that multiplies stationary
   `prob_q` by the vertical V operand and writes the horizontal `sum_data_o`
   register. Preserve the existing softmax rowsum behavior in its own mode.
4. Extend `os_fsa_stripe` with a 32-bit partial-sum left boundary, a registered
   right boundary, local V/psum valid tokens, and stripe-local right-edge
   de-skew. Keep all PE links as constant-index unpacked arrays.
5. In `os_fsa_fused_array`, disable the Q/probability-restream source during PV,
   reuse the K column skew for V, and route only four 256-bit aligned result
   streams to the O banks.
6. Replace `fsa_pv_engine` row loading and probability shifting with a 64-cycle
   feature issue loop. For the first KV tile inject zero seeds; otherwise read
   O/alpha and inject `alpha*O_old` seeds.
7. Add feature-valid, feature-ID, first/last-feature, and tile-last tags through
   the complete pipeline. Completion is driven by the final propagated tag,
   not a fixed 64/127 counter.
8. Add final feature-major to row-major reorder and connect it to the existing
   normalizer/output AXI stream.
9. Only after two-KV-tile regression passes, remove `prob_shift_q`,
   `prob_shift_*`, the old OS-PV accumulator-row load/read ports, and the
   superseded row-major accumulator path.

### 3.7 Cost and expected benefit

Benefits relative to the current OS-PV path:

- P never moves after exp writeback;
- removes 16,384 `prob_shift_q` bits in a 32x32 array;
- removes the right-to-left probability shift followed by left-to-right Q-path
  traversal, reducing switching and control fanout;
- reuses the registered K vertical path and rowsum horizontal path;
- produces one 32-row feature vector per cycle after fill;
- result storage is naturally localized to four stripe banks.

Costs:

- 32-bit row-seed skew and right-edge de-skew storage are required. A direct
  register implementation is approximately 32 Kbits total; FPGA should map
  these delays to SRLs/BRAM where practical;
- sustaining one feature per cycle on later KV tiles needs 32 alpha-rescale
  multipliers, physically grouped as 8 per stripe;
- V load ordering and final output ordering require bounded transpose/reorder
  stages;
- the PE rowsum path becomes a multiply-add path during PV, so its timing must
  be checked against the same target as the existing registered MAC path.

The expected primary gain is lower PE-state movement and better physical
locality, not a large flip-flop-area reduction. The additional boundary skew
storage partly offsets the removed probability-shift registers.

### 3.8 Required verification before removing OS-PV

- PE directed tests for unsigned probability times negative/positive INT8 V;
- 4x4 and 32x32 wavefront tests proving `(i,k,d)` alignment;
- feature IDs 0, 31, 32, and 63 across both cache halves;
- right-edge de-skew checks at stripe boundary rows 7/8, 15/16, and 23/24;
- first KV tile with zero seed;
- at least two KV tiles checking `alpha*O_old + P*V` against the fixed-point
  software model;
- random input bubbles with V and partial-sum valid alignment;
- causal and tail tiles, ensuring masked `prob_q` contributes zero;
- final feature-major to row-major reorder and AXI byte order;
- assertions that softmax rowsum and WS-PV never drive `sum_data_o` together.

## 4. Packed Versus Unpacked Arrays

Internal PE and neighbor links now use unpacked two-dimensional arrays inside
`os_fsa_stripe`. This makes constant neighbor ownership explicit and prevents
manual flattened-index arithmetic from hiding long connections.

Unpacked syntax alone does not remove hardware. A variable access such as
`state[row_id][lane]` still synthesizes a mux. The implemented rule is:

- constant `genvar` access for PE-to-PE links;
- variable row selection only inside an 8-row stripe;
- register the selected stripe row before it leaves the stripe;
- never export all PE state through a module port;
- preserve stripe hierarchy during synthesis and floorplan each stripe as a
  placement region.

## 5. P0 Findings and Status

### P0.1 Dynamic delta-row selection: fixed

The full delta matrix and central `ROWS:1` selector were removed. A tagged
request selects one of at most eight local rows inside the owning stripe. The
selected row is registered at the stripe boundary before driving the shared
exp lanes.

### P0.2 Dynamic accumulator-row selection: fixed for the current OS-PV path

The full accumulator matrix and central selector were removed. Row completion
is read through the owning stripe's registered row response. The external row
transfer remains 1024 bits for the bounded 32-column core.

### P0.3 Exp-result broadcast: fixed

Exp results are sent only to the selected stripe. That stripe performs an
8-row local decode. The result no longer fans out to every PE row.

### P0.4 Wide O-accumulator load: partially fixed

Load-valid and row decode are stripe-local, reducing control fanout from 32 to
8 PEs. The 1024-bit row data still reaches the selected stripe. A later design
should bank it into four or eight 128/256-bit groups. The WS-PV organization in
Section 3 removes this row-load pattern entirely.

### P0.5 Full row-state export: fixed

The fused array now exposes a synchronous narrow request/response interface:

```text
row_state_rd_en, row_id -> row_state_rd_valid, alpha, l
```

The PV engine and final normalizer arbitrate this interface at the top level.

### P0.6 False large-array parameterization: guarded

`CACHE_LANES=CACHE_WORD_W/CACHE_ELEM_W` is explicit. QK, PV, fused-array, top,
and output-buffer modules reject configurations where the physical array does
not match the 32-lane cache word. Index widths and output-buffer depth are now
derived parameters. Logical dimensions larger than 32 remain scheduler-level
subtiles, not physical array parameters.

## 6. P1 Findings and Status

### P1.1 Arithmetic replication outside the PE: partially fixed

- LSE `old_l*alpha` update is serialized to one row per cycle and uses one
  multiplier.
- PV rescale multiplier operands are held at zero except during a valid row
  load, but the current OS-PV path still contains 32 parallel rescale lanes.
- Exp and final-normalizer lane counts are still coupled to the physical
  32-lane word.

Independent `EXP_LANES`, `RESCALE_LANES`, and `NORM_LANES` are still required
before exploring a different physical core width.

### P1.2 Full-grid mask logic: partially fixed

Query index/range is computed once per row and key index/range once per column.
Only the causal `key_index <= query_index` decision remains per PE lane. A
diagonal valid-token implementation can remove those replicated comparators if
mask timing becomes critical.

### P1.3 High-fanout control: contained by hierarchy

Phase, clear, probability-load, and accumulator-load commands enter four
stripe instances. Row decode occurs locally with fanout bounded to eight rows.
The stripe modules carry `keep_hierarchy`, and DC synthesis disables ungrouping
at stripe boundaries. FPGA pblocks and ASIC placement groups are still needed
in the implementation flow; RTL hierarchy alone is not a floorplan.

### P1.4 Physical stripes: fixed

`os_fsa_fused_array` instantiates real `os_fsa_stripe` modules. Each stripe owns
8x32 PEs, local Q/K and reduction links, local probability/accumulator decode,
and registered delta/accumulator row access. K and valid tokens cross stripe
boundaries through explicit ports.

### P1.5 Wide output memory: open

`output_buffer` is parameterized but still operates on a 1024-bit accumulator
row and 256-bit normalized word. It is acceptable for the fixed 32-column core,
but it activates a broad bank. The next memory refactor should use 128/256-bit
groups or the feature-major stripe banks required by WS-PV.

## 7. P2 Findings and Status

### P2.1 Quadratic skew storage: bounded

Boundary skew remains quadratic in physical rows/columns. This is acceptable
only because the core is fixed at 32x32. FPGA implementation should infer SRLs
or shallow distributed memories where beneficial; ASIC implementation should
place enabled shift-register chains at the array edges.

### P2.2 Multiplier operand isolation: fixed where enabled

PE multiply operands toggle only on valid Q/K or P/V work. PV rescale operands
toggle only during an accepted row load. Clock gating can be added after real
activity factors are available, but functional operand isolation is present.

### P2.3 Wide declarations hiding locality: fixed for PE links

Q, K, max, reverse-m, sum, delta, probability-shift, and accumulator links are
unpacked arrays within each stripe. Wide packed vectors remain only at explicit
registered or bounded module boundaries.

## 8. Verification Requirements

Every subsequent dataflow change must retain these tests:

- signed INT8 QK and PV arithmetic, including negative operands;
- causal, partial-row, and partial-column masks;
- two feature halves using the same PE-local probabilities;
- at least two KV tiles, checking `m_new`, `alpha`, `l_new`, and
  `alpha*O_old + P*V`;
- stripe-boundary rows 7/8, 15/16, and 23/24;
- registered delta, accumulator, and row-state request/response timing;
- randomized backpressure on row output;
- no X propagation on inactive stripe responses.

For a future WS-PV implementation, a one-KV-tile test is insufficient. The
minimum acceptance test is two KV tiles and both 32-feature halves, compared
against the fixed-point software model.
