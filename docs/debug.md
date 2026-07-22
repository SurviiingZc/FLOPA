# RTL Optimization and FPGA Bring-Up Baseline

## 1. Scope

This document is the implementation baseline for two stages:

- Stage 1: the current 32x32 prefill accelerator used for initial VCK190
  integration and prefill measurements;
- Stage 2: native decode and grouped-query attention (GQA), which is a guided
  extension and is not implemented in the current RTL.

The physical array remains 32x32, partitioned into four 8x32 stripes. Logical
dimensions larger than 32 are tiled by the scheduler. A monolithic 128x128
physical array is not supported by changing parameters alone.

Q/K/V are loaded and transported through the array as native signed INT8 and
are extended only at the PE multiplier input. Probability is unsigned Q1.15, and O uses
the existing signed 32-bit accumulation path. Wider accumulation, formal
overflow bounds, and revised saturation/rounding are separate work items.

## 2. Stage 1 Final Prefill Dataflow

For PE coordinate `(query row i, key column k)`:

1. QK uses output-stationary accumulation to produce `S[i,k]` in PE-local
   `accum_q`.
2. Row max moves left-to-right inside each PE row. `m_new` then moves
   right-to-left and overwrites `accum_q` with `S[i,k]-m_new[i]`.
3. Completed delta columns feed 32 row-parallel scale/exp lanes. Probability
   returns to the tagged PE column and remains stationary in `prob_q`.
4. The reverse rowsum wave starts as soon as the first completed probability
   column is available; SUB, exp writeback, and rowsum overlap.
5. All row sums are captured. One `old_l*alpha` unit updates `l` row by row,
   while WS-PV starts from the earlier probability-ready event.
6. V is stored feature-major. Cycle `d` presents `V[0:31,d]`; the K vertical
   links carry V and the rowsum horizontal links carry partial sums.
7. The right edge produces `O_new[i,d]` and writes it directly to persistent,
   row-banked O storage using the propagated feature ID.

The online update is:

```text
O_new[i,d] = alpha[i] * O_old[i,d]
           + sum(k=0..31) P[i,k] * V[k,d]
```

The first KV tile uses a zero seed. Later tiles synchronously read the old O
feature, multiply each row by its stored alpha, and inject the rescaled value at
the left edge. All `HEAD_DIM=64` features are one continuous WS-PV invocation;
there is no half-boundary restart.

## 3. Six Implemented Optimization Points

### 3.1 One explicit PE multiplier

`fsa_fused_pe` now contains one multiplication expression and phase-selected
operands:

```text
QK:    signed Q x signed K
WS-PV: unsigned P x signed V
```

Both operands are explicitly extended before multiplication to avoid Verilog
signed-product truncation. Invalid operands are forced to zero, reducing
unnecessary multiplier switching. QK and WS-PV remain phase-exclusive and no
new pipeline register was added.

FPGA gate: confirm the post-synthesis DSP report maps one logical multiplier
per PE. The explicit RTL sharing removes duplicate expressions, but the final
DSP count and any decomposition of the extended signed multiplier must still
be checked in Vivado.

### 3.2 Persistent row-banked O storage

The former two shifting row buffers, row preload states, wide accumulator SRAM,
and 1024-bit row load/result ports were removed. Each 8-row stripe owns an
`o_accumulator_bank` indexed by full feature ID.

- FPGA backend: inferred block RAM with synchronous read;
- ASIC backend: independent single-port feature-group macros;
- write: every row may write its returned feature simultaneously because rows
  are physically independent banks;
- seed read: all stripes read the same feature for WS-PV;
- final normalization: only the selected stripe reads a feature;
- a simulation assertion rejects read/write access to the same single-port
  feature group in one cycle.

`FEATURE_GROUPS=ceil(HEAD_DIM/ARRAY_COLS)`. The default 64-dimensional design
has two physical groups; a 128-dimensional configuration has four. These groups
are storage banks, not serial compute halves.

