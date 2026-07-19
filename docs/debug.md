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

The former score and PV accumulators were reduced to one QK-only `accum_q`.
The active schedule is:

1. QK MAC stores Score in `accum_q`.
2. Rowmax consumes Score.
3. The reverse `m_new` pass overwrites `accum_q` with `Score - m_new`.
4. Exp and rowsum consume the delta and write `prob_q`.
5. WS-PV reuses `sum_data_o`; `accum_q` is idle until the next QK clear.

The merge saves 32 bits per PE at the default width. Overwriting Score with
delta saves another 32 bits per PE by removing `delta_q`.

| Physical array | State removed |
| --- | ---: |
| 32x32 | 65,536 bits |
| 128x128 monolith, unsupported | 1,048,576 bits |

The PE multiplier operands are isolated unless the matching Q/K or V/partial-
sum valids are asserted. Clear has highest priority, followed by reverse-m
overwrite and QK MAC.

### 2.2 Removed probability shift state

`prob_shift_q` and the complete right-to-left probability network were removed.
`prob_q` remains stationary across one continuous 64-feature WS-PV stream,
while V and the horizontal partial sum move through the existing registered PE
links. Half tags remain only for row-buffer and output-SRAM ownership.

### 2.3 Column-streamed SUB, P-exp, and rowsum overlap

The scale-plus-exp path has seven cycles of latency: four stages in
`scale_requant_unit` and three in `pwl_exp_unit`. Its initiation interval is one
32-element vector per cycle, not one vector per seven cycles.

The reverse `m_new` wave makes all 32 rows of column `c` complete
`Score-m_new` together, in column order `31,30,...,0`. The shared exp lanes now
map to rows and consume that completed column immediately. A seven-stage column
tag pipeline returns each probability vector to the same PE column. One cycle
after column 31 writes `prob_q`, a right-to-left rowsum token starts at the
right edge and follows the probability writeback wave through columns 30 to 0.
SUB, P-exp, and rowsum are therefore concurrent column wavefronts.

All 32 row sums finish together. A 32x32-bit capture register holds them while
the existing single `old_l*alpha` multiplier updates row state at one row per
cycle. This adds 1 Kbit of bounded state, keeps the exp and LSE multiplier counts
unchanged, and removes the former row-request delta interface.

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

O remains row-major in the existing 64x1024-bit output buffer. Before a
non-first KV tile, `fsa_pv_engine` reads and rescales both old-O halves for all
rows. Each stripe row owns two 32-entry buffers.

1. Features 0--31 shift half-0 seeds from buffer 0.
2. Features 32--63 shift half-1 seeds from buffer 1 while buffer 0 collects
   half-0 right-edge results.
3. After the 64th issue, buffer 1 collects the half-1 drain.

Only different buffers may issue and collect in the same cycle; a simulation
assertion rejects a same-half collision. This costs 64 Kbits of stripe-local
storage for the 32x32 core, but removes the half-boundary drain/restart and
still avoids a feature-major O SRAM or final transpose.

### 3.6 Implemented RTL path

1. V cache issue is feature-major and contiguous: address `d=0..63` returns
   `V[0:31,d]`.
2. `fsa_fused_pe` keeps `prob_q` stationary and updates the registered
   horizontal sum with `sum_in + prob_q*V`.
3. `fsa_stripe` owns two row-local seed/result buffers per row and local row
   load decode.
4. `fsa_fused_array` reuses the K column skew for V and adds an ACC-width row
   seed skew. Q boundary links are inactive during PV.
5. `fsa_pv_engine` preloads both old-O halves for later KV tiles and issues 64
   feature vectors in one array invocation.
6. Completed row halves return in natural staggered row order to the unchanged
   row-major output buffer and final row-wise normalizer.
7. `prob_shift_q`, PE PV accumulator state, accumulator matrix reads, and all
   active `os_*` file/module names were removed.

### 3.7 Cost and expected benefit

Benefits relative to the removed OS-PV path:

- P never moves after exp writeback;
- removes 16,384 `prob_shift_q` bits in a 32x32 array;
- removes the right-to-left probability shift followed by left-to-right Q-path
  traversal, reducing switching and control fanout;
- reuses the registered K vertical path and rowsum horizontal path;
- produces one feature result per active row per cycle after row fill;
- writes completed row halves directly to the existing output buffer.

Costs:

- 64 Kbits of stripe-local row buffers and ACC-width left-edge seed skew are
  required; FPGA should map long delay portions to SRLs where practical;
- sustaining row preload throughput retains the existing 32 alpha-rescale
  multipliers, operand-gated outside valid row loads;
- V must be transposed to feature-major order before cache issue;
- the PE rowsum path becomes a multiply-add path during PV, so its timing must
  be checked against the same target as the existing registered MAC path.

Per the scope of this RTL round, the PV/O datapath remains at the existing
32-bit signed accumulation width. Wider accumulation, saturation/rounding
policy changes, and the corresponding overflow proof are deliberately deferred
and are not implied by the WS-PV dataflow conversion.

### 3.8 Measured Cycle Benefit

