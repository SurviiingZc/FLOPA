# FLOPA Submission Checklist and Requirement Traceability

## 1. Competition Requirements

| Requirement | Status | Evidence |
| --- | --- | --- |
| systolic array larger than 16 x 16 | complete | 32 x 32 fused PE array; architecture and dataflow figures |
| KV cache greater than 4 KiB | complete | K and V each provide 4 KiB ping-pong capacity; 8 KiB combined |
| hardware softmax parallelism greater than 16 | complete | 32 score-scale/PWL-exp lanes |
| AXI4 master/slave interfaces | complete at system boundary | AXI4-Lite control, AXI4 writeback, VCK190 mover for 128-bit tile-loader input |
| FPGA implementation | complete | routed 170 MHz VCK190 design and deterministic smoke |
| bonus 1: scalability | **complete** | parameterized geometry, runtime configuration, tiled prefill/decode, VCK190 sequence 32-1024 mover |
| bonus 2: data reuse | **complete** | local score/P and row state, probability-stationary WS-PV, persistent O banks, ping-pong cache |
| bonus 3: energy optimization per computation | **complete** | INT8/Q1.15 mixed precision, shared 17 x 9 multipliers/accumulators, local dataflow; 8.60 pJ/MAC and 0.233 TOPS/W gate estimate |
| bonus 4: comprehensive test data | **complete** | 21/21 UVM and 23/23 module jobs; random/directed/causal/decode/backpressure; 100% functional coverage |
| bonus 5: real Transformer Attention | **complete** | SmolLM2-135M-Instruct measured on VCK190 at sequence 64 and 1024 with matching output tokens |
| Re10K workload | remaining extension | protocol and tensor plan retained; board result not yet collected |

## 2. Required Artifacts

| Artifact | Location | Status |
| --- | --- | --- |
| synthesizable RTL | `rtl/` | ready |
| module/UVM verification | `tb/module_tb/`, `tb/uvm/`, `tb/sim/` | ready |
| register/interface document | `docs/register_and_interface_reference.md` | ready |
| design/algorithm report | `docs/design_specification.md` | ready |
| PPA/optimization report | `docs/ppa_and_optimization.md` | ASIC estimate and FPGA measurements ready |
| verification/coverage report | `docs/verification_report.md` | 21/21 pass, 100% functional, 96.00% reviewed DUT |
| architecture/dataflow/pipeline figures | `figures/*.png` | ready |
| FPGA result evidence | `fpga/docs/final_report_material.md`, `fpga/model/results/` | ready |
| waveform panels | verification report Section 8 | capture for final slide deck |
| presentation | `ppt/defense_outline.md` | outline ready; rendered deck is external |
| reproduction guide | `README.md` | ready |

## 3. Final Result Summary

| Metric | Value |
| --- | ---: |
| 28 nm TT cell area estimate | 2,438,948.64 library units |
| ASIC target clock | 1.60 ns / 625 MHz |
| gate-SAIF dynamic / leakage / total | 648.6251 / 9.8584 / 658.4835 mW |
| gate workload throughput/efficiency | 76.58 GMAC/s; 8.60 pJ/MAC |
| UVM / module jobs | 21/21 / 23/23 passing |
| functional / raw merged / reviewed DUT coverage | 100.00% / 95.66% / 96.00% |
| VCK190 routed clock | 170 MHz |
| seq64 core / callback / full speedup | 19.762x / 1.410x / 1.008x |
| seq1024 core / callback / full speedup | 9.378x / 3.865x / 1.185x |

## 4. Final Packaging Gates

1. Rerun the 21-test regression on the delivered source and preserve command,
   seeds, logs, VDB, and raw/reviewed URG reports.
2. Verify every deployable directory with its `SHA256SUMS` before board use.
3. Keep the matched `BOOT.BIN`, xclbin, and host from one release build.
4. Capture the four waveform panels defined in the verification report.
5. State that FPGA power, final routed utilization table, and Re10K board data
   are not included; do not infer them from ASIC or historical FPGA reports.
6. Qualify ASIC values as 28 nm TT 0.9 V/25 C mapped estimates and distinguish
   PL core, callback, and full-prefill intervals in every performance chart.

## 5. Packaging Rule

Exclude VCS build trees, EDA work directories, transient logs, and generated
waveform databases. Include RTL, scripts, maintained Markdown, figures, compact
report extracts, raw board JSON/log evidence, and hashes/manifests for external
artifacts. The legacy `dit_fa_*` FPGA filenames are retained for compatibility
but refer to FLOPA.
