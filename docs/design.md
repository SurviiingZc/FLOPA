# Design Document

## 1. Purpose

This document defines the RTL architecture, source-file responsibilities, coding rules, timing-closure strategy, and module-level design methods for the FlashAttention-like accelerator.

The document is intended to guide actual RTL implementation, not just describe the algorithm.

## 2. Language Decision

### 2.1 Final Decision

The RTL implementation shall use **Verilog** as the main design language.

The verification environment shall use **SystemVerilog and UVM**.

Rationale:

- Verilog RTL has the broadest compatibility across Vivado, VCS, Design Compiler, and possible contest review flows.
- A plain Verilog RTL codebase is easier to migrate between FPGA and ASIC-style front-end flows.
- SystemVerilog/UVM testbenches can instantiate and verify Verilog modules directly.
- RTL should not depend on SV-only constructs such as `interface`, `package`, `class`, `typedef enum`, `logic`, `always_ff`, or `always_comb`.

### 2.2 Verilog RTL and SV/UVM Integration

The integration boundary is fixed as follows:

1. The DUT is a normal Verilog module with plain `input`, `output`, `wire`, and `reg` ports.
2. The UVM testbench is written in SystemVerilog and may use `interface`, `package`, classes, sequences, virtual interfaces, and assertions.
3. `tb_top.sv` instantiates the Verilog DUT and the SV interfaces.
4. SV interfaces are connected to DUT ports signal-by-signal in `tb_top.sv` or in a thin SV wrapper.
5. Shared constants are placed in Verilog headers such as `rtl/common/attention_defines.vh`.
6. Both RTL and TB may include the same `.vh` files with `` `include``.
7. The RTL shall not import SV packages.
8. The TB may wrap `.vh` constants into an SV package for UVM convenience.
9. The compile order is: Verilog headers, RTL `.v`, SV interfaces/packages, UVM components, then `tb_top.sv`.

This keeps the RTL synthesis-friendly while allowing the verification side to use full SystemVerilog/UVM capability.

## 3. Frequency Targets

The VCK190 PL clock target is split into three levels:

- **150 MHz**: bring-up and fallback target.
- **200 MHz**: first implementation baseline.
- **312.5 MHz**: aggressive timing-closure exploration target.

312.5 MHz should not be written as a guaranteed maximum frequency. It should be treated as a serious search target because AMD VCK190/Vitis platform examples expose PL/kernel clocking in this range. Final claims must come from post-route timing reports.

Timing-closure flow:

1. Close functionality at 200 MHz first.
2. Sweep implementation targets at 250 MHz, 300 MHz, and 312.5 MHz.
3. Use post-route timing as the only accepted frequency evidence.
4. If 312.5 MHz does not close, identify the top failing paths and either add pipeline stages or report a lower achieved frequency.

References:

- AMD Vitis accelerated embedded platform documentation for VCK190 clocking examples: https://docs.amd.com/r/2024.2-English/ug1701-vitis-accelerated-embedded/Adding-Hardware-Interfaces
- AMD Versal system design clocking tutorial: https://docs.amd.com/r/2024.1-English/Vitis-Tutorials-AI-Engine-Development/Versal-System-Design-Clocking

## 4. RTL Coding Rules

### 4.1 Verilog Style

- Use Verilog-2001 style modules.
- Use `.v` for RTL files.
- Use `.vh` for shared macros and parameters.
- Use `reg` for sequentially assigned signals.
- Use `wire` for continuous assignments and module connections.
- Use `localparam` for state encoding and internal constants.
- Use `parameter` only for module-level configurability.

### 4.2 Sequential and Combinational Separation

Sequential logic and combinational logic must not be mixed.

Sequential block style:

```verilog
always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    state_q <= IDLE;
  end else begin
    state_q <= state_d;
  end
end
```

Combinational block style:

```verilog
always @(*) begin
  state_d = state_q;
  case (state_q)
    IDLE: if (start) state_d = LOAD_Q;
    default: state_d = IDLE;
  endcase
