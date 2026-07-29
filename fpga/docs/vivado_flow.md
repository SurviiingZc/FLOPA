# VCK190 Standalone Vivado QoR Flow

This flow is retained for RTL synthesis and implementation analysis. Its PDI
and XSA are not deployment artifacts for the existing PetaLinux common image.
Board deployment must use the Vitis/XRT flow in `fpga/vitis/README.md`.

The final deployed Vitis implementation runs at 170 MHz with setup WNS/TNS of
`0.000/0.000 ns` and hold WHS/THS of `0.010/0.000 ns`. Its authoritative timing report is
`fpga/vitis/build/reports/release-20260729/timing_summary_routed.rpt`.

## Hardware topology

The first board design uses the VCK190 board part
`xilinx.com:vck190:part0:3.2`, which targets `xcvc1902-vsva2197-2MP-e-S`
and declares compatibility with the VCK190 Rev B02 board.

```text
Cortex-A72 / CIPS
    |-- NoC M00 -> SmartConnect -> AXI DMA control
    |                         |-> attention control
    |                         `-> tile-loader control
    |
    |-- DDR4/NoC -> AXI DMA MM2S -> AXIS tile loader -> Q/K/V cache
    |
    `-- attention AXI4 write master -> NoC -> DDR4 output buffer
```

The AXI DMA is simple-mode, MM2S-only, and 128 bits wide. Software packs each
32-by-64 INT8 tile in cache order before starting a 2048-byte DMA transfer.
The adapter converts 128 stream beats into 64 256-bit cache words and emits
the matching Q, K, or V bank commit.

## Address map

| Base address | Range | Target |
| --- | --- | --- |
| `0x0000_0000` | 2 GiB | DDR4 low window for DMA input and output writeback |
| `0x0201_0000_0000` | 64 KiB | AXI DMA registers |
| `0x0201_0001_0000` | 64 KiB | attention accelerator registers |
| `0x0201_0002_0000` | 64 KiB | tile-loader registers |

The standalone build exports its address table to `address_map.csv` for debug.

## Tile-loader registers

| Offset | Name | Description |
| --- | --- | --- |
| `0x00` | CONTROL | bit 0 start, bit 1 abort, bit 2 clear done, bit 3 clear error |
| `0x04` | STATUS | bit 0 busy, bit 1 done, bit 2 error, bit 3 idle |
| `0x08` | DESCRIPTOR | bits 1:0 kind (`Q=0`, `K=1`, `V=2`), bit 2 bank |
| `0x0c` | BEATS | number of 128-bit beats; normal tile value is 128 |
| `0x10` | PROGRESS | accepted beat count |
| `0x14` | VERSION | adapter interface version |

Every transfer must use full `TKEEP`, an even beat count, and `TLAST` exactly
on the configured final beat. A protocol violation raises the loader IRQ and
does not commit the partially written cache bank.

## Build

From the repository root:

```bash
source fpga/my_env.sh
make -C fpga clean
make -C fpga impl JOBS=2 FREQ_MHZ=170
```

The `impl` flow generates synthesis reports first and continues only when setup
WNS meets `SYNTH_MIN_WNS` and DSP usage fits the device. It accepts the final
PDI and XSA only when post-route setup and hold both have non-negative slack.
Post-synthesis hold is reported but is not a gate because placement and routing
must repair minimum-delay paths.

To stop after the 170 MHz synthesis baseline, use:

```bash
make -C fpga clean
make -C fpga synth JOBS=2 FREQ_MHZ=170
```

Generated reports are under `fpga/vivado/build/reports`. The PDI and XSA are
copied to `fpga/vivado/build/output` after implementation. They are standalone
QoR/debug outputs and must not be loaded over the PetaLinux common platform.
`flow_summary.txt` records the synthesis gate and final timing margins. Separate
setup and hold violation reports retain up to 2000 detailed paths.

The default clock request is 170 MHz. Raise `FREQ_MHZ` explicitly after reviewing
the post-route margin; 185, 200, 250, 300, and 312.5 MHz are candidate steps and
do not require an RTL change.

When implementation is already complete in the GUI, export the current routed
design without deleting the project or rerunning synthesis:

```bash
make -C fpga export-hw JOBS=2
```

This resumes `impl_1` only through `write_device_image`, checks final setup and
hold slack, and writes `dit_fa_vck190.xsa` plus the generated PDI under
`fpga/vivado/build/output`.

## Frequency Plan After Board Bring-Up

The released 170 MHz Vitis implementation meets setup and hold with setup WNS of `0.000 ns` and
hold WHS of `0.010 ns`. Keep its matched runtime as the functional board baseline; do not claim
additional frequency margin from this result.

The worst setup paths are entirely inside `u_fused_array`, from shared row-state
launch registers into PE accumulators. They use 17 to 19 logic levels and spend
roughly 52% to 60% of the data-path delay in routing. CIPS, NoC, AXI DMA, and
the board wrapper are not data-path endpoints for these violations. A large
monolithic Pblock is therefore not the next optimization step.

For future frequency work, use this order:

1. Record cycles, stalls, MACs, and DDR/DMA behavior at 170 MHz.
2. Try 175 MHz, then 180 MHz with several implementation seeds. Keep a result
   only when post-route setup and hold both pass with at least 0.20 ns setup
   margin; otherwise retain the 170 MHz image.
3. For a larger increase, change the PE microarchitecture rather than the
   wrapper: register or replicate the row-state fanout per stripe, and split
   the DSP-to-carry-chain accumulator boundary. Both alter cycle timing and
   require RTL verification before implementation.

The reported source-to-destination placement spans multiple PE rows and has
long fanout. Any future physical constraint should be scoped to a single stripe
and compared against an unconstrained seed. Do not reapply the earlier global
PE Pblocks, because they worsened these routing-dominated paths.