The directed top-level regression contains two KV tiles. All rows, cache
traffic, final normalization, and AXI writeback are included in the reported
cycle count.

| Implementation stage | Top cycles | Stage cycles saved | Stage reduction | Cumulative reduction |
| --- | ---: | ---: | ---: | ---: |
| Original fused-array baseline | 2174 | - | - | - |
| Probability-stationary WS-PV | 1794 | 380 cycles | 17.5% | 17.5% |
| Continuous 64-feature WS-PV plus row-streamed softmax | 1581 | 213 cycles | 11.9% | 27.3% |
| Column-streamed SUB/exp/reverse-rowsum wave | 1519 | 62 cycles | 3.9% | 30.1% |
| Overlap WS-PV with serialized `l` update | 1453 | 66 cycles | 4.3% | 33.2% |

The final 62-cycle gain matches two KV tiles times `COLS-1`, confirming that
the column wave removes one serial column traversal per tile. The 64 V issues
are still followed by one registered array drain; complete-tile latency is
greater than 64 cycles even though the issue interval is exactly 64 cycles.

WS-PV and the serialized `l` update are overlapped in the current RTL. The
active sequence is:

```text
capture all row sums -> softmax_pv_ready_o -> WS-PV
                     \-> SM_L_UPDATE for ROWS cycles -> softmax_done_o
```

The scheduler enters PV on `softmax_pv_ready_o`, which pulses when all row sums
have been captured and stationary `prob_q` is complete. `softmax_done_o` keeps
its stronger meaning and is asserted only after the last serialized
`old_l*alpha+local_l` update. Current-tile WS-PV consumes `prob_q` and `alpha`,
not the new `l`, so these operations have no data hazard.

The top level records `softmax_done_o` in sticky `l_update_done_q`. If PV were
to drain before the row-state update, `PV_FLOW_WAIT_L` holds the tile boundary;
the next softmax and final normalization cannot start until `l_update_done_q`
is set. This guard is required even though the present 32-row update is shorter
than WS-PV, because future array and feature dimensions can change that ordering.

The measured 66-cycle reduction is 33 cycles per KV tile: it hides the 32
serialized row updates plus the former softmax-to-PV completion boundary. The
new top result is 1453 cycles, 33.2% below the original 2174-cycle baseline.

### 3.9 Deferred verification expansion

- PE directed tests for unsigned probability times negative/positive INT8 V;
- 4x4 and 32x32 wavefront tests proving `(i,k,d)` alignment;
- feature IDs 0, 31, 32, and 63 across both cache halves;
- row-buffer ordering checks at stripe boundary rows 7/8, 15/16, and 23/24;
- first KV tile with zero seed;
- at least two KV tiles checking `alpha*O_old + P*V` against the fixed-point
  software model;
- random input bubbles with V and partial-sum valid alignment;
- causal and tail tiles, ensuring masked `prob_q` contributes zero;
- feature-major V cache order and row-major O/AXI byte order;
- assertions that softmax rowsum and WS-PV never drive `sum_data_o` together.

## 4. Packed Versus Unpacked Arrays

Internal PE and neighbor links now use unpacked two-dimensional arrays inside
`fsa_stripe`. This makes constant neighbor ownership explicit and prevents
manual flattened-index arithmetic from hiding long connections.

Unpacked syntax alone does not remove hardware. A variable access such as
`state[row_id][lane]` still synthesizes a mux. The implemented rule is:

- constant `genvar` access for PE-to-PE links;
- variable selection remains bounded inside a physical stripe;
- the active delta column uses a registered 32:1 selector per stripe row;
- split the physical core into column groups before increasing `COLS` beyond 32;
- never export all PE state through a module port;
- preserve stripe hierarchy during synthesis and floorplan each stripe as a
  placement region.

## 5. P0 Findings and Status

### P0.1 Dynamic delta-row selection: fixed

The full delta matrix and central `ROWS:1` selector were removed. Each stripe
registers only the active reverse-wave column for its eight local rows. Four
fixed stripe slices concatenate into the 32 exp lanes; no complete delta tile
or variable row request crosses a module boundary. The local 32:1 column
selector is bounded to the fixed 32-column core and must be column-banked for a
larger physical array.

### P0.2 Dynamic accumulator-row selection: fixed

The full accumulator matrix and central selector were removed. WS-PV results
are collected sequentially in each row-local buffer and emitted only when a
complete 32-feature row half is ready.

### P0.3 Exp-result broadcast: fixed

Each stripe receives only its fixed eight-row probability slice. The returned
column tag is decoded locally across 32 columns, so result data does not fan out
across stripes and no array-wide row decode remains.

### P0.4 Wide O-accumulator load: partially fixed

Load-valid and row decode are stripe-local, reducing control fanout from 32 to
8 PEs. The 1024-bit row data still reaches the selected stripe. A later design
should bank it into four or eight 128/256-bit groups in a later memory pass.

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
  load; the WS-PV row preload still contains 32 parallel rescale lanes.
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

