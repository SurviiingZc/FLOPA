# Synthesis and Implementation Notes

This engineering note describes the current synthesis contract and the
remaining implementation work. Contest-facing numerical tables are maintained
in [PPA and Optimization](ppa_and_optimization.md); superseded round-by-round
logs are intentionally not duplicated here.

## 1. Current Configuration

| Item | Current setting |
| --- | --- |
| top | `attention_accel_top` |
| process corner | TSMC 28 nm TT, 0.9 V, 25 C |
| standard-cell view | `tcbn28hpcplus...tt0p9v25c_ccs.db` |
| SRAM view | `uhdsp_256x8m4s_tt0p9v25c.db` |
| clock target | 1.60 ns / 625 MHz |
| geometry | 32 x 32 PEs, four 8-row stripes, `HEAD_DIM=64` |
| physical awareness | disabled in the current logical baseline |
| wire model | `ZeroWireload` |
| RTL/tool ICG count | 0 / 0 |
| DesignWare library | `dw_foundation.sldb` |

The current `fa_clock_gate` wrapper passes through the root clock in ASIC and
FPGA builds. Synthesis rejects a stale netlist containing either characterized
ICGs or generic `SNPS_CLOCK_GATE_HIGH_*` modules. This is the fixed comparison
baseline for later low-power experiments.

## 2. Current Mapped Result

| Metric | Result |
| --- | ---: |
| setup WNS / TNS / failing paths | 0.000 ns / 0.000 ns / 0 |
| critical path | 1.49 ns, 60 levels |
| total cell area | 2,438,964.94 library units |
| combinational area | 1,161,025.14 |
| noncombinational area | 621,193.10 |
| macro area | 656,746.70 |
| total cells | 1,524,232 |
| combinational cells | 1,281,371 |
| sequential cells | 242,335 |
| buffer/inverter cells | 252,342 |
| SRAM macros | 480 |
| fused-array area | 2,048,222.41 (84.0%) |

The zero setup slack means DC met the requested logical target without positive
margin. Placement, routing, clock-tree, and extracted-parasitic results are
still required before assigning a deployable ASIC frequency.

Reports:

- `asic/dc/work/synth/tt/system/attention_accel_top/reports/qor.rpt`
- `asic/dc/work/synth/tt/system/attention_accel_top/reports/area.rpt`
- `asic/dc/work/synth/tt/system/attention_accel_top/reports/resources.rpt`
- `asic/dc/work/synth/tt/system/attention_accel_top/reports/run_config.rpt`

## 3. Arithmetic Mapping

The complete top contains 1,220 `fa_mult_*` wrappers and 1,220 linked
`DW02_mult` instances. The wrappers provide explicit width, signedness, and
pipeline contracts while allowing DC to optimize the implementation.

Current arithmetic choices:

- Q/K/V remain signed INT8 through cache and array links and are extended only
  at multiplier inputs;
- PE QK and PV share the phase-exclusive 32-bit accumulator state;
- score scaling is pipelined and replicated across 32 exp lanes;
- PWL exp registers the decoded segment difference before its multiply;
- O rescale is pipelined per stripe;
- the normalizer carries payload, valid, and feature tags through reciprocal
  and scaling stages at II=1.

Do not replace the wrappers with fixed hard macros solely because a `*` appears
in RTL. A dedicated macro is justified only after a target-specific report
shows an unsuitable mapping and the replacement has an equivalent latency and
verification contract.

## 4. Memory Mapping

| Owner | Organization | Macro count |
| --- | --- | ---: |
| Q/K/V ping-pong cache | six 256-bit memories assembled from byte macros | 192 |
| persistent O banks | four stripes, eight rows, two feature groups | 256 |
| output buffer | one 256-bit memory | 32 |
| total | | 480 |

The current macros provide a stable characterized backend but use capacity
inefficiently, especially in the persistent O banks. A later ASIC revision
should compare wider/deeper macros, row packing, byte-write support, port
conflicts, placement aspect ratio, and access latency. FPGA builds keep the
same logical contract while mapping storage to BRAM/URAM resources.

## 5. Gate-SAIF Power Flow

The accepted flow is:

```text
mapped Verilog + cell/SRAM models
  -> VCS fa_random_qkv_test
  -> DUT-only SAIF for tb_top/dut
  -> Power Compiler read_saif on the matching mapped DDC
  -> annotation, hierarchy, clock, and power reports
```

The current 64 x 64 seed-301 run samples cycles 57--4336 and passes with zero
UVM errors/fatals. Nets, ports, and pins are all 100% annotated. Power Compiler
reports 648.6251 mW dynamic, 9.8584 mW leakage, 658.4835 mW total, and
18.1893 mW net switching power. See the PPA document for full qualifications
and artifact paths.

## 6. Commands

Run from the repository root:

```bash
make synth-config
make synth CORNER=tt CLOCK_PERIOD=1.6
make formality CORNER=tt
make gate-saif-power CORNER=tt GATE_SEQ_Q=64 GATE_SEQ_KV=64 \
  GATE_SAIF_SEED=301
```

For physical-aware synthesis:

```bash
make synth-physical CORNER=tt CLOCK_PERIOD=1.6 \
  PHYSICAL_MW_LIB=/path/to/combined_design_mw \
  PHYSICAL_TLUPLUS_MAX=/path/to/max.tluplus \
  PHYSICAL_TLUPLUS_MIN=/path/to/min.tluplus \
  PHYSICAL_TLUPLUS_MAP=/path/to/tech2itf.map
```

## 7. Remaining Work

1. Build the combined physical library, place the 480 macros, and obtain
   routed setup, congestion, transition, capacitance, and clock-tree results.
2. Reorganize the persistent O storage after the FPGA dataflow is stable.
3. Re-evaluate clock gating only against the fixed zero-ICG 64 x 64 workload,
   with equivalence and complete numerical gate regression required before a
   power comparison is accepted.
4. Add idle, Re10K prefill, LLM prefill, and decode SAIF profiles using the same
   RTL-hash and DDC/SAIF matching rules.
5. Use the VCK190 reports to determine whether any multiplier maps to LUT fabric
   instead of DSP and adjust wrappers only where the report justifies it.