### 3.3 Parameterized tile-cache depth and SRAM selection

The on-chip Q/K/V cache depth is `HEAD_DIM`, not model context length. With
`HEAD_DIM=64`, each ping-pong side stores 64 feature words; autoregressive
history remains in PS DDR/LPDDR.

- `CACHE_ADDR_W=clog2(HEAD_DIM)` for the current configuration;
- ASIC configurations with address width up to 8 use the 256-depth wide SRAM
  wrapper directly;
- larger configurations retain depth composition;
- `asic_sram_1024x16` now registers the depth tag so consecutive reads across
  address 255/256 select the macro output aligned with the returned data;
- unselected SRAM banks keep their enable inactive for dynamic-power control.

This change reduces the default ASIC Q/K/V cache composition from four unused
depth slices per logical bank to one while preserving the 32-token tile.

### 3.4 Eight-lane final normalization and narrow output assembly

Final normalization now consumes one stripe at one feature per cycle:

```text
8 O accumulators + 8 l values -> 8 normalized INT8 outputs
```

It instantiates eight reciprocal pipelines and sixteen normalization/scale
multipliers instead of the former 32 reciprocals and 64 multipliers. The output
buffer collects 32 feature bytes for eight rows in local 256-bit pack registers,
then writes the eight completed row/group words sequentially to output SRAM.

No 1024-bit accumulator row crosses a module boundary. The final SRAM stays
256 bits wide because that width naturally serves two 128-bit AXI beats.

### 3.5 Bounded delta, mask, and probability control

- Delta selection is hierarchical inside each stripe: four local 8-column
  groups, one register boundary, then a bounded group mux and output register.
  The initiation interval remains one completed column per cycle.
- Causal/padding validity is converted during QK setup into a registered
  32-bit thermometer mask for each row. Runtime PE lanes no longer contain a
  full grid of 17-bit key/query comparisons.
- The probability column ID enters each stripe once and is decoded locally to
  a 32-bit one-hot enable. Each selected column drives only the stripe's eight
  PEs.
- WS-PV phase is registered at the stripe boundary, containing control fanout
  within the physical hierarchy.

The extra delta selector register is carried by the existing column tag, so it
adds startup latency but does not reduce column throughput.

### 3.6 Address, reciprocal, and AXI hardening

- Output address generation uses registered head-base, head-stride, and
  incremental Q-tile counters instead of two runtime combinational address
  multiplications.
- Reciprocal is split into input capture, leading-zero/normalization, and
  LUT/shift stages. It accepts one value per cycle.
- AXI write bursts are limited by configured burst length, remaining beats,
  and beats to the next 4-KB boundary.
- Misaligned output base addresses are rejected because the datapath emits
  16-byte beats.

The Q/K/V cache interface still assumes fixed-latency responses. A future
stallable source must add ready/credit tracking rather than advancing issue
counters only from requests.

## 4. Cycle Result

The directed top regression contains two KV tiles, final normalization, and
AXI writeback.

| Implementation point | Top cycles | Saved from prior | Cumulative saving |
| --- | ---: | ---: | ---: |
| Original fused-array baseline | 2174 | - | - |
| Probability-stationary WS-PV | 1794 | 380 | 17.5% |
| Continuous feature stream and row-streamed softmax | 1581 | 213 | 27.3% |
| Column-overlapped SUB/exp/rowsum | 1519 | 62 | 30.1% |
| WS-PV overlapped with serialized l update | 1453 | 66 | 33.2% |
| Six-point storage/control optimization | 1334 | 119 | 38.6% |
| Round-4 timing pipeline boundaries | 1348 | -14 | 38.0% |
| Round-5 local-clear and O-rescale pipelines | 1354 | -6 | 37.7% |

The six-point optimization removed 119 cycles, or 8.2% of the preceding
1453-cycle implementation. The following timing round deliberately returns 14
startup cycles to cut three synthesis-critical paths while retaining II=1.

