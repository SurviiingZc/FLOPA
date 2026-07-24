# Verification Plan, Test Cases, and Coverage Report

## 1. Verification Objective and Scope

Verification uses plain Verilog RTL with SystemVerilog/UVM test infrastructure.
The scoreboard calls a bit-accurate SystemVerilog reference model that mirrors
the fixed-point score scaling, PWL exponential, online `m/l/O` recurrence,
reciprocal, rounding, saturation, causal masking, and output-byte packing.

The verified system scope is:

- 32 x 32 INT8 MHA prefill, including two Q tiles and two KV tiles;
- single-query MHA decode with a 32-token KV tile;
- AXI4-Lite programming, 128-bit tile-loader ingress, and 128-bit AXI4 write;
- cache bank transitions, output backpressure, legal and illegal configuration;
- PWL boundaries, rounding, positive/negative saturation, and causal masking.

The following are outside current sign-off scope: native GQA, an AXI4 read DMA,
VCK190 hardware, more-than-two-tile numerical regression, post-route timing,
and a proof that the current PWL precision meets the contest requirement.

## 2. Verification Environment

```text
AXI-Lite UVM agent ----+                         +---- AXI4 write agent/monitor
Tile-loader UVM agent -+--> attention_accel_top -+---- status/IRQ monitor
                       |                         |
                       +--> scoreboard <---------+
                              |          |
                              |          +--> functional coverage
                              +--> bit-accurate reference model
```

| Component | Location | Responsibility |
| --- | --- | --- |
| module TBs | `tb/module_tb/` | directed self-checking tests and default FSDB generation |
| UVM top/environment | `tb/uvm/tb_top.sv`, `tb/uvm/env/` | virtual interfaces, agents, test coordination |
| sequences/tests | `tb/uvm/sequences/`, `tb/uvm/tests/` | fixed-seed directed/random, backpressure, invalid configuration, two-tile flows |
| reference model | `tb/uvm/ref_model/attention_ref_model.svh` | bit-accurate expected bytes and numerical events |
| scoreboard | `tb/uvm/scoreboard/` | loader accounting, output address/data comparison, end-of-test checks |
| assertions | `tb/uvm/protocol_assertions.sv` | AXI ready/valid stability and protocol properties |
| coverage | `tb/uvm/coverage/` | AXI-Lite, tile loading, AXI write, scheduler, math and ping-pong coverage |

The SystemVerilog environment is a verification-only wrapper. The synthesizable
DUT remains Verilog and does not import UVM packages or SV interfaces.

## 3. Module-Level Verification Plan

All retained module testbenches are self-checking and run from `tb/sim`. Each
uses reset, directed legal traffic, boundary conditions, and a timeout. Where
the interface contains handshakes, the test includes stalls or backpressure.

| RTL function | Primary testbench | Key checks |
| --- | --- | --- |
| AXI control/write | `tb_axi4_slave_if`, `tb_axi4_master_write` | read/write responses, burst sequence, WLAST, backpressure |
| scheduler/regfile/performance | `tb_accel_regfile`, `tb_accel_scheduler`, `tb_perf_counter` | START snapshot, status/error behavior, state transitions, counters |
| cache/memory | `tb_qkv_tile_cache`, `tb_pingpong_buffer`, `tb_banked_sram`, `tb_asic_sram_backend` | bank validity, consume/switch, read-after-write, ASIC macro composition |
| fused compute | `tb_fsa_fused_array`, `tb_fsa_stripe`, `tb_fsa_fused_pe`, `tb_fsa_pv_engine` | QK, rowmax, reverse delta, P writeback, rowsum, WS-PV, feature tags |
| fixed-point pipes | `tb_score_scale_pipe`, `tb_pwl_exp_unit`, `tb_online_normalizer`, `tb_reciprocal_lut` | PWL corners, pipeline tag alignment, rounding, reciprocal/normalization saturation |
| integrated RTL | `tb_attention_accel_top` | one-tile load/compute/normalization/writeback protocol |

Run the directed suite as follows:

```bash
cd tb/sim
make syntax
make run
make asic-sram
make lint-rtl
```

## 4. UVM System Test Plan

The fixed-seed regression script is `tb/sim/scripts/run_uvm_regression.sh`.
The following 15 test cases are compiled with code coverage and merged into
one coverage database.

