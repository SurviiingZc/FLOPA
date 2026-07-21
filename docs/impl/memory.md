# Memory and Tile Cache Design

## 1. Scope

This document defines the implementation strategy for all on-chip storage and tile movement:

- `rtl/memory/pingpong_buffer.v`
- `rtl/memory/banked_sram.v`
- `rtl/memory/asic_sram_1024x16.v`
- `rtl/memory/asic_sram_256xwide.v`
- `rtl/memory/uram_bank.v`
- `rtl/memory/bram_buffer.v`
- `rtl/memory/qkv_tile_cache.v`
- `rtl/memory/stream_fifo.v`
- `rtl/memory/output_buffer.v`

## 2. Design Basis

FlashAttention-style accelerators are IO-aware. The common pattern is:

- tile the input;
- keep the currently used tiles on chip;
- avoid spilling score/probability matrices;
- overlap load and compute using ping-pong buffering;
- minimize on-chip port contention.

For this project, memory design should support the array and softmax pipeline rather than compete with them.

## 3. Global Memory Strategy

### 3.1 First-Version Principle

The first version should not depend on a single giant RAM block with irregular access.

Preferred strategy:

- Q/K/V staged in separate banked caches;
- short FIFOs for lane alignment;
- output buffered separately;
- banked SRAM for tile storage;
- explicit ping-pong around tile boundaries.

### 3.2 Why This Matters

SystolicAttention reports that softmax and array contention over SRAM/register files hurts throughput. The safest RTL response is to reduce contention through clean separation of buffers and by registering the handoff between stages.

## 4. Banked SRAM

### 4.1 Purpose

`banked_sram.v` is the generic storage building block for all tile caches.

### 4.2 Design Rules

- Parameterize bank count and width.
- Keep address decode simple.
- Register read and write addresses.
- Make read-during-write behavior explicit.
- Keep bank enable local and gated.
- Avoid deep combinational address math.

### 4.3 Recommended Bank Organization

For a 128-bit external data path, either of these is reasonable:

- 8 banks with wider lanes and simple alignment.
- 16 banks with narrower slices and higher internal parallelism.

Choose the bank scheme that gives the cleanest timing in synthesis, but keep the bank mapping deterministic.

### 4.4 Bank Mapping Rule

Use low-bit interleaving for lane-friendly access.

Example policy:

- bank = low-order slice of element index,
- row/column remainder selects the address within the bank.

This makes burst unpacking and reassembly predictable.

### 4.5 Timing Rule

The bank decoder and bank enable logic must be registered if the raw address fanout becomes large.

### 4.6 Technology Backends

The logical memory interface is common, but the physical implementation is selected at compile time:

- ASIC (`ATTN_ASIC`): use `/data/public/SRAM/uhdsp_256x8m4s`, a 256 x 8 single-port macro.
- FPGA: infer Xilinx UltraRAM for Q/K/V tile banks with `ram_style = "ultra"`.
- FPGA output storage: infer block RAM with `ram_style = "block"`.

Q/K/V cache depth follows `HEAD_DIM`. Configurations with at most 256 addresses
use the 256-depth width-composed macro directly; deeper configurations use
registered depth composition. The registered depth tag is aligned with macro
read data across slice boundaries. Persistent O is split by stripe row and
feature group into 32-bit-wide banks. Normalized output uses 256-bit row/group
words composed from the same 256x8 macro in ASIC builds.

All SRAM ports are single-port. A write has priority over a coincident read. The RTL must suppress read-valid for that collision rather than relying on an unspecified read-during-write value.

### 4.7 SRAM Power Rules

- Drive active-low `CEB` low only for a real read or write.
- On Q/K/V writes, enable only the selected logical byte banks; keep all unused macros in standby.
- Hold registered address and write-data signals while idle so macro inputs do not toggle unnecessarily.
- Do not issue SRAM reads while downstream backpressure is holding a valid word.
- Read the 256-bit normalized-output word once and serve its two 128-bit AXI beats from the held macro output.
- Keep `SLP` and `SD` deasserted in the first version; system-level retention sequencing is outside the accelerator block.

## 5. Ping-Pong Buffer

### 5.1 Purpose

Ping-pong buffers hide load latency by separating current-tile and next-tile storage.

### 5.2 Design Rules

- Switch banks only at tile boundaries.
- Do not switch banks mid-tile.
- Make the active bank bit explicit and observable.
- Keep load and compute consumers isolated through a narrow control signal.

### 5.3 Timing Rule

The bank switch decision must be registered. Do not feed a deep memory-ready condition directly into compute logic in the same cycle.

## 6. Q/K/V Tile Cache

### 6.1 Purpose

The tile cache stages the current and next Q/K/V tiles, not the full sequence.

