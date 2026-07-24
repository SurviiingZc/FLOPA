# Register and Interface Reference

This document is the software and integration reference for
`rtl/attention_accel_top.v`. The RTL definitions in
`rtl/common/attention_defines.vh` and `rtl/control/accel_regfile.v` are the
source of truth. All control addresses below are byte offsets from the
AXI4-Lite control BAR.

## 1. AXI4-Lite Register Map

All registers are 32 bits wide and word aligned. `RW` fields support byte
strobes; narrow fields use only the least-significant byte or half-word.
`W1P` means that writing one generates a one-cycle command pulse. Reserved
bits read as zero and should be written as zero.

| Offset | Register | Access | Reset | Implemented behavior |
| ---: | --- | :---: | ---: | --- |
| `0x000` | `CONTROL` | mixed | `0x0000_0040` | command pulses in `[3:0]`; mode shadow in `[7:4]` |
| `0x004` | `STATUS` | RO | `0x0000_0008` | live scheduler and phase status |
| `0x008` | `ERROR_CODE` | RO | `0x0000_0000` | sticky four-bit error code |
| `0x00C` | `VERSION` | RO | `0x0002_0000` | RTL programming-model version 2.0 |
| `0x010` | `Q_BASE_LO` | RW | `0x0000_0000` | Q byte address `[31:0]`; reserved for input DMA integration |
| `0x014` | `Q_BASE_HI` | RW | `0x0000_0000` | Q byte address `[63:32]`; reserved for input DMA integration |
| `0x018` | `K_BASE_LO` | RW | `0x0000_0000` | K byte address `[31:0]`; reserved for input DMA integration |
| `0x01C` | `K_BASE_HI` | RW | `0x0000_0000` | K byte address `[63:32]`; reserved for input DMA integration |
| `0x020` | `V_BASE_LO` | RW | `0x0000_0000` | V byte address `[31:0]`; reserved for input DMA integration |
| `0x024` | `V_BASE_HI` | RW | `0x0000_0000` | V byte address `[63:32]`; reserved for input DMA integration |
| `0x028` | `O_BASE_LO` | RW | `0x0000_0000` | output byte address `[31:0]`; consumed by AXI4 writeback |
| `0x02C` | `O_BASE_HI` | RW | `0x0000_0000` | output byte address `[63:32]`; stored, but current write master uses only the low 32 bits |
| `0x030` | `Q_STRIDE` | RW | `0x0000_0000` | Q row stride in bytes; reserved for input DMA integration |
| `0x034` | `K_STRIDE` | RW | `0x0000_0000` | K row stride in bytes; reserved for input DMA integration |
| `0x038` | `V_STRIDE` | RW | `0x0000_0000` | V row stride in bytes; reserved for input DMA integration |
| `0x03C` | `O_STRIDE` | RW | `0x0000_0000` | output row stride in bytes; active in Q-tile/head address progression |
| `0x040` | `SEQ_Q` | RW | `0x0000_0000` | query sequence length in `[15:0]` |
| `0x044` | `SEQ_KV` | RW | `0x0000_0000` | key/value sequence length in `[15:0]` |
| `0x048` | `NUM_Q_HEADS` | RW | `0x0000_0009` | number of query heads in `[7:0]` |
| `0x04C` | `NUM_KV_HEADS` | RW | `0x0000_0009` | number of KV heads in `[7:0]` |
| `0x050` | `HEAD_DIM` | RW | `0x0000_0040` | runtime head dimension in `[7:0]`; must equal elaborated `HEAD_DIM=64` |
| `0x054` | `TILE_Q` | RW | `0x0000_0020` | query tile size in `[7:0]`; must be 32 |
| `0x058` | `TILE_K` | RW | `0x0000_0020` | key tile size in `[7:0]`; must be 32 |
| `0x05C` | `MODE` | RW | `0x0000_0004` | persistent copy of mode fields; see Section 2.3 |
| `0x060` | `SCORE_SCALE` | RW | `0x0000_0000` | signed mantissa and right shift before PWL exp |
| `0x064` | `VALUE_SCALE` | RW | `0x0000_0000` | retained in the snapshot but not consumed by the current datapath |
| `0x068` | `OUT_SCALE` | RW | `0x0000_0000` | signed mantissa and right shift for final INT8 requantization |
| `0x06C` | `MASK_CFG` | RW | `0x0000_0000` | retained/readable; current masking uses sequence, tile-base, and causal mode instead |
| `0x070` | `PERF_CTRL` | RW | `0x0000_0000` | bit 0 is a level-sensitive counter clear |
| `0x074` | `PERF_CYCLES_LO` | RO | `0x0000_0000` | busy-cycle counter `[31:0]` |
| `0x078` | `PERF_CYCLES_HI` | RO | `0x0000_0000` | busy-cycle counter `[63:32]` |
| `0x07C` | `PERF_STALL_LO` | RO | `0x0000_0000` | load/writeback stall counter `[31:0]` |
| `0x080` | `PERF_STALL_HI` | RO | `0x0000_0000` | load/writeback stall counter `[63:32]` |
| `0x084` | `PERF_MAC_LO` | RO | `0x0000_0000` | issued MAC count `[31:0]` |
| `0x088` | `PERF_MAC_HI` | RO | `0x0000_0000` | issued MAC count `[63:32]` |
| `0x08C` | `PERF_TILES` | RO | `0x0000_0000` | completed KV-tile count `[31:0]` |

