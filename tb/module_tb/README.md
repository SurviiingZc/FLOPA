# ABI-v3 验收说明（2026-10-17）

本目录原有测试包含 B0 固定 d、causal/Decode 与旧 O 布局假设，部分接口已过时。
新版只以 `make runtime-d-smoke` 的短 UVM 全链路与 `tb_runtime_arithmetic` 定向结果
作为本轮验收；旧版 21/23 项、历史 PASS 和覆盖率不得复用到新版。
具体矩阵、来源哈希与测试边界见 `docs/uvm_runtime_d.md`。

以下内容为历史 B0 module 测试说明。

# Directed Module Testbenches

The directed suite covers every active leaf or its nearest integration parent.
The current suite contains 23 Makefile jobs; several jobs exercise multiple
small helpers or both ASIC memory wrappers.

| RTL area | Testbenches |
| --- | --- |
| AXI and FPGA ingress | `tb_axi4_slave_if`, `tb_axi4_master_write`, `tb_axis_tile_loader` |
| Control/common | `tb_accel_regfile`, `tb_accel_scheduler`, `tb_perf_counter`, `tb_fa_clear_replica`, `tb_fa_signed_mult_pipe2`, `tb_fa_unsigned_mult_pipe2`, `tb_fixed_defs_smoke` |
| Compute | `tb_fsa_fused_array`, `tb_fsa_fused_pe`, `tb_fsa_stripe`, `tb_fsa_controller`, `tb_fsa_pv_engine`, `tb_score_scale_pipe` |
| Memory | `tb_banked_sram`, `tb_output_buffer`, `tb_pingpong_buffer`, `tb_qkv_tile_cache`, `tb_o_accumulator_bank`, `tb_asic_sram_backend` |
| Softmax | `tb_online_normalizer`, `tb_pwl_exp_unit`, `tb_reciprocal_lut` |
| Integration | `tb_attention_accel_top` |

Run the generic RTL suite with `make -C tb/sim run` and the foundry SRAM
functional models with `make -C tb/sim asic-sram`. All output is written below
`tb/sim/build/<test>/`.

FSDB dumping is enabled by default in every module testbench. The default file
is `<tb_name>.fsdb`; pass `+FSDB_FILE=<path>` to `simv` to override it. VCS
must be built with Verdi PLI/debug support (`-debug_access+all -kdb`).