## 5. Verification Status

All 25 normal module/integration TBs pass with default FSDB generation enabled.
The dedicated TT SRAM-macro backend test also passes. Coverage includes:

- Verilog-2001 VCS lint of `attention_accel_top`, with no RTL lint warnings;
- successful top-level elaboration with `HEAD_DIM=128`, including derived
  7-bit cache addresses and four O feature groups;
- fused-array QK, column softmax, continuous feature-tagged WS-PV, and O-bank
  readback;
- stripe rowsum and probability-stationary WS-PV write/read;
- O-bank feature groups 0 and 1;
- eight-lane normalizer numerical saturation and tag alignment;
- output byte packing, AXI backpressure, and partial final strobe;
- reciprocal pipeline values;
- consecutive ASIC SRAM responses across addresses 255 and 256 with the
  registered depth-select tag;
- AXI burst splitting for a transfer beginning at address offset `0xff0`;
- two-KV-tile top-level flow, completing in 1354 cycles after the timing cuts.

Before FPGA bitstream sign-off, add or retain system tests for signed random V,
nontrivial alpha on at least two KV tiles, causal tail tiles, `HEAD_DIM=128`, and
random AXI backpressure. The current directed tests establish the dataflow and
interfaces; they are not an overflow proof.

## 6. Remaining Stage 1 FPGA Risks

### 6.1 Must inspect after synthesis

- DSP count: one selected PE multiply expression must not duplicate into QK
  and PV hardware; inspect DSP cascade depth and the PE MAC critical path.
- The 32 score-scale lanes, 32 exp interpolation lanes, and 32 old-O rescale
  lanes remain area-heavy. Do not reduce these lanes before measuring achieved
  Fmax and resource pressure because they are on the per-KV-tile path.
- Confirm O banks infer BRAM/URAM rather than distributed registers. Check RAM
  port collision reports and the placement of each 8x32 stripe near its banks.
- The local second-stage delta mux and exp scale multiplier are likely timing
  candidates. Use WNS path details, not RTL depth estimates, to decide whether
  another register is necessary.
- Q/K/V and boundary skew chains are quadratic in the fixed physical 32x32
  core. Confirm SRL/BRAM inference and avoid scaling the physical array to
  128x128.
- Clear and phase signals remain high-fanout inside a stripe. Use pblocks and
  replicated local enables if the routed design reports control-net problems.

### 6.2 FPGA acceptance data

Record utilization by hierarchy, DSP/BRAM/URAM counts, WNS/TNS, achieved clock,
top ten critical paths, high-fanout nets, route congestion, and dynamic power.
For each workload also record `perf_cycles`, `perf_stall`, tile count, DMA
submit/completion timestamps, and PL loader underruns.

For INT8 K and V, bytes per KV tile and KV head are:

```text
B_KV_tile = 2 * TILE_K * HEAD_DIM
```

The default `TILE_K=32`, `HEAD_DIM=64` tile is 4096 bytes. Ping-pong overlap is
effective only when measured DMA time for the next tile does not exceed current
tile compute time. The Stage 1 pass condition is no loader underrun and less
than 5% load-stall cycles at the selected production clock.

## 7. Stage 2 Native Decode and GQA Guidance

Stage 2 must preserve the Stage 1 PE and softmax math while replacing the
scheduler/cache lifetime rules. It should not be implemented as PS-side MHA
expansion for the final result.

### 7.1 Native GQA ownership

For `NUM_Q_HEADS/NUM_KV_HEADS = GQA_GROUP_SIZE`, one K/V tile is loaded once
and consumed by all Q heads mapped to that KV head.

Required control state:

- `kv_head_id` and `q_head_in_group`;
- a per-active-bank reference count initialized to `GQA_GROUP_SIZE`;
- consume/switch only when the last mapped Q head releases the bank;
- Q-head-specific `m`, `l`, and persistent O state;
- one shared K/V cache view while Q changes between group members.