## 2. Register Bit Fields

### 2.1 `CONTROL` (`0x000`)

| Bits | Name | Access | Reset | Description |
| ---: | --- | :---: | ---: | --- |
| `0` | `START` | W1P | 0 | Validate the shadow configuration and atomically copy it to the active snapshot. A rejected start returns `SLVERR` and records an error code. |
| `1` | `SOFT_RESET` | W1P | 0 | Return the scheduler/cache pipeline to idle and clear sticky error/counters. |
| `2` | `CLEAR_DONE` | W1P | 0 | Clear the scheduler's sticky done state. |
| `3` | `CLEAR_ERROR` | W1P | 0 | Clear scheduler and register-file sticky errors. |
| `4` | `MODE_SEL` | RW | 0 | 0: MHA; 1: GQA. GQA is currently rejected at START. |
| `5` | `CAUSAL_EN` | RW | 0 | Enable causal masking. |
| `6` | `PREFILL_EN` | RW | 1 | Select MHA prefill when set with `DECODE_EN=0`. |
| `7` | `DECODE_EN` | RW | 0 | Select single-query MHA decode when set with `PREFILL_EN=0`. |
| `31:8` | reserved | RO | 0 | Read zero; write zero. |

Only byte lane 0 (`WSTRB[0]`) affects `CONTROL`. A `CONTROL` write always
replaces bits `[7:4]`, including a command-only write. Therefore software must
include the intended mode bits in every command value:

| Operation | Prefill value | Decode value |
| --- | ---: | ---: |
| start | `0x0000_0041` | `0x0000_0081` |
| soft reset | `0x0000_0042` | `0x0000_0082` |
| clear done | `0x0000_0044` | `0x0000_0084` |
| clear error | `0x0000_0048` | `0x0000_0088` |

Writing only `0x1` after programming `MODE` does **not** preserve the earlier
mode selection: it writes `PREFILL_EN=0` and `DECODE_EN=0`, so START is rejected.

### 2.2 `STATUS` (`0x004`)

| Bits | Name | Description |
| ---: | --- | --- |
| `0` | `BUSY` | scheduler is executing a job |
| `1` | `DONE` | sticky completion indication; clear with `CONTROL.CLEAR_DONE` |
| `2` | `ERROR` | scheduler, datapath, bus, or sticky register-file error is present |
| `3` | `IDLE` | scheduler is in IDLE or DONE |
| `4` | `LOAD_ACTIVE` | scheduler is waiting for Q or KV cache ownership |
| `5` | `COMPUTE_ACTIVE` | QK, online-softmax, or WS-PV is active |
| `6` | `WRITEBACK_ACTIVE` | final normalization/writeback phase is active |
| `31:7` | reserved | read zero |

### 2.3 `MODE` (`0x05C`)

| Bits | Name | Description |
| ---: | --- | --- |
| `0` | `MODE_SEL` | 0: MHA; 1: GQA (currently rejected) |
| `1` | `CAUSAL_EN` | enable causal attention mask |
| `2` | `PREFILL_EN` | enable tiled prefill |
| `3` | `DECODE_EN` | enable single-query decode |
| `31:4` | reserved | read zero |

`MODE` and `CONTROL[7:4]` access the same four shadow bits. `MODE` is useful
for readback, but the intended values must still be present in the command
write to `CONTROL` as described above.

### 2.4 Scale Registers