end
```

Rules:

- Use nonblocking assignments `<=` in sequential blocks.
- Use blocking assignments `=` in combinational blocks.
- Every combinational output must get a default assignment.
- No inferred latches are allowed.
- No combinational loops are allowed.
- No multi-driver nets are allowed.
- No `#delay`, `wait`, `fork/join`, file I/O, randomization, or testbench-only constructs in RTL.

### 4.3 Reset Policy

- Use a single active-low reset name: `rst_n`.
- Reset all control state, valid bits, counters, and observable status registers.
- Large datapath memories do not need full reset unless required by behavior.
- After reset, all output valid signals must be deasserted.

### 4.4 Timing-Aware RTL Rules

- Long add/compare trees must be balanced and pipelined.
- Broadcast signals to 32 lanes must be registered or replicated.
- Wide muxes must be avoided on critical datapaths.
- State machines shall control phases only, not perform heavy arithmetic.
- Memory address generation shall be registered before RAM access.
- Tile-boundary mode changes are preferred over cycle-by-cycle dynamic mode changes.
- Valid/ready paths must not form long combinational feedback loops.

## 5. Top-Level Architecture

The accelerator implements a tiled FlashAttention-like MHA pipeline:

1. AXI4-Lite configures registers.
2. Q/K/V tiles are loaded into on-chip tile caches.
3. The scheduler iterates over Q tiles and K/V tiles.
4. The 32x32 output-stationary array computes QK.
5. The softmax path applies mask, row max, exp approximation, row sum, LSE update, and normalization.
6. The same compute fabric is reused for PV.
7. The output buffer collects O tiles.
8. AXI4 master writes results back to memory.

The first version should keep one primary clock domain for RTL simplicity.

## 6. RTL Source File Responsibilities

### 6.1 Top Level

| File | Purpose | Design Notes |
| --- | --- | --- |
| `rtl/attention_accel_top.v` | Top-level integration | Connect control, AXI, cache, compute, softmax, and output paths. Avoid heavy algorithmic logic in the top module. |

### 6.2 Common