For SmolLM2-135M, nine Q heads and three KV heads give a reuse factor of three.
The acceptance test must show approximately 3x less K/V tile traffic than MHA
expansion, excluding alignment and descriptor overhead.

### 7.2 Decode row packing

`seq_q=1` uses only one query row if scheduled directly. Pack independent work
into the 32 physical rows in this order:

1. Q heads for the same token, grouped by their shared KV head;
2. independent batch items or beams;
3. masked idle rows only when no independent work is available.

Each physical row needs metadata `{batch, beam, q_head, kv_head, token}`. Mask
generation and O/l/m state indexing must use this metadata rather than assuming
adjacent rows are adjacent sequence positions.

### 7.3 Autoregressive KV-cache flow

The model-level KV cache stays in PS DDR/LPDDR; the PL cache stores only current
and next 32-token tiles.

```text
append new K/V token to model-level DDR cache
for each historical 32-token tile:
    DMA the next native KV-head tile into the inactive bank
    run QK -> online softmax -> WS-PV on the active bank
    retain the bank until every mapped Q head completes
normalize O after the final historical tile
```

Reducing the PL tile-cache depth therefore does not discard history. Decode
performance depends on sustained DDR/NoC bandwidth and overlap, which must be
measured at context lengths 128, 512, 1024, and 2048 before increasing on-chip
capacity.

### 7.4 Decode implementation order

1. Add scheduler-visible head mapping and GQA bank reference counts.
2. Separate Q-head state addressing from physical row ID.
3. Add row-packing descriptors and `seq_q=1` mask generation.
4. Add a context-length-driven KV tile loop and DMA descriptor queue.
5. Add ping-pong underrun handling and performance counters per head/tile.
6. Validate batch 1, then enable multi-batch/beam packing.

### 7.5 Stage 2 verification and acceptance

Compare against the same fixed-point PS reference for prefill and every decode
token. Cover unequal Q/KV head counts, tail head groups, causal context tails,
bank reuse, and contexts spanning many KV tiles.

Report:

- latency per generated token and tokens/s;
- DDR bytes/token and achieved bandwidth;
- physical-row and PE utilization;
- native GQA reuse factor;
- DMA overlap and load-stall ratio;
- driver and descriptor overhead;
- numerical error versus the fixed-point reference.

Stage 2 is accepted only when native GQA reduces K/V traffic, token outputs
match the reference, and end-to-end latency includes DMA and software overhead.
Until then, the RTL release is classified as a prefill baseline.

## 8. Round-3 Datapath and Physical-Risk Cleanup

### 8.1 Implemented RTL changes

- Q/K/V engine outputs, array links, and PE forwarding registers now remain
  signed INT8. The phase-exclusive PE multiplier uses signed 17-bit and 9-bit
  operands, preserving exact 16-bit QK and 24-bit PV products while keeping P
  as independent unsigned Q1.15.
- The final normalizer verifies the sign-extension bound after the first
  product shift, narrows it to signed 48 bit, and feeds an exact latency-2,
  II=1 48x16 multiplier. Valid, tag, and result-shift metadata cross the same
  two registered boundaries.
- `q_last`, `k_last`, and `mac_last` were removed from every PE. A single
  `ROWS+COLS` array-level completion shift register supplies fixed rowmax taps
  and the final QK-done tap.
- Valid-qualified Q/K/V, skew, arithmetic, exp, reciprocal, and normalization
  payload registers no longer carry unnecessary asynchronous reset. Valid,
  phase, counters, tags needed for addressing, and externally observable state
  retain deterministic reset behavior.
- The default SRAM input `set_min_delay` is zero. Liberty hold checks, hold
  uncertainty, and `set_fix_hold` remain; signoff repair is reserved for the
  fast-cell/fast-SRAM/min-RC propagated-clock CTS scenario.
