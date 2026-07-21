# SAIF Power Characterization Plan

## 1. Scope and timing

This plan defines the ASIC activity-based power flow for the fixed 32x32
prefill RTL. Script implementation and final measurements are intentionally
deferred until the UVM system test can reproduce complete loader, compute,
normalization, and AXI-write traffic. Vectorless power remains useful only for
structural comparison.

Power must be measured from one frozen RTL/netlist hash, one documented PVT
corner, and one documented clock period. Never compare SAIF files generated
from different hierarchy or source revisions without remapping coverage.

## 2. Required workload profiles

| Profile | Sampling window | Purpose |
| --- | --- | --- |
| `idle` | reset released, configured clock running, no job active | leakage plus residual clock/control activity |
| `re10k_prefill` | representative 8192-token, 9-head, D=64 attention tiles after warm-up | long-sequence vision-attention activity |
| `llm_prefill` | SmolLM2-135M representative prefill after warm-up | LLM QK/softmax/PV and DMA balance |

Exclude reset, one-time register programming, FSDB startup, and UVM build time
from the active sampling window. Include ping-pong loading, all compute phases,
final normalization, output-buffer traffic, AXI backpressure, and realistic
inter-tile gaps. Record cycle range, sequence length, head count, tile count,
stall injection, random seed, and model tensor checksum beside every SAIF.

## 3. Simulation capture contract

The UVM top shall call `$set_toggle_region` for the DUT, then
`$toggle_start`/`$toggle_stop` exactly at workload markers and write one SAIF
per profile. The canonical output layout is:

```text
asic/power/saif/<rtl_hash>/<profile>.saif
asic/power/saif/<rtl_hash>/<profile>.json
```

The JSON sidecar records simulator version, source hash, clock period, seed,
start/end cycles, configuration registers, tile counts, loader stalls, and
pass/fail status. A failing or truncated simulation must not publish SAIF.

## 4. Synthesis and power readback

Use the mapped netlist generated from the same RTL hash. The expected command
sequence is conceptually:

```tcl
read_saif -input <profile>.saif \
  -strip_path tb_attention_accel_top/dut \
  -instance attention_accel_top
report_saif -hierarchy > reports/<profile>/saif_coverage.rpt
report_clock_gating -multi_stage -verbose \
  > reports/<profile>/clock_gating.rpt
report_power -hierarchy -levels 4 \
  > reports/<profile>/power_hierarchy.rpt
report_power > reports/<profile>/power_summary.rpt
```

The final path and option spelling must follow the installed PrimeTime-PX or
Design Compiler power tool version. Report annotation coverage separately for
nets, sequential cells, combinational cells, SRAM pins, and generated/gated
clocks. SRAM internal power requires compatible macro power models; black-box
outputs must be called out rather than treated as zero activity.

## 5. Required reports

For each profile publish:

- total internal, switching, leakage, and clock-network power;
- power by `control`, `compute`, `softmax/normalizer`, `memory`, `AXI`, and
  output-buffer hierarchy;
- every ICG instance, its enable duty cycle, clock activity, fanout, and gated
  versus ungated time;
- SRAM read/write enable duty cycles by Q, K, V, O, and output bank;
- phase cycle share for load, QK, softmax, WS-PV, normalization, writeback,
  stall, and idle;
- SAIF coverage and every unannotated high-power hierarchy.

Normalize active profiles as both mW at the characterized frequency and energy
per attention tile/token. Idle power must not be subtracted silently; report
gross power and incremental active power separately.

## 6. Acceptance criteria

- DUT net and cell annotation coverage is at least 95%; clock, valid, and all
  major data inputs are 100% annotated.
- Every intentional ICG is recognized and has plausible activity matching the
  phase counters; no gated clock toggles continuously during `idle`.
- No major SRAM or PE hierarchy is unannotated or assigned a tool default
  toggle rate without an explicit note.
- Repeated runs with the same seed/configuration agree within 2%; changed seeds
  are reported as a range.
- Area or clock-gating optimizations are accepted only when functional tests,
  timing, SAIF coverage, and energy per tile/token all remain valid.

Decode and native GQA profiles are Stage 2 additions. They must include context
lengths 128/512/1024/2048, native KV-head reuse, DDR bytes per token, DMA stall
cycles, and generated-token latency.
