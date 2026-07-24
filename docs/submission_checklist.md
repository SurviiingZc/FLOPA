# Submission Checklist and Requirement Traceability

This checklist prevents a design feature, a planned feature, and a measured
result from being presented as the same thing. "Implemented" means present in
the checked RTL; "verified" means covered by the documented passing regression;
"measured" requires an implementation or board report.

## 1. Competition Requirement Map

| Requirement | Current status | Evidence | Submission action |
| --- | --- | --- | --- |
| Systolic matrix computation, array larger than 16 x 16 | implemented and verified | 32 x 32 PE array in `rtl/compute/fsa_fused_array.v`; UVM/module TBs | include Figure 1 and design Sections 1/5 |
| KV cache capacity greater than 4 KiB | implemented | K and V each have 4 KiB ping-pong capacity; combined KV is 8 KiB | include storage table and cache organization |
| Hardware softmax/nonlinear function, parallelism greater than 16 | implemented | 32 parallel score-scale/PWL-exp lanes, online recurrence, reciprocal normalizer | include the 32-lane dataflow and Q1.15/PWL numerical format |
| AXI4 master/slave interface | partial | AXI4-Lite slave and 128-bit AXI4 write master implemented | state clearly that DDR input needs external DMA/AXI adapter |
| FPGA platform deployment | planned | VCK190 target and integration plan | attach bitstream, Vivado reports, and board log when complete |
| Configurability bonus | partial | compile-time parameters plus runtime sequence/head/mode registers | do not overstate fixed tile/head-dimension restrictions |
| Data-reuse bonus | implemented | P-stationary PE state, local row state, persistent O banks, ping-pong cache | include Figure 1/2 and PPA optimization table |
| Quantization bonus | implemented | INT8 Q/K/V, Q1.15 P/alpha, INT32 accumulation, INT8 output | include exact fixed-point table and numerical test cases |
| Robust test data bonus | partial/verified | random, corner, causal, saturation, decode, backpressure, two-tile UVM tests | attach the 15-test log and coverage report |
| Real Transformer Attention and data | planned | Re10K and SmolLM2/VCK190 planning materials | include only after model inputs, outputs, and E2E measurements exist |

## 2. Required Submission Artifacts

| Artifact | Current file or source | Status |
| --- | --- | --- |
| Synthesizable RTL | `rtl/` | ready for source submission |
| Simulation/UVM environment | `tb/module_tb/`, `tb/uvm/`, `tb/sim/` | ready; retain VCS logs/VDB separately if allowed |
| Register map and interface explanation | `docs/register_and_interface_reference.md` | ready |
| Storage and architecture explanation | `docs/design_specification.md` | ready |
| Algorithm, buffers, and detailed design | `docs/design_specification.md` | ready |
| Resource/power/performance analysis | `docs/ppa_and_optimization.md` | baseline only; update after FPGA/post-layout results |
| Optimization explanation | `docs/ppa_and_optimization.md` | ready with open items stated |
| Verification plan/testcase/coverage report | `docs/verification_report.md` | ready; coverage closure still open |
| Architecture/pipeline figures | `figures/architecture/`, `figures/pipeline/` | ready in PDF/SVG/PNG/TIFF |
| Waveform figures | capture instructions in `docs/verification_report.md` Section 7 | pending screenshots |
| Defense slide deck | `ppt/defense_outline.md` | pending; create the required presentation from this outline |
| Root reproduction guide | `README.md` | ready |

## 3. Pre-Submission Gates

1. **Functional gate:** rerun the 15-test UVM regression after the final RTL
   revision. Archive the exact command, test log, VDB, and `urg` output.
2. **Softmax parallelism gate:** retain the 32-lane score-scale/PWL-exp source
   and architecture evidence showing that one 32-element score column is
   evaluated in parallel each cycle.
3. **Interface gate:** include the AXI DMA/tile-loader wrapper in the FPGA build
   or describe the external integration boundary explicitly in the submission.
4. **FPGA gate:** attach post-route utilization, timing, clocking, memory/DSP
   inference, bandwidth, and board-power evidence. Do not substitute ASIC
   logical synthesis for a VCK190 result.
5. **Coverage gate:** reach the required targets or submit an approved,
   traceable waiver list. Current 80.79% DUT code and 81.44% functional
   coverage do not satisfy a 95%/100% requirement.
6. **PPA gate:** replace all FPGA `TBD` entries and qualify ASIC estimates as
   pre-layout until CTS/routed min/max STA are complete.
7. **Presentation gate:** add the architecture figure, pipeline figure, PPA
   table, verification table, and the four waveform panels requested in the
   verification report to the defense slides.

## 4. Final Packaging Rule

Exclude generated VCS build directories, multi-gigabyte mapped netlists/SDF,
and raw large tensor data unless the contest explicitly asks for them. Include
reproduction scripts, report summaries, file hashes/manifests for large data,
and links or paths to externally retained artifacts. The final package must be
internally consistent: every figure, number, and supported-mode statement must
match the final RTL revision.