| Test | Seed | Stimulus and checker focus |
| --- | ---: | --- |
| `fa_smoke_test` | 1 | legal prefill/configuration, basic byte-exact output |
| `fa_axi_backpressure_test` | 19 | AXI write stalls and ready/valid stability |
| `fa_random_qkv_test` | 101 | randomized signed Q/K/V and bit-exact oracle |
| `fa_pwl_corner_test` | 102 | PWL segment/boundary and exp clamp behavior |
| `fa_arith_rounding_test` | 106 | guard/sticky rounding path and exact output bytes |
| `fa_positive_saturation_test` | 103 | positive INT8 saturation |
| `fa_negative_saturation_test` | 104 | negative INT8 saturation |
| `fa_causal_random_test` | 105 | causal mask plus random data and output stalls |
| `fa_two_tile_pingpong_test` | 301 | two Q/two KV tiles, bank preload/refill, exact online recurrence, contiguous writes |
| `fa_two_tile_random_backpressure_test` | 302 | two-tile random data with output stalls and address-hole/duplicate detection |
| `fa_decode_smoke_test` | 201 | one-query MHA decode and row-zero validity |
| `fa_decode_backpressure_test` | 202 | decode AXI write stalls and four-beat writeback |
| `fa_decode_random_test` | 203 | random decode, full 32-token context, feature/tag ordering |
| `fa_decode_illegal_config_test` | 204 | reject decode with `seq_q=2` and recover error state |
| `fa_illegal_config_test` | 7 | generic invalid configuration/error response |

Run and reproduce the merged report:

```bash
cd tb/sim
OUT_DIR=build/uvm_two_tile_random_pingpong scripts/run_uvm_regression.sh
```

## 5. Latest Passing Regression Record

| Item | Recorded result |
| --- | --- |
| Date | 2026-07-23 |
| Simulator | VCS V-2023.12-SP2_Full64 |
| Database | `tb/sim/build/uvm_two_tile_random_pingpong/coverage.vdb` |
| HTML/text report | `tb/sim/build/uvm_two_tile_random_pingpong/urg/` |
| Result | 15/15 fixed-seed tests pass; UVM error and fatal counts are zero |
| Numerical checking | prefill, decode, and two-tile random results compare against the bit-accurate SV model |
| Ping-pong result | Q/K/V loads are 128/256/256 words; bank coverage is 100% in `fa_tile_coverage` |
| Writeback result | second Q tile starts at byte 2048; `0..4095` has no holes, duplicates, or invalid bytes |

The address check specifically guards the former failure mode in which a
level-held AXI completion was consumed twice, advancing the second Q-tile
writeback base from 2048 to 4096. The RTL now uses one shared rising-edge
completion pulse.

## 6. Coverage Analysis

| Scope | Score | Line | Condition | Toggle | Branch | Functional group |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Composite report | 80.75% | 85.49% | 68.08% | 83.41% | 85.36% | 81.44% |
| `tb_top.dut` hierarchy | 80.79% | 85.90% | 68.19% | 83.42% | 85.65% | N/A |
| Module definitions | 73.65% | 68.03% | 64.57% | 75.94% | 86.08% | N/A |
| UVM functional covergroups | 81.44% | N/A | N/A | N/A | N/A | 81.44% |

The composite score includes a low-covered Verdi UVM recorder instance. The
`tb_top.dut` row is therefore the appropriate current DUT code-coverage
baseline. No coverage waiver is applied.

| Functional area | Current result | Coverage debt |
| --- | --- | --- |
| Tile loader | 100% | none in the current covergroup |
| AXI-Lite | 67.50% | scale 1.00, DECERR, additional response/cross bins |
| AXI write | 83.33% | legal short-burst/last-beat model and cross coverage |
| Scheduler phase | 77.78% | ERROR and phase/IRQ combinations |
| Math / softmax | 78.57% | non-unity exp, score saturation, output saturation, rounding/saturation crosses |
| high-value RTL instances | 47.87-90.14% | regfile, scheduler, and perf counter are the weakest code-coverage blocks |

The project does **not** claim the stated 95% RTL code-coverage or 100%
functional-coverage target. Closure requires new tests for error, busy/restart,
perf counter, legal tail/short burst, saturation, and relevant crosses, followed
by a new merged VDB. Numerical correctness for the documented 15 fixed seeds is
closed; coverage sign-off is not.

