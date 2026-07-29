# Vitis/XRT Board Flow

This flow targets a VCK190 running the 2023.1 PetaLinux common platform. Vitis
links the DIT-FA RTL into `xilinx_vck190_base_202310_1` and emits a matched
`BOOT.BIN`, xclbin, and host. It does not build a WIC, kernel Image, or root
filesystem.

The design contains two kernels:

- `dit_fa`: user-managed RTL kernel containing the attention core, tile loader,
  AXI-Lite register map, and DDR write master;
- `dit_fa_tile_mover`: HLS kernel that reads XRT BO data from DDR and streams a
  complete runtime-sized, nine-Q-head schedule into `dit_fa` in one invocation.

For each attention node in the `seq=32..1024`, `head_dim=64` path, software
expands model 9Q/3KV GQA into the accelerator's 9Q/9KV MHA interface. It starts
the mover once and sends one RTL `START` after the first `Q0/K0/V0` commits.
The mover then traverses all heads and tiles and refills released banks under AXIS
backpressure. See
[`../docs/pingpong_streaming.md`](../docs/pingpong_streaming.md) for the protocol.

## Build

```bash
source fpga/my_env.sh
make -C fpga/vitis runtime FREQ_HZ=170000000 JOBS=1
```

Useful incremental targets are `rtl-xo`, `mover-xo`, `xo`, `link`, `xclbin`,
`host`, `inspect`, and `runtime`. Vitis first links a Versal XSA, then packages
the XRT xclbin and boot-time PL PDI. All generated files stay under
`fpga/vitis/build/`.

The deployable directory is `fpga/vitis/build/runtime/`. Generated archives and intermediate
link products are intentionally not retained after the runtime directory passes its checksums.

The verified 170 MHz build meets all timing constraints with setup WNS/TNS of
`0.000/0.000 ns` and hold WHS/THS of `0.010/0.000 ns`. Treat it as the board
functionality baseline, not as evidence of frequency margin. The routed report
is `build/reports/release-20260729/timing_summary_routed.rpt`.

## Board Run

Copy the runtime directory to PetaLinux. Follow its `README.md` to install the
matched `BOOT.BIN`, xclbin, and host on the SD boot partition, then reboot and
run:

```bash
sudo /run/media/mmcblk0p1/dit_fa_xrt_test \
    /run/media/mmcblk0p1/dit_fa.xclbin
```

Expected final output includes:

```text
Completed tiles: 4
Loaded tiles: 10
PASS: seq=64, head_dim=64, four tiles
```

The final board run completed this test twice with `2942` cycles, zero stall cycles, four
completed tiles, ten loaded tiles, and zero errors. The matched full-model test measured:

| Sequence | PS Attention | PL callback | PL interval | Core speedup |
| --- | ---: | ---: | ---: | ---: |
| 64 | 92.342 ms | 65.511 ms | 4.673 ms | 19.762x |
| 1024 | 6369.045 ms | 1648.075 ms | 679.180 ms | 9.378x |

The accelerator is substantially faster than the PS implementation. The main remaining
Attention-integration bottleneck is PS quantization, packing, GQA expansion, and output
conversion; optimizing those stages is the next priority.

No standalone `.pdi`, `.dtbo`, kernel module, WIC, or rootfs image is needed.
This base platform configures the linked PL design from `BOOT.BIN`; runtime XRT
loads the matching xclbin metadata but does not replace an already booted full
PL PDI.
