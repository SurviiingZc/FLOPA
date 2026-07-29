# UVM coverage waivers

The regression always emits both an unmodified `urg/` report and a separate
`urg_waived/` signoff view. Waivers never alter the raw report.

| ID | Scope | Rationale | Independent check |
| --- | --- | --- | --- |
| W-HIER-001 | `DW02_mult`, `uhdsp_256x8m4s` | Third-party DesignWare and characterized SRAM internals are outside RTL verification ownership. Wrapper interfaces remain included. | Arithmetic end-to-end scoreboards and ASIC SRAM module TB. |
| W-RTL-001 | Fixed-parameter `$fatal` guards | The production build fixes array lanes, INT8 width and stripe divisibility; violating them requires a different elaboration. | Compile-time configuration review and parameterized module TBs. |
| W-RTL-002 | Scheduler invalid/busy START combinations | `accel_regfile.start_cfg_valid_w` and busy write rejection prevent these combinations from reaching the top-level scheduler instance. Only the unreachable vectors are excluded. | `tb_accel_scheduler` directly tests scheduler guards; UVM tests AXI rejection. |
| W-RTL-003 | FSM `default` recovery | Reaching these branches requires state-bit corruption, which pin-level simulation cannot inject. | RTL lint and formal state-reachability review. |
| W-RTL-004 | `PV_FLOW_WAIT_L` | With fixed `HEAD_DIM=64`, multiplier latency and 32-row l-update latency, l-update always completes before PV drain. The opposite ordering requires a different parameterization. | `tb_fsa_fused_array` and all end-to-end KV sizes check the implemented ordering. |
| W-MATH-001 | PWL post-interpolation clamps | Ordered positive LUT endpoints and an 8-bit interpolation fraction mathematically keep the non-bypass result in `[11,32767]`. | PWL segment functional coverage and `tb_pwl_exp_unit`. |

Any RTL change that invalidates a checksum makes URG reject the stale exclusion;
the waiver must then be re-reviewed against the new source and VDB.

## Current sign-off result

The 2026-07-29 ASIC-SRAM regression contains 21 passing tests. The unmodified
report is 95.66% aggregate code coverage (94.95 line, 94.10 condition, 92.16
toggle, 92.89 branch, 99.88 assertion) with 100% functional coverage. Applying
only the reviewed hierarchy and expression exclusions produces 96.00% DUT
coverage (95.53 line, 94.48 condition, 92.65 toggle, 93.35 branch, 100 assertion)
and leaves all five functional covergroups at 100%.

## Structural valid invariants

The former `fsa_stripe` WS-PV valid-correlation candidate is resolved in RTL,
not waived. O-seed and V have the same `row+column+1` delay, so one canonical
valid drives each PE and per-PE SVA checks phase/seed/V alignment. The same
canonical-valid pattern is used only for replicated lanes or metadata pipelines
that share an issue token and fixed latency. Independent protocol events remain
separate conditions.

## Open formal candidates (not excluded)

- `online_normalizer` arithmetic clamp combinations: derive signed bounds from
  the fixed accumulator, reciprocal, and requantization widths before deleting
  logic or excluding bins. Replicated-lane valid correlation has already been
  removed from the synthesized condition cone and is checked by SVA.
- `accel_regfile.start_cfg_valid_w` zero-Q-head and zero-KV-head MC/DC rows:
  each zero also makes the head-equality term false, so the terms cannot be
  independently isolated. Keep them raw until the expression-level proof and
  checksum-bound exclusion are reviewed.
- controller/engine defensive error arcs: module tests cover the implemented
  recovery, while legal top-level handshakes block several fault combinations.
  Do not exclude them without a reachability proof or an internal fault test.

This candidate remains in both reported scores. A low condition percentage is
not itself sufficient evidence for a waiver.