- Every mixed-width multiply was audited for Verilog expression sizing. One
  operand is extended only to the result context so high product bits cannot be
  truncated, while the other retains its native width and synthesis can fold
  the repeated sign/zero bits. This removed all multiplier width-mismatch lint
  findings in PE, requant, normalizer, O-rescale, and LSE paths.

### 8.2 Similar wide-multiply issues removed

The audit also found two operands that had been widened before multiplication,
causing hardware wider than the source formats required. Old-O rescale now uses
an exact signed 32x17 multiply, and serialized `old_l*alpha` uses an exact
unsigned 32x16 multiply. This avoids accidental 48x48 structures without
changing the online recurrence or cycle schedule.

### 8.3 Verification and remaining gates

The dedicated PE test includes signed INT8 extremes (`-128*-128`,
`127*-128`, `-128*127`) and signed V extremes with Q1.15 P. Compute, softmax,
and top regressions pass. The completion sideband and reset cleanup did not alter
the schedule before the timing-pipeline round described below.
Top-level `HEAD_DIM=128` elaboration also passes after the width changes.

Before release to FPGA implementation, run full RTL lint plus randomized signed
V, causal tails, loader stalls, reset/X-propagation, and `HEAD_DIM=128`. Before
ASIC conclusions, rerun TT/SS synthesis from one fixed source hash. The old
frequency sweep was started before these edits and is therefore a mixed-revision
artifact. SAIF collection is specified in `asic/docs/saif_power_plan.md` but is
deferred until the UVM system workloads exist. Fanout=19 is not restructured;
compare thresholds 16/24/32 using timing, transition, buffer, and congestion
reports first.

## 9. Round-4 Timing-Pipeline Implementation

### 9.1 Implemented changes

- A shared exact signed multiplier wrapper now has latency 2 and II=1. Stage 1
  computes signed high and zero-positive low partial products; stage 2 performs
  the shifted addition. This creates a real arithmetic register boundary for
  both ASIC mapping and FPGA DSP inference without changing fixed-point results.
- Every normalizer lane uses the wrapper for its reduced signed 48x16 output
  scale. The eight lanes still accept and retire one complete stripe per cycle.
- All 32 score-scale lanes use the same contract for signed 32x16 requantization.
  Scale latency is defined centrally as five cycles and PWL-exp latency as three
  cycles, so the probability column tag uses the derived eight-cycle total.
- Each stripe captures `{O_old, alpha, feature, zero, valid}` beside its O-bank.
  The following cycle performs signed 32x17 O rescale, while V payload and its
  feature tag receive the matching one-cycle delay before entering row skew.
  This cuts the former SRAM-Q-to-multiplier-to-array-register path.
- PE score accumulation no longer consumes `ws_pv`. Mutually exclusive QK and
  PV valid tokens select the operation; `ws_pv` remains stripe-local only for
  link direction and phase-controlled O-bank behavior.
- PWL-exp endpoint interpolation now exposes its real unsigned 16x8 operands,
  rather than two artificial 32-bit zero-extended operands.

### 9.2 Cost and measured schedule

The two wide pipelines and stripe seed boundary add startup latency but keep
II=1. The two-KV-tile top regression changes from 1334 to 1348 cycles, a
14-cycle increase (1.0%) for this short directed case; long prefill throughput
is still governed by one score column and one PV feature accepted per cycle.
The wrapper adds one partial-product register pair plus one result register per
instance. This is an intentional register-for-critical-path tradeoff; the next
TT/SS and VCK190 reports must confirm that the added register clock power is
smaller than the timing and routing benefit.

### 9.3 Verification and remaining gates

The active regression set is 24 tests, including a dedicated multiplier test
with back-to-back tokens, bubbles, random vectors, and signed extremes. Compute,
softmax, and two-KV top regressions pass, top completes in 1348 cycles, RTL lint
has no width mismatch, and `HEAD_DIM=128` elaboration passes.