| File | Purpose | Design Notes |
| --- | --- | --- |
| `rtl/common/attention_defines.vh` | Global parameters, state encodings, register offsets, mode constants | Shared by RTL and SV TB through `` `include``. Do not use SV package syntax. |
| `rtl/common/fixed_defs.vh` | Fixed-point widths, saturation constants, rounding constants | Keep numeric policy centralized. |

### 6.3 Control

| File | Purpose | Design Notes |
| --- | --- | --- |
| `rtl/control/accel_regfile.v` | Software-visible register file | Use explicit address decode, shadow start configuration, status bits, and error codes. |
| `rtl/control/accel_scheduler.v` | Tile-level scheduler | FSM for IDLE, LOAD_Q, LOAD_KV, QK, SOFTMAX, PV, WRITEBACK, DONE, ERROR. |
| `rtl/control/perf_counter.v` | Performance counters | Count cycles, stalls, busy cycles, MAC activity, AXI stalls, and tile count. Keep off the critical datapath. |

### 6.4 AXI

| File | Purpose | Design Notes |
| --- | --- | --- |
| `rtl/axi/axi4_slave_if.v` | AXI4-Lite/control-side signal handling | RTL side uses plain Verilog ports. SV interface exists only in TB. |
| `rtl/axi/axi4_master_write.v` | Output writeback engine | Support aligned 128-bit bursts, backpressure, write response handling, and done signaling. |

### 6.5 Compute

| File | Purpose | Design Notes |
| --- | --- | --- |
| `rtl/compute/os_fsa_fused_pe.v` | Active fused PE | Holds score, probability, and O accumulator state; implements local max/subtract/sum and restream links. |
| `rtl/compute/os_fsa_fused_array.v` | Active 32x32 FSA-style OS array | Registered input skew, PE-local online softmax, shared 32-lane exp, probability restream, and PV. |
| `rtl/compute/os_fsa_delay_line.v` | Systolic skew stage | Registers row/column boundary data and valid/last tokens. |
| `rtl/compute/os_fsa_controller.v` | Array mode controller | Controls QK/PV phases, PE modes, score hold, and beta stream timing. |
| `rtl/compute/scale_requant_unit.v` | Fixed-point rescale/requantization | Signed multiply, shift, round, saturate, and optional zero-point add. |
| `rtl/compute/fsa_qk_engine.v` | Active QK wrapper | Reads Q/K tiles and drives the fused array without score/matrix output ports. |
| `rtl/compute/fsa_pv_engine.v` | Active PV wrapper | Restores one O-accumulator row at a time and streams V; probability remains inside the PE array. |

### 6.6 Softmax

| File | Purpose | Design Notes |
| --- | --- | --- |
| `rtl/softmax/pwl_exp_unit.v` | PWL exp approximation | Pipelined piecewise-linear exp approximation for non-positive inputs. |
| `rtl/softmax/reciprocal_lut.v` | Reciprocal seed/LUT | Provides reciprocal approximation for final normalization. |
| `rtl/softmax/online_normalizer.v` | Final normalization | Pipelined reciprocal alignment, normalization multiply, scale multiply, shift, and saturation. |

### 6.7 Memory

| File | Purpose | Design Notes |
| --- | --- | --- |
| `rtl/memory/pingpong_buffer.v` | Double buffering | Switch banks only at tile boundaries. |
| `rtl/memory/banked_sram.v` | Generic banked SRAM wrapper | Parameterized bank count and width. Can infer BRAM/URAM or map to SRAM macros. |
| `rtl/memory/uram_bank.v` | URAM-specific bank wrapper | FPGA-oriented large tile-cache storage. |
| `rtl/memory/bram_buffer.v` | BRAM buffer wrapper | Smaller buffers, output tile, staging FIFO. |
| `rtl/memory/qkv_tile_cache.v` | Q/K/V tile cache | Unified staging cache for Q, K, and V tiles. |
| `rtl/memory/stream_fifo.v` | Short stream FIFO | Handles local backpressure and pipeline alignment. |
| `rtl/memory/output_buffer.v` | Output aggregation | Packs final O tile for AXI master writeback. |

## 7. Module Design Methods

The detailed module implementation guidance now lives under `docs/impl/`.
Use these files as the coding contract for RTL work:

- `docs/impl/README.md`: index and usage rule.
- `docs/impl/common.md`: shared headers, numeric policy, and parameter set.
- `docs/impl/register_file.md`: register table, software contract, and illegal config policy.
- `docs/impl/scheduler.md`: FSM, tile flow, and control handshakes.
- `docs/impl/axi.md`: AXI-Lite control path, input staging, and output writeback.
- `docs/impl/compute.md`: PE, array, controller, requantization, QK, and PV.
- `docs/impl/softmax.md`: mask, reduction, exp, LSE, reciprocal, and normalization.
- `docs/impl/memory.md`: banked SRAM, ping-pong, Q/K/V cache, FIFOs, and output buffer.

Short rule:

- `common.md` defines shared constants first.
- `register_file.md` freezes the software-visible contract next.
- The remaining module docs define the implementation order for RTL.
- RTL should be coded against these documents, and any future RTL change should update the corresponding impl doc first.

## 8. Timing Closure Checklist

- No long combinational ready/valid loops.
- No single-cycle 32-lane reduction without pipeline.
- No high-fanout row-state broadcast without register replication.
- No huge mux on score/beta/O paths.
- No unregistered RAM address path.
- No mixed control/datapath state machine doing arithmetic.
- Critical paths must be documented after synthesis and post-route.

## 9. Interface Freeze Items

Freeze these early:

- Register map.
- Verilog module ports.
- Data widths for Q/K/V, score, beta, O_acc, and O.
- Tile sizes and bank counts.
- State encodings and error codes.
- Filelist compile order.

## 10. Deliverables

- Verilog RTL files under `rtl/`.
- Shared headers under `rtl/common/`.
- Timing constraints and reports under `asic/` and `fpga/`.
- Updated design diagrams and module descriptions in this document.
