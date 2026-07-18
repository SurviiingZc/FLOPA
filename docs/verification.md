# Verification Document

## 1. Purpose

This document defines the verification plan for the Verilog RTL accelerator. Verification code uses SystemVerilog and UVM, while the DUT remains plain Verilog.

## 2. Language Boundary

- RTL: Verilog `.v` and `.vh`.
- Verification: SystemVerilog `.sv` and UVM.
- Reference model: SystemVerilog, under `tb/uvm/ref_model/`.
- SV interfaces: allowed only in TB.
- RTL must not import SV packages or use SV interfaces.

## 3. Verilog DUT and SV/UVM Integration

Integration flow:

1. Compile shared Verilog headers first.
2. Compile Verilog RTL modules.
3. Compile SV interfaces and UVM packages.
4. Compile UVM agents, env, scoreboard, coverage, sequences, and tests.
5. Compile `tb_top.sv` last.

`tb_top.sv` responsibilities:

- Instantiate the Verilog DUT.
- Instantiate SV interfaces for AXI-Lite, AXI memory/stream, clock/reset, and debug signals.
- Connect SV interface signals to DUT ports signal-by-signal.
- Publish virtual interfaces into `uvm_config_db`.
- Start the selected UVM test.

Rules:

- Wrappers may connect and pack/unpack signals only.
- Wrappers shall not implement functional behavior.
- Shared constants should come from `.vh` files when possible.
- TB-only convenience packages may mirror constants, but RTL cannot depend on them.

## 4. Verification Directory Structure

```text
tb/
    module_tb/
        common/
        softmax/
        compute/
        memory/
        axi/
    uvm/
        env/
        agents/
        sequences/
        tests/
        scoreboard/
        coverage/
        ref_model/
    sim/
        filelists/
        scripts/
        vectors/
        logs/
```

## 5. Module-Level Simple TBs

### 5.1 Purpose

`tb/module_tb/` is used for fast directed self-checking tests of small RTL modules before UVM integration.

Targets:

- `fixed_defs.vh` numeric helpers and constants.
- `accel_regfile.v`.
- `banked_sram.v`, `pingpong_buffer.v`, `stream_fifo.v`.
- `pwl_exp_unit.v`, `reciprocal_lut.v`, `online_normalizer.v`.
- `os_fsa_fused_array.v`, `scale_requant_unit.v`, and `os_fsa_controller.v`.
- `axi4_master_write.v` and AXI handshake logic.

### 5.2 Required TB Structure

Each module TB should contain:

- Clock/reset generation.
- DUT instantiation.
- Stimulus tasks.
- Golden/checker tasks.
- Timeout guard.
- Pass/fail summary.

All module TBs must be self-checking. A test that only dumps waves is not accepted.

### 5.3 Module TB Test Categories

For each module, cover:

- Reset behavior.
- Basic legal transaction.
- Boundary values.
- Randomized values where useful.
- Backpressure or stall if the module has valid/ready.
- Illegal input or error path if supported.

### 5.4 Example Module TB Policy

For `os_fsa_fused_array.v`:

- Test nonuniform score rows and the column-staggered rowmax pass.
- Check reverse `m_new` propagation and PE-local score subtraction.
- Compare shared-PWL exp writeback and PE-chain rowsum against the reference.
- Check causal masking, probability restream, and identity-V PV output.

For `banked_sram.v`:

- Test every bank.
- Test consecutive addresses.
- Test read-after-write.
- Test read/write conflict policy.
- Test ping-pong bank switch at tile boundary.
- In ASIC mode, compile against the `/data/public` SRAM Verilog model and cover every 256-word depth boundary.
- Check that active-low macro `CEB` is inactive while the logical buffer is idle.

## 6. UVM System-Level Architecture

### 6.1 Top Components

| Component | Responsibility |
| --- | --- |
| `attention_env` | Top-level UVM environment. Owns agents, scoreboard, coverage, and reference model. |
| `axi_lite_agent` | Register read/write, status polling, illegal config transactions. |
| `data_agent` | Q/K/V input data movement and output collection. |
| `axi_mem_agent` | Memory-like burst transactions if AXI memory model is used. |
| `axi_stream_agent` | Stream-style data movement if AXIS is used. |
| `virtual_sequencer` | Coordinates register and data sequences. |
| `attention_scoreboard` | Compares DUT output against SV reference model. |
| `attention_coverage` | Collects functional and cross coverage. |
| `attention_ref_model` | Bit-accurate SV reference model. |
| `protocol_assertions` | SVA checks for handshakes and protocol rules. |

### 6.2 Agents

#### AXI-Lite Agent

Responsibilities:

- Program register file.
- Read status and counters.
- Generate legal and illegal register transactions.
- Check W1C and readback behavior.

#### Data Agent

Responsibilities:

- Send Q/K/V data.
- Apply random idle cycles and backpressure.
- Record transactions for scoreboard replay.
- Support full tiles and tail tiles.

#### Output Monitor

Responsibilities:

- Capture output writes.
- Check write order and byte count.
- Send observed output to scoreboard.
- Feed writeback coverage.

### 6.3 Sequences

Sequence groups:

1. `bringup_seq`: minimal smoke flow.
2. `directed_seq`: fixed scenarios such as tile boundary or softmax extremes.
3. `random_seq`: constrained-random dimensions, data, and backpressure.
4. `negative_seq`: illegal configuration and error-path tests.
5. `re10k_seq`: real attention-layer sample tests.

All random sequences must have explicit constraints. Undefined parameter combinations are not allowed.

## 7. Scoreboard

The scoreboard compares DUT output against the SystemVerilog reference model.

