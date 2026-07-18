# Directed Module Testbenches

Every synthesizable RTL module is covered by a self-checking directed testbench.
The two ASIC SRAM composition wrappers are covered together by
`memory/tb_asic_sram_backend.sv`, because both require the foundry functional
macro model and the `ATTN_ASIC` build define.

| RTL area | Testbench coverage |
| --- | --- |
| AXI | `tb_axi4_slave_if`, `tb_axi4_master_write` |
| Control | `tb_accel_regfile`, `tb_accel_scheduler`, `tb_perf_counter` |
| Compute | `tb_os_fsa_pe`, `tb_os_fsa_array`, `tb_os_fsa_controller`, `tb_scale_requant_unit`, `tb_qk_engine`, `tb_pv_engine` |
| Memory | `tb_banked_sram`, `tb_bram_buffer`, `tb_output_buffer`, `tb_pingpong_buffer`, `tb_qkv_tile_cache`, `tb_stream_fifo`, `tb_uram_bank`, `tb_asic_sram_backend` |
| Softmax | `tb_block_lse_update`, `tb_causal_mask`, `tb_online_normalizer`, `tb_pwl_exp_unit`, `tb_reciprocal_lut`, `tb_row_broadcast`, `tb_row_reduce_unit`, `tb_softmax_engine` |
| Integration | `tb_attention_accel_top` |

Run the generic RTL suite with `make -C tb/sim run`. Run the foundry SRAM
suite separately with `make -C tb/sim asic-sram`.

All simulator output is written below `tb/sim/build/<test>/`.

Every module TB enables FSDB dumping by default. The default waveform name is
`<tb_name>.fsdb`; pass `+FSDB_FILE=<path>` to `simv` to override it. VCS must
be compiled with Verdi PLI support (`-debug_access+all -kdb`).