### 6.2 Recommended Organization

- Q cache: about 64 KB.
- K cache: about 64 KB.
- V cache: about 64 KB.
- Use the same banked SRAM wrapper shape for all three.

### 6.3 Design Rules

- Keep Q, K, and V address generation separate.
- Keep cache load side and compute side decoupled.
- Use explicit valid bits for current and next tile.
- Align cache movement to the scheduler phase.
- Do not let the array directly consume AXI beats.
- Define `CACHE_LANES=CACHE_WORD_W/CACHE_ELEM_W` and reject physical array
  configurations that index beyond the cache word.

### 6.4 Why This Works

This organization maps the FlashAttention tiling idea cleanly onto hardware:

- Q is reused across many K/V tiles.
- K/V are streamed tile by tile.
- Nothing requires a full N x N score buffer.
- The cache is large enough to absorb timing and bandwidth variation but small enough to stay synthesizable.

For WS-PV, V uses a feature-major contract. Contiguous address `d` returns the
32 key values `V[0:31,d]`. FPGA software may transpose the 32xHEAD_DIM tile
before loading; an ASIC DMA path may use bounded 32x32 transpose stages.

### 6.5 Timing Rule

Cache load, unpack, and issue should be separated by at least one register stage.

## 7. Stream FIFO

### 7.1 Purpose

Short FIFOs are used for:

- lane alignment,
- bubble absorption,
- phase decoupling,
- small backpressure smoothing.

### 7.2 Design Rules

- Keep the FIFO shallow.
- Keep full and empty flags registered.
- Do not let the FIFO become a hidden large buffer.
- Use FIFOs to absorb short latency mismatches, not to redesign the architecture.

## 8. Output Buffer

### 8.1 Purpose

The output buffer collects the finished O tile and prepares it for AXI master writeback.

### 8.2 Design Rules

- Keep output aggregation separate from compute.
- Pack data into the AXI write width.
- Track partial tiles and tail conditions.
- Preserve ordering exactly.
- Provide a clean write-ready / write-done handshake.

### 8.3 Timing Rule

The output buffer should be a staging block with registered input and output boundaries.

### 8.4 Physical Organization

The output buffer receives eight normalized rows at one feature per cycle. It
packs 32 feature bytes locally for each row, then writes eight 256-bit
row/group words sequentially:

- no accumulator SRAM exists in `output_buffer`;
- normalized output depth is `ROWS*ceil(HEAD_DIM/32)` words;
- AXI stream uses the lower and upper 128-bit beats of each held 256-bit word.

Feature order is an explicit ascending contract. Every valid feature shifts the
eight row packers by one byte and inserts new data at a fixed high end; a
parameter-constant alignment shift handles a partial final group. During flush,
the completed row words shift destructively toward lane zero, which is the only
SRAM write-data port. Thus neither the feature ID nor the flush-row counter
selects data from a 256-bit packed register at runtime.

The stream reader caches the current 256-bit SRAM word. Backpressure never causes another macro access, and moving from the lower to upper AXI beat does not toggle `CEB`.

The widest compute-to-normalizer transfer is one stripe: eight 32-bit O values
and eight 32-bit `l` values. It is fixed-locality data, not an array-state bus.

### 8.5 Persistent O-Bank Contract

Each stripe row owns address-indexed 32-bit O banks split into
`ceil(HEAD_DIM/ARRAY_COLS)` feature groups. WS-PV reads the old feature and
writes the tagged returning feature. ASIC groups are independent single-port
macros; RTL assertions reject same-group read/write collisions. FPGA builds
infer block RAM. The structure removes whole-row shifts and scales to 64 or 128
features by changing bank count, not datapath width.

## 9. Memory/Compute Interface

The memory subsystem should feed the compute subsystem through narrow, registered handoff points:

- cache issue -> compute start,
- compute done -> cache drain,
- softmax beta ready -> PV issue,
- output ready -> writeback start.

This prevents the memory system from creating a long critical path through the whole accelerator.

## 10. First-Version Strategy

For a first version that is easier to close:

1. Use separate Q, K, and V tile caches.
2. Use explicit ping-pong bits.
3. Use shallow FIFOs for staging only.
4. Keep output buffering separate from tile caching.
5. Register every cache boundary.
6. Avoid direct compute-to-AXI coupling.

## 11. Verification Hooks

- Each banked SRAM configuration must have a module TB.
- Ping-pong switching must be deterministic.
- Cache and FIFO behavior must be checked with boundary cases.
- Output packing must be checked against the AXI write width.

## 12. References

- FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness.
- FlashAttention-2: Faster Attention with Better Parallelism and Work Partitioning.
- SystolicAttention: Fusing FlashAttention within a Single Systolic Array.