Inputs:

- Register configuration snapshot.
- Q/K/V input transactions.
- DUT output transactions.
- Optional pregenerated golden vectors.

Comparison metrics:

- Exact match for integer-only submodules.
- `max_abs_error` for approximate softmax and final output.
- `mean_abs_error`.
- `cosine_similarity` for output vectors.
- Row-level softmax distribution error.

The scoreboard must print enough information to debug the first mismatch:

- test name and seed;
- tile id;
- head id;
- row/column index;
- DUT value;
- reference value;
- absolute error.

## 8. SystemVerilog Reference Model

Files:

| File | Purpose |
| --- | --- |
| `tb/uvm/ref_model/attention_ref_pkg.sv` | Common reference types and top-level APIs. |
| `tb/uvm/ref_model/qk_ref_model.sv` | QK reference and score scaling. |
| `tb/uvm/ref_model/softmax_ref_model.sv` | Mask, rowmax, exp, rowsum, LSE, normalization. |
| `tb/uvm/ref_model/pv_ref_model.sv` | PV and final output scaling. |

Requirements:

- Deterministic behavior.
- Same rounding, shift, and saturation policy as RTL.
- No DPI dependency for the primary golden path.
- Reusable by both UVM scoreboard and module TBs.

## 9. Test Plan

### 9.1 Module Tests

| Test | Goal |
| --- | --- |
| `smoke_fixed` | Fixed-point constants and helper behavior. |
| `smoke_regfile` | Register read/write/start/status/error. |
| `smoke_banked_sram` | Bank select, read/write, conflict policy. |
| `asic_sram_backend` | 256x8 macro width/depth composition and idle chip-enable gating. |
| `smoke_softmax` | PWL exp, reciprocal, and final normalization. |
| `smoke_fused_array` | QK, rowmax/sub/exp/rowsum, probability restream, and PV. |
| `smoke_axi_write` | AXI write burst and backpressure. |

### 9.3 Command-Level Checks

| Command | Goal |
| --- | --- |
| `make run` | Run all directed module and end-to-end tests. |
| `make asic-sram` | Run the structural ASIC SRAM test with the foundry functional model. |
| `make lint-rtl` | Parse and lint the DUT as plain Verilog-2001. |
| `asic/scripts/run_rtl_check.sh` | Analyze, elaborate, link, and check the ASIC build with 28nm libraries. |

Generated simulator files belong under `tb/sim/build/<test>/`. DC work files and reports belong under
`asic/dc/work/`, and DC logs belong under `asic/dc/logs/`. Tool invocations must not leave `csrc`,
`flex*.log`, `.pvl`, `.syn`, `.mr`, `command.log`, or `default.svf` in the repository root.

### 9.2 UVM Tests

| Test | Goal |
| --- | --- |
| `smoke` | One 32x32x64 attention tile. |
| `tile_boundary` | Non-multiple-of-32 sequence lengths. |
| `softmax_accuracy` | Random and extreme scores. |
| `axi_backpressure` | Random ready/valid stalls. |
| `illegal_config` | Bad head_dim, seq_len, mode, repeated start. |
| `qk_gemm` | QK-only path. |
| `pv_gemm` | PV-only path. |
| `pingpong_reuse` | Double-buffer switching. |
| `random_regression` | Multi-seed random run. |
| `transformer_layer` | Re10K attention-layer sample. |

## 10. Coverage and Acceptance Targets

### 10.1 Code Coverage

Target: **100% code coverage**, with documented waivers only.

Required coverage types:

- statement coverage: 100%;
- branch coverage: 100%;
- condition coverage: 100%;
- expression/toggle coverage: 100% when supported by the tool.

Waivers are allowed only for unreachable defensive logic or configuration paths explicitly excluded from the first milestone.

### 10.2 Functional Coverage

Target: **100% planned functional coverage**.

Required covergroups:

| Covergroup | Coverpoints |
| --- | --- |
| config coverage | mode, head_dim, num_q_heads, num_kv_heads, seq_q, seq_kv, scale mode |
| tile coverage | full tile, tail tile, short sequence, aligned boundary, unaligned boundary |
| softmax coverage | mask active, max update, sum update, exp saturation, final normalization |
| AXI coverage | burst length, alignment, backpressure, idle gap, response status |
| cache coverage | bank id, ping-pong switch, FIFO empty/full, read/write conflict |
| error coverage | illegal config, length overflow, repeated start, timeout, error code |
| performance coverage | idle, load, compute, stall, writeback, done |

Required cross coverage:

- mode x tile type;
- seq_len x tail type;
- AXI backpressure x burst length;
- cache ping-pong phase x QK/PV phase;
- illegal config x error code.

### 10.3 Sign-Off Conditions

A milestone can be accepted only when:

- all planned tests pass;
- no fatal assertion remains;
- scoreboard mismatches are resolved or documented;
- code coverage target is met or waived;
- functional coverage target is met;
- no deadlock or timeout is observed in random regression;
- error thresholds are met for approximate softmax paths.

## 11. Verification Coding Style

- Verification code uses SystemVerilog.
- UVM classes are allowed only under `tb/uvm/`.
- SV interfaces are allowed only in TB.
- Module TBs should stay simple and self-checking.
- Assertions should be placed near interfaces and monitors.
- Tests must be reproducible with a printed random seed.

## 12. Deliverables

- `tb/sim/filelists/rtl.f`
- `tb/sim/filelists/module_tb.f`
- `tb/sim/filelists/uvm.f`
- module TB source files
- UVM env, agents, sequences, tests
- SV reference model
- regression report
- coverage report
- mismatch/debug report