`fsa_fused_array` instantiates real `fsa_stripe` modules. Each stripe owns 8x32
PEs, local Q/K/V and reduction links, stationary probabilities, row-local
seed/result buffers, and registered delta-column access. K/V and valid tokens
cross stripe boundaries through explicit ports.

### P1.5 Wide output memory: open

`output_buffer` is parameterized but still operates on a 1024-bit accumulator
row and 256-bit normalized word. It is acceptable for the fixed 32-column core,
but it activates a broad bank. The next memory refactor should use 128/256-bit
groups if the fixed 32-column core later changes.

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

Q, K/V, max, reverse-m, sum, and delta links are unpacked arrays within each
stripe. Wide packed vectors remain only at explicit registered or bounded
module boundaries.

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

The active WS-PV path passes the existing one-tile identity-V array test and
the existing two-KV-tile top test. Nontrivial alpha, signed V, overflow, and
expanded random coverage are intentionally deferred to the next verification
round.

## 9. Post-Overlap Full RTL Audit

This audit covers the complete current RTL hierarchy, not only the overlap
diff. VCS Verilog-2001 lint and all 21 directed module/integration tests pass;
the two-KV-tile top test completes in 1453 cycles.

### 9.1 Overlap contract: confirmed

- `softmax_pv_ready_o` is generated only after all row sums are captured.
- WS-PV reads completed `prob_q` and `alpha`; it does not read the new `l`.
- `softmax_done_o` is retained until the last serialized `l` write completes,
  and top-level sticky `l_update_done_q` protects both tile advance and final
  normalization through `PV_FLOW_WAIT_L`.
- QK cannot restart while current PV is active, so overlapping the central
  row-state multiplier does not conflict with PE QK state.

### 9.2 P0 synthesis risks

1. `fsa_fused_pe` contains separate QK and WS-PV multiplication expressions.
   Although their valids and phases are mutually exclusive, synthesis is not
   guaranteed to share them. The worst mapping is two multipliers per PE. Use
   one explicitly selected signed multiplier input/result path, then confirm
   the mapped multiplier count and operand isolation.
2. The two WS-PV row buffers are 64 Kbits of shift-register state across the
   32x32 array. Each feature issue shifts one complete active half. Whole-row
   load, shift, and result insertion make clean BRAM/URAM/SRAM inference
   unlikely and create a large clock/power load. Replace shifting with two
   per-row depth-32, width-32 banks and circular read/write pointers; narrow the
   output-buffer write interface so a complete 1024-bit row need not be read in
   one cycle.
3. ASIC cache composition is substantially overprovisioned for the active
   64-address Q/K/V issue window: six 1024x256 logical memories expand to many
   256x8 macros. Right-size cache depth or deliberately use the extra depth for
   multiple resident tiles. In addition, `asic_sram_1024x16` selects the depth
   slice with the current high address bits rather than a read-aligned
   registered tag; consecutive reads crossing a 256-word boundary require a
   registered depth select.

### 9.3 P1 area, timing, and routing risks

- The current 32-lane datapath instantiates 32 score-scale multipliers, 32 PWL
  interpolation multipliers, 32 old-O/alpha rescale multipliers, and two
  multiplier stages in each of 32 final-normalizer lanes. These blocks need an
  explicit multiplier budget and, if necessary, independent lane-count/time-
  multiplex parameters.
- Each stripe still contains eight registered 32:1 delta-column selectors.
  They are bounded and local, but can remain a softmax critical path; split
  columns into fixed groups and pipeline the group select if timing fails.
- Causal masking still replicates a 17-bit key/query comparison over the full
  32x32 grid. A diagonal mask token or row threshold can replace 1024 compares.
- `pv_load_row_data`, `pv_row_data`, and the accumulator SRAM word are each
  1024 bits. Stripe-local decode limits fanout, but physical routing and the
  1024-bit SRAM wrapper remain implementation hotspots.
- Probability-column decode, phase, clear, and valid controls drive many PEs.
  Stripe hierarchy helps only if FPGA pblocks or ASIC placement/CTS buffering
  preserve the intended locality.

### 9.4 P2 implementation and protocol risks

- Top-level writeback address generation contains two wide combinational
  multiplications. Replace it with registered incremental address counters if
  it appears on a control critical path.
- `reciprocal_lut` uses a 32-bit priority encoder plus variable normalization
  shifters before its output register; pipeline leading-zero detection and
  normalization if final-normalizer timing is weak.
- QK/PV cache issue counters advance on requests, while completion counts use
  returned valids. The current SRAM contract is fixed-latency; any future
  bubble-capable memory interface needs request/response credit tracking.
- The AXI writer does not split bursts at 4-KB boundaries. Software alignment
  currently avoids this in the directed test, but a production DMA path must
  enforce or implement the AXI boundary rule.
- Reset/clear and phase nets remain high fanout. Prefer local synchronous clear
  trees and operand/clock enables after physical synthesis exposes the actual
  fanout and activity hotspots.

No synthesis or place-and-route result is claimed by this audit. The next
decision point is the multiplier/RAM inference report; it determines whether
the explicit PE multiplier merge and circular-buffer refactor are mandatory
before timing closure.
