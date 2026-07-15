# Common Definitions

## 1. Scope

This document covers shared Verilog headers and numeric policy.

Relevant RTL files:

- `rtl/common/attention_defines.vh`
- `rtl/common/fixed_defs.vh`

## 2. Design Rules

- Put all shared constants in Verilog headers.
- Use the same header files in RTL and TB.
- Avoid duplicated magic numbers.
- Freeze widths before coding module internals.

## 3. Shared Parameter Set

Recommended shared parameters:

| Name | Meaning |
| --- | --- |
| `DATA_W` | input data width, INT8 default |
| `ACC_W` | internal accumulation width |
| `SCORE_W` | score / beta width |
| `HEAD_DIM` | default 64 |
| `NUM_Q_HEADS` | default 9 |
| `NUM_KV_HEADS` | default 9 |
| `TILE_Q` | query tile size, default 32 |
| `TILE_K` | key/value tile size, default 32 |
| `NUM_BANKS` | SRAM bank count, default 8 or 16 |
| `AXI_DATA_W` | 128 |
| `AXI_ADDR_W` | address width |

## 4. Shared Encodings

Define these in the header file:

- FSM states.
- Module modes.
- Error codes.
- Register offsets.
- Interrupt or done bits.
- Saturation / rounding modes.

## 5. Numeric Policy

- Q/K/V input: signed INT8.
- QK accumulation: signed INT32.
- Softmax state: fixed-point or BF16-like representation.
- Final output: INT8 or INT16 depending on configuration.

## 6. Header Policy

- Keep headers synthesis-safe.
- Use `localparam`-style constants in the header only if they are truly shared.
- Do not put behavioral code in shared headers.
- Keep the header syntax compatible with both Verilog and SV include usage.