`SCORE_SCALE` and `OUT_SCALE` use the same packed representation:

| Bits | Field | Description |
| ---: | --- | --- |
| `15:0` | `MANTISSA` | signed two's-complement 16-bit multiplier |
| `21:16` | `SHIFT` | unsigned arithmetic right-shift count, 0 to 63 |
| `31:22` | reserved | write zero |

The score path computes a rounded and saturated signed-16 value equivalent to
`(score_delta * MANTISSA) >>> SHIFT` before the PWL exp unit. The output path
applies the same packed scale to the normalized O value before signed INT8
rounding and saturation.

### 2.5 `PERF_CTRL` and Counters

`PERF_CTRL[0]` is level-sensitive, not a self-clearing command. Write one and
then zero to clear the counters and resume counting. Cycles count scheduler
`BUSY` clocks. Stall cycles count a busy load without both active cache owners,
or writeback backpressure. Each valid QK/PV issue adds 1024 MACs at the default
32x32 geometry. `PERF_TILES` increments when a KV tile completes PV and its
overlapped row-state update.

The 64-bit counters are exposed as independent live halves; there is no latch-on-
read mechanism. For a coherent software sample, read high, low, and high again,
and retry if the two high values differ.

## 3. Error Codes and AXI4-Lite Behavior

| Code | Name | Meaning |
| ---: | --- | --- |
| `0x0` | `NONE` | no sticky error |
| `0x1` | `BAD_CFG` | illegal mode/shape, write to protected configuration while busy, or START while busy |
| `0x2` | `BUS` | unknown address or write to a read-only address |
| `0x3` | `PROTOCOL` | reserved protocol classification |
| `0x4` | `ALIGNMENT` | one or more Q/K/V/O base addresses are not 16-byte aligned |
| `0x5` | `OVERFLOW` | reserved arithmetic-overflow classification |
| `0xF` | `FATAL` | cache/array/AXI write fatal error, or an unclassified hardware error |

AW and W may arrive independently and are joined by one-entry holding
registers. Only one unaccepted B response and one unaccepted R response are
allowed. Unknown reads, unknown writes, and writes to RO registers return
AXI `SLVERR` (`2'b10`). While `STATUS.BUSY=1`, only `CONTROL` and `PERF_CTRL`
are writable; other writes return `SLVERR` and record `BAD_CFG`. A successful
START snapshots all shadow registers, so later shadow writes cannot alter the
running job.

START is accepted only when all of the following are true:

- `SEQ_Q`, `SEQ_KV`, `NUM_Q_HEADS`, and `NUM_KV_HEADS` are nonzero;
- `HEAD_DIM=64`, `TILE_Q=32`, and `TILE_K=32` for the default elaboration;
- MHA is selected and `NUM_Q_HEADS == NUM_KV_HEADS`;
- Q/K/V/O base addresses are all 16-byte aligned;
- exactly one of prefill and decode is selected;
- decode additionally requires `SEQ_Q=1`.

## 4. Top-Level Interfaces

### 4.1 Clock, Reset, Interrupt, and Debug

| Signal | Dir. | Width | Contract |
| --- | :---: | ---: | --- |
| `clk` | in | 1 | single RTL clock; FPGA clock enables and ASIC ICG wrappers preserve one logical clock domain |
| `rst_n` | in | 1 | active-low asynchronous reset for control/valid state |
| `irq_o` | out | 1 | level interrupt, asserted while scheduler DONE or ERROR is set |
| `debug_state_o` | out | 4 | current scheduler state encoding shown below |

| Value | Scheduler state |
| ---: | --- |
| `0` | IDLE |
| `1` | LOAD_Q |
| `2` | LOAD_KV |
| `3` | QK |
| `4` | SOFTMAX |
| `5` | PV |
| `6` | WRITEBACK |
| `7` | DONE |
| `8` | ERROR |

### 4.2 AXI4-Lite Slave

| Channel | Signals | Width / behavior |
| --- | --- | --- |
| AW | `s_axi_awaddr`, `s_axi_awvalid`, `s_axi_awready` | 32-bit byte address; low 12 bits select the register |
| W | `s_axi_wdata`, `s_axi_wstrb`, `s_axi_wvalid`, `s_axi_wready` | 32-bit data and four byte enables |
| B | `s_axi_bresp`, `s_axi_bvalid`, `s_axi_bready` | `OKAY` or `SLVERR`; one outstanding response |
| AR | `s_axi_araddr`, `s_axi_arvalid`, `s_axi_arready` | 32-bit byte address; one-entry request holding register |
| R | `s_axi_rdata`, `s_axi_rresp`, `s_axi_rvalid`, `s_axi_rready` | 32-bit data; `OKAY` or `SLVERR` |

