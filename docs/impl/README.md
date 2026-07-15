# Implementation Guides

This directory contains module-level design guidance for RTL implementation.
Use these files as the source of truth when writing Verilog.

## Index

- `common.md`: shared parameters, numeric rules, and include-file policy.
- `register_file.md`: AXI-Lite register map and software contract.
- `scheduler.md`: top-level FSM and tile-level control flow.
- `axi.md`: control bus, input window, and writeback behavior.
- `compute.md`: PE, array, controller, QK, PV, and requantization guidance.
- `softmax.md`: mask, reduction, exp, LSE, and normalization guidance.
- `memory.md`: banked SRAM, ping-pong, Q/K/V cache, and output buffer guidance.

## Use Rule

Write RTL to match these documents, not the other way around.
