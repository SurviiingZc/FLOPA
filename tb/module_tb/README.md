# Directed Module Testbenches

Every retained RTL module is covered either by a self-checking directed
testbench or by the nearest parent integration test. Fused PE/delay-line logic
is covered through `tb_fsa_fused_array`; the FSA stream wrappers are covered
through `tb_attention_accel_top`.
The two ASIC SRAM composition wrappers are covered together by
`memory/tb_asic_sram_backend.sv`, because both require the foundry functional
macro model and the `ATTN_ASIC` build define.

| RTL area | Testbench coverage |
| --- | --- |
| AXI | `tb_axi4_slave_if`, `tb_axi4_master_write` |
| Control | `tb_accel_regfile`, `tb_accel_scheduler`, `tb_perf_counter` |
| Compute | `tb_fsa_fused_array`, `tb_fsa_stripe`, `tb_fsa_controller`, `tb_scale_requant_unit` |
| Memory | `tb_banked_sram`, `tb_bram_buffer`, `tb_output_buffer`, `tb_pingpong_buffer`, `tb_qkv_tile_cache`, `tb_stream_fifo`, `tb_uram_bank`, `tb_asic_sram_backend` |
| Softmax | `tb_online_normalizer`, `tb_pwl_exp_unit`, `tb_reciprocal_lut` |
| Integration | `tb_attention_accel_top` |

Run the generic RTL suite with `make -C tb/sim run`. Run the foundry SRAM
suite separately with `make -C tb/sim asic-sram`.

All simulator output is written below `tb/sim/build/<test>/`.

Every module TB enables FSDB dumping by default. The default waveform name is
`<tb_name>.fsdb`; pass `+FSDB_FILE=<path>` to `simv` to override it. VCS must
be compiled with Verdi PLI support (`-debug_access+all -kdb`).
