# FLOPA Defense Outline

## 1. Problem and Requirements

- FlashAttention is limited by score/probability traffic and nonlinear
  softmax scheduling.
- Competition targets: array larger than 16 x 16, KV cache above 4 KiB,
  softmax parallelism above 16, AXI integration, FPGA operation, reuse, and
  quantization.
- Explicitly state that all five bonus items are completed: scalability, data
  reuse, energy optimization per computation, comprehensive test data, and
  real Transformer Attention with measured VCK190 results.

## 2. Architecture

- 32 x 32 fused PE fabric arranged as four 8 x 32 stripes.
- Ping-pong Q/K/V cache, PE-local score/P, persistent feature-addressed O
  banks, 32-lane SFU, final normalizer, and AXI control/writeback.
- Show `flopa_overall_architecture.png` and `flopa_design_overview.png`.

## 3. Local QK and Online Softmax

- INT8 output-stationary QK accumulates INT32 scores in each PE.
- Rowmax propagates in the row; `score-m_new` returns through the array.
- One completed column enters 32 parallel scale/PWL-exp lanes, while rowsum
  overlaps the following columns.

## 4. Probability-Stationary WS-PV

- P remains in the PE array while feature-major V streams vertically.
- Persistent O banks retain partial output across KV tiles and align the seed
  by feature, removing repeated O preload.
- Row-state update and WS-PV overlap.

## 5. Numeric and Interface Contract

- INT8 Q/K/V/output, Q1.15 P/alpha, INT32 score/O/l.
- AXI4-Lite register control, 128-bit mover input, 128-bit AXI4 output.
- MHA prefill and single-query decode; software GQA-to-MHA expansion on board.

## 6. Verification

- 21/21 UVM runs and 23/23 module jobs pass with zero errors/fatals.
- Functional coverage 100.00%; raw merged 95.66%; reviewed DUT 96.00%.
- Prefill through 512 x 512 and decode through 1 x 256.
- Add waveform panels specified in `docs/verification_report.md` Section 8.

## 7. ASIC PPA

- 28 nm TT, 0.9 V, 25 C; 1.60 ns target.
- Estimated area 2,436,075.17 library units with 480 SRAM macros.
- Gate-SAIF: 648.6251 mW dynamic, 9.8584 mW leakage, 658.4835 mW total.
- 76.58 GMAC/s (153.16 GOPS) and 8.60 pJ/MAC on the sampled 64 x 64 job.

## 8. VCK190 and SmolLM2

- Routed 170.019 MHz VCK190 design with 0.012 ns setup WNS; deterministic
  smoke passes twice with zero stalls and zero errors.
- 294,718 LUTs, 295,111 FFs, 6.5 BRAM tiles, 96 URAMs, and 1,220 DSP58s.
- Sequence 64: 19.762x core, 1.410x callback, 1.008x full-prefill speedup.
- Sequence 1024: 9.378x core, 3.865x callback, 1.185x full-prefill speedup.
- Explain the gap using measured quantization/packing/GQA/output conversion
  and non-Attention PS time.

## 9. Limits and Next Steps

- Native GQA, on-chip KV multicast/reuse, and fused tensor conversion.
- Re10K board measurement and board power measurement.
- Routed ASIC implementation and better-shaped SRAM macros.