### 4.3 Q/K/V Tile Loader

The loader is the bulk input interface. It is not an AXI4 read master. An FPGA
design must place an AXI DMA MM2S or custom adapter in front of these ports.

| Signal | Dir. | Width | Contract |
| --- | :---: | ---: | --- |
| `tile_load_kind_i` | in | 2 | `0`: Q, `1`: K, `2`: V; `3` is reserved |
| `tile_load_bank_i` | in | 1 | destination ping-pong bank, 0 or 1 |
| `tile_load_addr_i` | in | `CACHE_ADDR_W` | feature address; 0 to 63 for `HEAD_DIM=64` |
| `tile_load_half_i` | in | 1 | 0: cache word `[127:0]`/lanes 0-15; 1: `[255:128]`/lanes 16-31 |
| `tile_load_data_i` | in | 128 | sixteen packed signed INT8 elements |
| `tile_load_valid_i` | in | 1 | transfer is accepted when valid and ready are both high |
| `tile_load_ready_o` | out | 1 | currently always one; adapter should still obey the handshake |
| `tile_commit_kind_i` | in | 2 | tensor whose fully loaded bank is committed: Q, K, or V |
| `tile_commit_bank_i` | in | 1 | committed bank ID |
| `tile_commit_valid_i` | in | 1 | one-cycle commit pulse after all words for that tensor bank are loaded |

Half 0 must precede half 1 for each `(kind, bank, address)`. Half 1 must match
the pending metadata exactly; otherwise the cache asserts a protocol error.
Commit each bank only once before it is consumed. K and V for a KV tile must be
committed separately to the same bank. Loading the inactive bank can overlap
compute on the active bank.

### 4.4 AXI4 Write Master

The output interface implements write address, write data, and write response
channels only. It permits one outstanding burst, limits bursts to 16 beats,
and splits bursts at 4-KiB boundaries.

| Channel | Signals | Width / behavior |
| --- | --- | --- |
| AW | `m_axi_awaddr` | 32-bit byte address derived from `O_BASE_LO` and `O_STRIDE` |
| AW | `m_axi_awlen` | beats minus one |
| AW | `m_axi_awsize` | fixed `3'b100`: 16 bytes per beat |
| AW | `m_axi_awburst` | fixed `2'b01`: INCR |
| AW | `m_axi_awvalid`, `m_axi_awready` | standard valid/ready handshake |
| W | `m_axi_wdata` | 128-bit normalized output payload |
| W | `m_axi_wstrb` | fixed `16'hFFFF`; only full beats are emitted |
| W | `m_axi_wlast` | asserted on the final beat of each burst |
| W | `m_axi_wvalid`, `m_axi_wready` | source advances only on a handshake |
| B | `m_axi_bresp`, `m_axi_bvalid`, `m_axi_bready` | non-OKAY response raises a fatal write error |

For prefill, one output row contains `HEAD_DIM` signed INT8 bytes. After a
32-row Q tile, the address advances by `32 * O_STRIDE`; after the final Q tile
of a head, it advances by `SEQ_Q * O_STRIDE`. Decode writes one 64-byte row.
The current master ignores `O_BASE_HI`, so the accessible writeback address
space is below 4 GiB.

## 5. Minimal Programming Sequence

1. Wait for `STATUS.BUSY=0`.
2. Program aligned tensor bases, byte strides, sequence lengths, head counts,
   `HEAD_DIM=64`, `TILE_Q=32`, `TILE_K=32`, and both active scale registers.
3. Clear counters by writing `PERF_CTRL=1`, then `PERF_CTRL=0`.
4. Start prefill with `CONTROL=0x41`, or decode with `CONTROL=0x81`.
5. Supply and commit Q/K/V ping-pong tiles through the tile-loader interface;
   the scheduler waits in LOAD_Q/LOAD_KV until ownership is valid.
6. Poll `STATUS`, or wait for `irq_o`. On ERROR, read `ERROR_CODE`. On DONE,
   read the performance counters and clear DONE with the matching mode value.

Configuration registers are shadowed. A successful START is the transaction
boundary at which every field becomes immutable for the running job.
