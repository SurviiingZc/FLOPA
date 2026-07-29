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
