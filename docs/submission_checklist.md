# Submission Checklist and Requirement Traceability

## 1. Competition Requirement Map

| Requirement | Status | Evidence / presentation action |
| --- | --- | --- |
| systolic array larger than 16 x 16 | implemented and verified | 32 x 32 fused PE array; include the architecture and dataflow figures |
| KV cache capacity greater than 4 KiB | implemented | K and V each provide 4 KiB ping-pong capacity; combined KV is 8 KiB |
| hardware nonlinear softmax, parallelism greater than 16 | implemented and verified | 32 score-scale/PWL-exp lanes accept one complete score column per cycle |
| AXI4 master/slave interfaces | partially integrated | AXI4-Lite control and AXI4 writeback are present; input uses an external 128-bit tile loader |
| FPGA deployment | planned | VCK190 integration/test plan exists; add bitstream and board reports when available |
| configurability bonus | partial | compile-time geometry plus runtime sequence/head/mode fields; verified point remains 32 x 32 x 64 |
| data-reuse bonus | implemented | local score/P, online row state, persistent O banks, ping-pong cache |
| quantization bonus | implemented and verified | INT8 Q/K/V and output, Q1.15 P/alpha, INT32 state |
| robust test-data bonus | verified | 20-run random/directed regression, 100% functional coverage, byte-exact model |
| real Transformer Attention | planned | Re10K and LLM board-test procedures are defined; measured results are pending |

## 2. Required Artifacts

| Artifact | Location | Status |
| --- | --- | --- |
| synthesizable RTL | `rtl/` | ready |
| module and UVM verification | `tb/module_tb/`, `tb/uvm/`, `tb/sim/` | ready |
| register/interface document | `docs/register_and_interface_reference.md` | ready |
| design/algorithm document | `docs/design_specification.md` | ready |
| PPA/optimization report | `docs/ppa_and_optimization.md` | ASIC baseline ready; FPGA rows pending |
| verification/coverage report | `docs/verification_report.md` | functional coverage complete; code coverage open |
| architecture/dataflow/pipeline figures | `figures/` | current assets ready |
| waveform panels | instructions in verification report Section 8 | screenshots pending |
| defense presentation | `ppt/defense_outline.md` | outline ready; deck pending |
| reproduction guide | `README.md` | ready |

## 3. Current Result Summary

| Metric | Current value |
| --- | ---: |
| 28 nm TT total cell area | 2,438,964.94 library units |
| target clock | 1.60 ns / 625 MHz logical-synthesis target |
| gate-SAIF dynamic power | 648.6251 mW |
| gate-SAIF leakage power | 9.8584 mW |
| gate-SAIF total power | 658.4835 mW |
| gate-SAIF net switching power | 18.1893 mW |
| functional regression | 20/20 passing |
| functional coverage | 100.00% |
| DUT code coverage | 85.28% |

## 4. Pre-Submission Gates

1. Rerun the complete 20-test regression on the final RTL revision and archive
   logs, VDB, URG report, command, and seeds.
2. Raise scoped DUT line/condition/toggle/branch coverage to the required target
   or provide an approved waiver list; 100% functional coverage does not replace
   the currently lower code-coverage score.
3. Add the FPGA AXI DMA/tile-loader adapter and state the external input boundary
   clearly in diagrams and software instructions.
4. Attach VCK190 post-route utilization/Fmax, DDR bandwidth, board power, and
   Re10K/LLM throughput evidence when available.
5. Capture the four waveform panels defined in the verification report.
6. Ensure every reported ASIC number retains the TT 0.9 V/25 C, 1.60 ns,
   pre-layout, workload, seed, and tool-version qualifiers.

## 5. Packaging Rule

Exclude generated VCS build trees, raw multi-gigabyte logs, and temporary EDA
work directories unless explicitly requested. Include source, scripts,
maintained documents, figures, concise report extracts, and hashes/manifests for
large external artifacts. Every claim in the package must match the final RTL.
