# Scheduler Design

## 1. Scope

This document defines the top-level FSM and tile-level control flow.

Relevant RTL file:

- `rtl/control/accel_scheduler.v`

## 2. Scheduler Role

The scheduler does not compute math. It coordinates when each block is active and when tile boundaries are crossed.

## 3. State Machine

Recommended states:

| State | Purpose |
| --- | --- |
| IDLE | wait for start |
| LOAD_Q | fetch query tile |
| LOAD_KV | fetch key/value tile |
| QK | run QK compute |
| SOFTMAX | run mask / max / exp / sum / LSE |
| PV | run PV compute |
| WRITEBACK | write output tile |
| DONE | signal completion |
| ERROR | signal failure and hold until cleared |

## 4. State Transitions

| Current | Condition | Next |
| --- | --- | --- |
| IDLE | start accepted | LOAD_Q |
| LOAD_Q | Q tile ready | LOAD_KV |
| LOAD_KV | K/V tile ready | QK |
| QK | score tile done | SOFTMAX |
| SOFTMAX | beta tile ready | PV |
| PV | output tile done | WRITEBACK |
| WRITEBACK | writeback complete | next tile or DONE |
| any | fatal error | ERROR |

## 5. Tile Flow

The scheduler should treat a tile as the unit of mode switching.

Preferred high-level loop:

1. Load Q tile.
2. Initialize row state.
3. Iterate over K/V tiles.
4. Run QK.
5. Run softmax update.
6. Run PV.
7. Continue until all K/V tiles are consumed.
8. Run final normalization.
9. Write back O tile.

## 6. Control Signals

The scheduler should drive or consume these abstract signals:

- `start_accept`
- `busy`
- `done`
- `error`
- `q_tile_done`
- `kv_tile_done`
- `qk_done`
- `softmax_done`
- `pv_done`
- `wb_done`
- `tile_last`
- `run_last`

## 7. Design Rules

- All state transitions must be explicit.
- Do not mix arithmetic with state control.
- State changes should happen only on clock edges.
- Tile boundary transitions must be clean and observable.
- Error handling must be sticky until cleared.

## 8. Integration Notes

The scheduler is the single source of truth for phase control.

Compute blocks, memory blocks, and writeback must obey scheduler handshakes.