This round does not claim hold closure. Re-run TT 1.9/1.7 ns with SRAM input
min-delay zero, then SS setup and FF/min-RC propagated-clock hold. If O rescale
still appears in the setup top paths, pipeline signed 32x17 itself with the same
wrapper contract. Hold failures ending at SRAM pins must be repaired in the
physical flow, not by adding RTL inverter chains or restoring artificial
`set_min_delay`.

## 10. Round-5 Local-Control and Arithmetic Boundaries

### 10.1 Implemented RTL

- Old-O rescale is now an explicit latency-2, II=1 signed 32x17 pipeline in
  each 8-row stripe. The SRAM result, alpha, feature, seed-zero, and valid are
  captured locally; V and its feature/valid metadata receive the same delay.
- QK clear is registered and replicated once per 8-column group inside each
  stripe. `ST_CLEAR` is followed by `ST_CLEAR_LOCAL`, so the global FSM only
  drives local clear registers and every PE observes two complete clear clocks
  before QK issue begins. Each copy is now a `fa_clear_replica` leaf instance.
  DC preserves its hierarchy and disables cross-boundary optimization, but does
  not apply `dont_touch` to the internal generic flop; the replica therefore
  remains physically independent and still maps to a real library cell.
- The generic requantizer was removed from the 32 score lanes. Dedicated
  `score_scale_pipe` fixes the score policy and exposes only data, mantissa,
  shift, and valid, while retaining latency 5 and II=1.
- PWL exp now registers `base_lo`, `base_lo-base_hi`, fraction, and bypass state
  immediately before its 16x8 multiplier. The following stage holds only the
  product; shift/subtract/saturation terminate at the output register. Total
  PWL latency remains 3 and score-plus-exp tag latency remains 8.
- Mixed signed/unsigned boundaries and multiplier result contexts were made
  explicit. VCS Verilog-2001 RTL lint reports no width or conversion warnings.

### 10.2 Measured schedule and acceptance

The two-KV directed top test completes in 1354 cycles, six more than Round 4:
two cycles are the extra local-clear setup, and four are the two-stage O-rescale
startup across two PV tiles. Both paths retain II=1, so long-feature steady-state
throughput is unchanged. The active regression set is 25/25 and includes burst
tests for the dedicated score scale and the newly split PWL exp.

`MAX_FANOUT=16` remains the default until the scripted 16/24/32 comparison is
run on this exact RTL hash. Adopt 24 only if setup WNS, transition violations,
buffer count, and physical congestion are not worse than the 16 result.

## 11. Round-6 LSE Row-State Streaming

### 11.1 Problem and decision

The former serialized update was arithmetically small but physically poor. A
runtime row index selected 32-bit entries from 1024-bit `old_l` and `sum_rows`
vectors and a 512-bit alpha vector. Those three 32:1 muxes directly fed a
32x16 multiply, shift, 48-bit add, overflow reduction, and saturation. The same
index then decoded a dynamic part-select write into the 1024-bit `l_rows`
register. This is a genuine setup, fanout, and placement risk and therefore was
changed rather than waived.

### 11.2 Implemented structure

- `old_l`, captured row sums, and an LSE-private alpha copy are shift streams.
  Their fixed low slices feed one unsigned 32x16 multiplier; the runtime row
  counter is carried only as pipeline metadata.
- The exact multiplier is latency 2 and II=1, split into two unsigned 16x16
  partial products followed by a registered shifted addition. Only valid bits
  are reset; qualified arithmetic payload registers stay off the reset tree.
- The delayed block sum is added after the multiplier. Overflow reduction and
  saturation terminate at the row-state register boundary.
- Each result shifts `l_rows` by one row and enters at a fixed high slice. After
  32 commits, packed row order is identical to the original implementation,
  without a dynamic wide write decoder.