## 7. Figure and Waveform Placeholders

The final submission should include wave screenshots. Existing module TBs dump
FSDB by default into their build directory. The UVM top currently captures SAIF
on request, not FSDB; use a TB-only dump hook or Verdi capture for the UVM
placeholder below. Do not add waveform code to synthesizable RTL.

### W1. Top-Level Control and AXI Writeback

**Placeholder caption:** "Configuration, Q/K/V tile loading, fused execution,
and AXI4 writeback for one attention tile."

- Generate: `cd tb/sim && make top`
- File: `tb/sim/build/tb_attention_accel_top/tb_attention_accel_top.fsdb`
- Capture: clock/reset; `debug_state_o`; tile-loader valid/ready/kind/bank/
  address/half; `m_axi_awaddr`, `m_axi_awvalid`, `m_axi_awready`,
  `m_axi_wvalid`, `m_axi_wready`, `m_axi_wlast`, `m_axi_bvalid`, and `irq_o`.
- Intended visual proof: legal state order, two 128-bit halves per cache word,
  contiguous output burst, and completion only after the write response.

### W2. PE-Local Softmax and WS-PV

**Placeholder caption:** "Column-overlapped rowmax, reverse delta, P writeback,
rowsum, and continuous feature-major WS-PV in the fused array."

- Generate: `cd tb/sim && make compute`
- File: `tb/sim/build/tb_fsa_fused_array/tb_fsa_fused_array.fsdb`
- Capture: `qk_valid_i`, `qk_last_i`, `qk_last_o`, `softmax_start_i`,
  `softmax_pv_ready_o`, `softmax_done_o`, `pv_start_i`, `pv_ready_o`,
  `pv_valid_i`, `pv_feature_i`, `pv_done_o`, `norm_rd_en_i`,
  `norm_rd_feature_i`, `norm_rd_valid_o`, `norm_rd_feature_o`, and
  `norm_rd_acc_o`.
- Intended visual proof: PV starts before the serial L-update drain completes,
  and an O-bank normalizer read returns the same feature tag that was requested.

### W3. Normalizer Tag and Rounding Pipeline

**Placeholder caption:** "Eight-lane normalization preserves payload/tag
alignment through reciprocal and two multiply stages."

- Generate: `cd tb/sim && make softmax`
- File: `tb/sim/build/tb_online_normalizer/tb_online_normalizer.fsdb`
- Capture: `valid_i`, `acc_rows_i`, `l_rows_i`, `out_scale_i`, `tag_i`,
  `dut.reciprocal_valid_w`, `dut.norm_product_valid_w`,
  `dut.scale_product_valid_w`, `valid_o`, `tag_o`, and `out_rows_o`.
- Intended visual proof: adjacent transactions and a bubble retain their
  corresponding tags, including signed positive/negative saturation outputs.

### W4. Two-Tile Ping-Pong under UVM

**Placeholder caption:** "Bank0/bank1 transition, refill overlap, and the
single AXI-write completion pulse in the two-Q/two-KV regression."

- Reproduce the 15-test UVM database with the command in Section 4. Add a
  verification-only `$fsdbDumpfile/$fsdbDumpvars` hook in `tb/uvm/tb_top.sv`
  or use a Verdi capture session; save as
  `tb/sim/build/uvm_two_tile_random_pingpong/fa_two_tile_pingpong_test.fsdb`.
- Capture: `status_if.debug_state`, `tile_if.load_*`, `tile_if.commit_*`,
  `write_if.aw*`, `write_if.w*`, `write_if.b*`, and DUT internals
  `q_active_bank_w`, `kv_active_bank_w`, `q_consume_w`, `kv_consume_w`,
  `axi_write_done_w`, `axi_write_done_pulse_w`, and `writeback_addr_q`.
- Intended visual proof: inactive-bank refill while active-bank computation or
  writeback proceeds; exactly one Q consume and one address increment per B
  response; second Q-tile writeback begins at byte 2048.

## 8. Regression Update Rule

When RTL changes, rerun at least the affected module testbench, its UVM test,
and then the 15-test regression before updating this document. Add the new
date/tool/seed/VDB path, exact pass/fail count, and revised coverage metrics.
Never treat an FSDB screenshot as a replacement for a scoreboard result.
