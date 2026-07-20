# AXI and Data-Path Interface Design

## 1. Scope

This document covers AXI-Lite control, input data movement, and output writeback behavior.

Relevant RTL files:

- `rtl/axi/axi4_slave_if.v`
- `rtl/axi/axi4_master_write.v`
- parts of `rtl/control/accel_regfile.v`

## 2. Control Path

The control path is AXI4-Lite with 32-bit data width.

Guidelines:

- Use explicit address decode.
- Keep responses simple and deterministic.
- Support register reads and writes only.
- Do not place heavy behavior in the AXI-Lite wrapper.

## 3. Output Writeback Path

The output path uses AXI4 master burst writes.

Requirements:

- 128-bit alignment is required by the current writer; misaligned start
  addresses raise an error.
- Burst length should be chosen to match output tile packing.
- Backpressure must be handled without data loss.
- Write response must be tracked until completion.
- Any write error must be surfaced to the scheduler and status register.

## 4. Input Data Path

The first version may use a memory-window style input path or a simple staged loader.

Policy:

- Keep input staging separate from compute logic.
- Use the same 128-bit width assumption on the internal staging path.
- Align tile movement with scheduler phase boundaries.

## 5. Interface Behavior

### 5.1 AXI-Lite

- Read/write only the defined register map.
- Do not allow undefined side effects on partial writes.
- Keep register read data stable.

### 5.2 AXI Master Write

- Track outstanding burst state.
- Pause cleanly when downstream is not ready.
- Do not advance the output buffer until the beat is accepted.
- Write completion should raise the scheduler done signal only after the last response is observed.
- Limit each burst by remaining beats, configured burst length, and beats to
  the next 4-KB boundary. No AW transaction may cross a 4-KB boundary.
- Writeback addressing uses registered head-base/head-stride state and
  constant-increment Q-tile updates rather than runtime nested multiplications.

## 6. Integration with Verification

The verification environment should have a dedicated AXI-Lite agent and a memory/stream agent.

Each transaction should be observable by the scoreboard and protocol assertions.
