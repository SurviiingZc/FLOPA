# FLOPA Defense Outline

## 1. Motivation and Competition Requirements

- FlashAttention data-movement bottleneck and fixed-point hardware objective.
- Requirement summary: array size, KV capacity, softmax parallelism, AXI, FPGA.

## 2. FLOPA Architecture Overview

- 32 x 32 fused PE fabric in four 8-row stripes.
- Ping-pong Q/K/V cache, persistent feature-addressed O banks, final normalizer.
- External 128-bit tile-loader boundary and AXI4 writeback.

## 3. Fully Local QK and Online Softmax

- Output-stationary QK with signed INT8 operands and INT32 score accumulation.
- PE-local rowmax, reverse `score-m_new`, 32-lane PWL exp, overlapped rowsum.
- Show architecture and QK/softmax dataflow figures.

## 4. Probability-Stationary WS-PV

- P remains in the PE array; feature-major V streams vertically.
- Persistent O-bank seed removes repeated partial-output preload.
- WS-PV overlaps the row-state update and sustains continuous feature issue.

## 5. Numeric Formats and Interface

- INT8 Q/K/V/output, Q1.15 P/alpha, INT32 score/O/l.
- Register map, prefill/decode commands, AXI4-Lite and AXI write contracts.

## 6. Verification Evidence

- 20/20 fixed-seed UVM runs passing with a bit-accurate reference model.
- 100.00% functional coverage; 85.28% DUT code coverage with closure plan.
- 64 x 64 mapped-netlist power workload: zero UVM errors/fatals.
- Include four waveform panels from `docs/verification_report.md` Section 8.

## 7. ASIC PPA Baseline

- 28 nm TT, 0.9 V, 25 C, 1.60 ns target.
- Cell area: 2,438,964.94 library units; 480 SRAM macros.
- Gate-SAIF power: 648.6251 mW dynamic, 9.8584 mW leakage,
  658.4835 mW total; net switching is 18.1893 mW.
- 64 x 64 workload: 76.58 GMAC/s average and 8.60 pJ/MAC derived metrics.

## 8. FPGA and Model Evaluation Plan

- VCK190 PS baseline versus PL-accelerated Re10K attention.
- LLM prefill experiment, DDR traffic, throughput, latency, and board power.
- Input DMA/tile-loader integration and post-route resource/Fmax reporting.

## 9. Limitations and Roadmap

- Native GQA, code-coverage closure, physical ASIC power, and full board results.
- Larger SRAM macro organization and extended decode/model evaluation.
