# Register File Design

## 1. Scope

This document defines the software-visible control and status registers.

Relevant RTL file:

- `rtl/control/accel_regfile.v`

## 2. Register Model

- 32-bit AXI-Lite register interface.
- All registers are 32-bit unless stated otherwise.
- 64-bit addresses or base pointers are split into low/high words.
- Writes take effect through shadow registers where needed.
- Start is edge-triggered or write-1-to-start.
- Status bits are read-only unless explicitly marked W1C.

## 3. Register Map

| Offset | Name | Access | Description |
| --- | --- | --- | --- |
| 0x00 | CONTROL | RW | Start, soft reset, clear done, mode control |
| 0x04 | STATUS | RO | busy, done, error, idle, active phase |
| 0x08 | ERROR_CODE | RO | sticky error code |
| 0x0C | VERSION | RO | RTL version / build ID |
| 0x10 | Q_BASE_LO | RW | Q base address low word |
| 0x14 | Q_BASE_HI | RW | Q base address high word |
| 0x18 | K_BASE_LO | RW | K base address low word |
| 0x1C | K_BASE_HI | RW | K base address high word |
| 0x20 | V_BASE_LO | RW | V base address low word |
| 0x24 | V_BASE_HI | RW | V base address high word |
| 0x28 | O_BASE_LO | RW | Output base address low word |
| 0x2C | O_BASE_HI | RW | Output base address high word |
| 0x30 | Q_STRIDE | RW | Q row stride in bytes |
| 0x34 | K_STRIDE | RW | K row stride in bytes |
| 0x38 | V_STRIDE | RW | V row stride in bytes |
| 0x3C | O_STRIDE | RW | Output row stride in bytes |
| 0x40 | SEQ_Q | RW | query sequence length |
| 0x44 | SEQ_KV | RW | key/value sequence length |
| 0x48 | NUM_Q_HEADS | RW | number of query heads |
| 0x4C | NUM_KV_HEADS | RW | number of key/value heads |
| 0x50 | HEAD_DIM | RW | head dimension |
| 0x54 | TILE_Q | RW | query tile size |
| 0x58 | TILE_K | RW | key/value tile size |
| 0x5C | MODE | RW | MHA/GQA, prefill/decode, causal flags |
| 0x60 | SCORE_SCALE | RW | score scale mantissa or encoded value |
| 0x64 | VALUE_SCALE | RW | value scale mantissa or encoded value |
| 0x68 | OUT_SCALE | RW | output scale mantissa or encoded value |
| 0x6C | MASK_CFG | RW | causal mask enable and policy bits |
| 0x70 | PERF_CTRL | RW | performance counter control |
| 0x74 | PERF_CYCLES_LO | RO | cycle counter low word |
| 0x78 | PERF_CYCLES_HI | RO | cycle counter high word |
| 0x7C | PERF_STALL_LO | RO | stall counter low word |
| 0x80 | PERF_STALL_HI | RO | stall counter high word |
| 0x84 | PERF_MAC_LO | RO | MAC counter low word |
| 0x88 | PERF_MAC_HI | RO | MAC counter high word |
| 0x8C | PERF_TILES | RO | tile count |

## 4. Bit Fields

### 4.1 CONTROL

| Bit | Name | Meaning |
| --- | --- | --- |
| 0 | start | write 1 to launch the accelerator |
| 1 | soft_reset | write 1 to clear control state |
| 2 | clear_done | write 1 to clear done status |
| 3 | clear_error | write 1 to clear sticky error |
| 4 | mode_sel | 0 = MHA, 1 = GQA |
| 5 | causal_en | enable causal mask |
| 6 | prefill_en | prefill mode select |
| 7 | decode_en | decode mode select |

### 4.2 STATUS

| Bit | Name | Meaning |
| --- | --- | --- |
| 0 | busy | accelerator active |
| 1 | done | operation finished |
| 2 | error | sticky error present |
| 3 | idle | scheduler in IDLE |
| 4 | load_active | load phase active |
| 5 | compute_active | compute phase active |
| 6 | writeback_active | writeback phase active |

## 5. Software Contract

### 5.1 Start Sequence

1. Write base addresses.
2. Write strides.
3. Write dimensions.
4. Write scales and mode.
5. Clear stale done/error bits.
6. Write `CONTROL.start = 1`.
7. Poll `STATUS.busy` and `STATUS.done`.
8. Read back `ERROR_CODE` if `STATUS.error = 1`.

### 5.2 Illegal Config Policy

The register file must reject or flag:

- `HEAD_DIM = 0`.
- `SEQ_Q = 0` or `SEQ_KV = 0`.
- `NUM_Q_HEADS = 0`.
- `NUM_KV_HEADS = 0`.
- unsupported `HEAD_DIM` values.
- invalid mode combinations.
- misaligned addresses if alignment is required.

### 5.3 Shadow Register Rule

Parameters that affect an entire run must be latched into shadow registers when `start` is accepted. Later writes during a busy run must either be ignored or cause an error, but they must not silently change the in-flight operation.

## 6. Implementation Notes

- Decode is explicit.
- Readback must be stable.
- Clear-on-read should be avoided for control/status unless documented.
- Performance counters should be reset by soft reset or dedicated clear bits.
- All register fields must have reset values.