- `alpha_rows` itself remains intact because overlapping WS-PV still consumes
  it. The private 512-bit alpha stream is the only full-vector storage cost;
  `old_l`, `sum_rows`, and `l_rows` are reused destructively.

The two-cycle multiplier startup is hidden under the already-overlapped WS-PV
phase. The two-KV top test therefore remains 1354 cycles; this change adds no
end-to-end cycle.

### 11.3 Related-index audit

Not every variable index is the same problem. Generate-loop part-selects are
compile-time constants, and variable addresses into Q/K/V/O SRAM arrays are
intentional memory ports. The remaining normalizer stripe select is a bounded
4:1 selection followed immediately by a register boundary. The output packer
was also in the same structural class even though it had no following
arithmetic: eight 256-bit row registers used a 32-way dynamic byte write and an
8-way dynamic row read. It now inserts ordered feature bytes at a fixed end and
destructively shifts completed rows through fixed lane zero during SRAM flush.
This removes both muxes without another 2 Kbit copy. Probability column
selection remains stripe-local and one-hot decoded as previously planned.

### 11.4 Verification and synthesis gate

The active regression set is 26 tests. A dedicated unsigned multiplier test
covers back-to-back traffic, bubbles, and the maximum product. The fused-array
test now uses distinct score distributions for four rows, so it detects row
permutation as well as arithmetic errors. The output-buffer test checks
fixed-port row ordering and a partial final group at `HEAD_DIM=50`. Full RTL
lint is clean. DC
analyze/elaborate/link completes with all 480 SRAM macros and no frontend
warning, error, or `VER-318`; the pre-optimization `check_design` report still
contains known structural `LINT-28/29/31/52` categories and is not being called
a clean mapped-netlist check. The next full synthesis must confirm that no
row-index mux appears before the LSE multiplier, that the two partial products
map at their intended widths, and that setup/area improve; functional
simulation alone cannot establish those physical results.

## 12. Round-7 Mapped-Control and Timing-Closure Corrections

### 12.1 Unmapped clear replicas

The previous clear replication intent was correct, but its implementation was
not: pre-compile `set_dont_touch` froze 16 generic clear flops as `**SEQGEN**`.
The flow correctly rejected the resulting mapped netlist. The four replicas in
each stripe are now separate `fa_clear_replica` leaves. `set_ungroup false` and
`set_boundary_optimization false` protect the four physical domains, while the
internal flop remains available for technology mapping. The synthesis wrapper
also scans every delivered mapped Verilog file for `**SEQGEN**` and `GTECH_`.

### 12.2 Block-max setup boundary

`SM_ALPHA_WAIT` already commits `m_pending_q` into `m_rows_q` before entering
`SM_M_START`. The reverse max wave nevertheless used `m_pending_q`, retaining a
62-level path from block/local-max selection through the PE delta subtractor.
The stripe input now uses `m_rows_q`. This consumes the existing state boundary,
adds no register and no cycle, and prevents block-max combinational logic from
being chained into all 1024 PE subtraction endpoints.

### 12.3 Hold policy

The TT ideal-clock run's worst hold path is a 0.046 ns register-to-O-SRAM input
path against 0.1401 ns required time, giving -0.0941 ns. Of 5602 reported paths,
5570 end on SRAM pins: 3840 D, 1454 A, 142 CEB, and 134 WEB. This is a physical
minimum-delay problem, not a reason to add functional RTL latency.

All synthesis runs now emit `timing_status.rpt`. Ordinary TT/SS setup runs retain
hold violations as diagnostics. Explicit `synth-system-hold` and FF/min-RC runs
must finish with zero setup and zero hold violating paths. Post-CTS PrimeTime
likewise checks both directions with propagated clocks and routed SPEF. The SRAM
input min-delay default remains zero; final repair belongs to legal delay cells
or buffer pairs inserted on the reported macro branches during place and route.
