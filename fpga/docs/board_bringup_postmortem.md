# VCK190 Board Bring-Up Postmortem

## Scope

This document records the failures found while bringing the FLOPA attention kernel up on a
VCK190 with the Vitis 2023.1 common platform. It is the release checklist for every later RTL,
host, or platform rebuild.

The supported deployment unit is one matched set produced by the same `make runtime` build:

- `BOOT.BIN`: configures the common platform and the linked PL design during boot;
- `dit_fa.xclbin`: supplies XRT with matching kernel metadata and connectivity;
- `dit_fa_xrt_test`: uses the register map and kernel signatures from that build.

The existing PetaLinux kernel and root filesystem are reused. Standalone PDI, DTBO, kernel
module, WIC, and replacement rootfs flows are outside this supported path.

## Final Result

The current 170 MHz runtime records Git commit
`cce5158aa2fc699cc2ae2e25991d8627ebd75aac` and source-diff digest
`1e215eaf5568dd6cd9814041090673499102560e154c5f8a3fbccdbd6b11c434`. After installing the
matched runtime and rebooting, the deterministic `seq=64`, `head_dim=64`, four-compute-tile test
passed both before and after the full-model measurements:

```text
run  cycles  stalls  macs    completed_tiles  loaded_tiles
1    2942    0       524288  4                10
2    2942    0       524288  4                10
```

Both runs reported attention and loader version `0x00020000`, final status `0x0000000a`, error
zero, and byte-for-byte output PASS. XRT 2.15 reported the device Ready and loaded xclbin UUID
`5cfe912a-18e4-db14-5b72-5aace132ec56`.

The model throughput runner also completed with matching top-1 tokens between PS and PS+PL:

| Sequence | PS prefill | PS+PL prefill | PS Attention | PL callback | PL core |
| --- | ---: | ---: | ---: | ---: | ---: |
| 64 | 1582.633 ms | 1570.297 ms | 92.342 ms | 65.511 ms | 4.673 ms |
| 1024 | 30178.154 ms | 25476.343 ms | 6369.045 ms | 1648.075 ms | 679.180 ms |

The 1024-token speedups are `1.185x` for full prefill, `3.865x` for the complete Attention
callback, and `9.378x` for the PL core. The raw JSON and logs are under `fpga/model/results`.

The accelerator result is strong: the final seq64 PL interval is `19.762x` faster than isolated
PS Attention, and seq1024 remains `9.378x` faster. The primary bottleneck inside the current
Attention replacement is PS adaptation. At seq1024, quantization, packing, GQA expansion, and
output conversion add `968.89 ms` around a `679.18 ms` PL interval. These software stages are the
first optimization target; the separate non-Attention PS graph dominates the remaining complete
prefill time.

The historical full SmolLM2 qualification executed all 30 attention nodes and 270 Q heads
through PL. Local attention comparison against llama.cpp reported MAE `0.016733` and RMSE
`0.025836`; PS and PS+PL produced the same top-1 token. The result is numerically approximate,
not bit-exact. That observer-callback run also computed CPU attention and is not a throughput
result.

## Root Causes

### Runtime XRT Load Did Not Reconfigure PL

The VCK190 base common platform used here is a boot-time, non-DFX PL design. Calling
`device.load_xclbin()` or `xbutil program` updates XRT's view of the xclbin, but it does not
replace the full PL image already configured by `BOOT.BIN`.

This produced a deceptive state: XRT accepted the new metadata while requests still reached
the old hardware. A control-probe xclbin appeared to load, but direct register reads still
showed the previous tile mover's control and argument registers. Every KDS launch then waited
forever for a kernel completion that the booted design could not provide.

Corrective action: extract the PDI section from the linked xclbin, install it as the boot
partition's `BOOT.BIN`, install the xclbin and host from the same runtime package, and reboot.

### Mixed Build Artifacts

At one point the SD card booted an `attention_v1` PL image while the host loaded an
`attention_debug_v1` xclbin. The hardware topology and XRT metadata did not match. Symptoms
included AIE lock stalls, no PL progress, and host timeouts.

Corrective action: never copy individual artifacts from different build directories. Deploy
only the contents of one generated runtime directory after checking `SHA256SUMS`.

### Full PDI Runtime Programming Was Not Valid

`fpgautil` attempted to send the linked full-system PDI through FPGA Manager. PLM rejected it,
and FPGA Manager entered `firmware request error`. The command still returned success in one
test, so its exit status was not reliable evidence that configuration succeeded.

Corrective action: use the linked PDI through `BOOT.BIN` for this platform. When diagnosing any
runtime programming command, inspect FPGA Manager state and hardware registers as well as the
process return code.

### Stale Host and Xclbin Interfaces

Reference directories contained host and xclbin artifacts from different API revisions. The
prebuilt host addressed an AIE RTP through an obsolete graph-port alias. XRT 2023.1 required
the concrete graph path. Rebuilding the host corrected RTP lookup, but could not correct the
separate boot-image mismatch.

Corrective action: build the AArch64 host from the same source tree and toolchain as the linked
xclbin. An API correction is not considered a complete fix until control, data movement, and
output validation all pass.

### Forced Termination Left AIE State Allocated

Killing a hung AIE process left the partition requested. The next launch failed with
`Partition 1 already requested`.

Corrective action: avoid force-killing a live graph unless necessary. Reboot after this error;
do not treat subsequent failures as an independent kernel defect until the partition state is
clean.

### Host Resource Pressure Killed Vivado

A later Vitis implementation ended while Vivado was parsing platform XDC files. The last log
line came from `rdiArgs.sh` and reported that the Vivado process was `Killed`; no Vivado error
preceded it. At the same time another eight-job Vitis implementation was active and host swap
was effectively full. This is an external process termination, not a timing or RTL failure.

A retry reached post-route physical optimization and closed timing at
`WNS=0.001 ns`, `TNS=0`, `WHS=0.009 ns`, and `THS=0`. Vivado was then killed before it wrote the
final routed checkpoint. This second case is especially easy to misclassify: the Vitis wrapper
reported `impl ERROR`, but the last design result met both setup and hold constraints.

The final low-resource retry completed routing, checkpoint generation, PDI, XSA, xclbin, and
runtime packaging with the same `WNS=0.001 ns`, `TNS=0`, `WHS=0.009 ns`, and `THS=0`. Final route
status was zero failed, unrouted, or partially routed nets and zero node overlaps.

Corrective action: inspect the last implementation log, host memory, swap, load, and other
Vivado processes before changing constraints or RTL. Wait for competing jobs to finish, reduce
`JOBS`, limit Vivado's internal threads with `general.maxThreads`, and reuse the completed XO and
synthesis products when retrying. On this shared host, the low-resource retry uses two Vivado
threads and one Vitis implementation job.

### Vitis Bundled an Obsolete CMake

Sourcing Vitis 2023.1 prepended its bundled CMake 3.3.2 to `PATH`. The pinned llama.cpp model
runner requires CMake 3.16 or newer, so following the documented environment setup made model
configuration fail even though the system has a suitable CMake.

Corrective action: the AArch64 model build script explicitly invokes `/usr/bin/cmake`. The
PetaLinux toolchain file still selects the target compiler and sysroot, so this does not change
the generated ABI.

### Device-Image DRC Warnings Need Hardware Validation

The successful final build emitted repeated DSP `DPBU-4` clock activity warnings and UltraRAM
`REQPXA-*` attribute/address warnings while generating the device image. Vivado reported zero
DRC errors and produced the PDI, but successful generation alone does not prove those resources
operate correctly.

Corrective action: every new RTL build must pass the four-run deterministic workload after boot.
Require nonzero MAC and tile counters plus byte-for-byte output validation before running a model.
Do not waive or modify the RTL behind these warnings without an explicit RTL review.

### Constant Smoke Data Hid a Tile Packing Error

The first model integration packed Q, K, and V as conventional row-major `[row][feature]`
buffers. The RTL tile loader instead consumes one 256-bit cache word per feature, with 32 row
bytes in each word. Its required order is `[tile][feature][local_row]`.

The deterministic test did not expose this mismatch because Q and K were all zero and V was all
one. Those tensors are invariant under this permutation, so every output byte still passed. A
real model produced incorrect logits even though all kernels completed successfully.

Corrective action: host software must explicitly pack every 32-by-64 input tile in cache-word
order. Model qualification must compare PL attention output against a CPU reference with
nonuniform Q/K/V data. Constant-data smoke tests remain necessary for connectivity, but are not
sufficient for layout or numerical validation.

### Board and VCS Cycle Windows Were Different

The RTL `PERF_CYCLES` counter is enabled by `scheduler_busy`. It starts after START is accepted
and stops after final writeback completes. `PERF_STALL` includes scheduler load cycles without
both active cache owners and writeback backpressure.

The historical board smoke host started with only Q0 plus K0/V0 and K1/V1 loaded. After two
tiles completed, it serially submitted XRT tile-mover commands for Q1 and both reused K/V banks.
The scheduler stayed busy while waiting. For example, run 2 counted 38063 total cycles, 35153
stalls, and only 2910 non-stall cycles.

The VCS test preloaded both Q banks and both K/V banks before START. Its refill path used the
direct tile interface and could overlap producers, so an approximately 4000-cycle result
measured mostly computation. The board and VCS numbers therefore did not indicate a tenfold PE
slowdown; they measured different data-supply behavior.

The first replacement path submitted one 10-tile HLS mover command per Q head. The current path
submits one 90-tile mover command and one RTL `START` per attention node. It starts compute after
the first Q0/K0/V0, prefetches subsequent tiles, and lets cache ownership drive AXIS
backpressure. The llama.cpp override callback now excludes the attention node from CPU
execution. The dynamic mover extends the same protocol through 1024 tokens. Its loader/cache and
multi-head scheduler tests pass, both kernels package as XO files, and the matched runtime has now
been booted and measured on the board.

### ZOCL IRQ Warning Remains Non-Fatal

Boot still reports `IRQ index 63 not found` while probing ZOCL. XRT 2.15 nevertheless reports the
device Ready, both compute units open successfully, model runs complete, and the deterministic
test passes after the model workload. Treat the message as a residual platform warning, but keep
it in the release checklist in case a future platform image changes interrupt connectivity.

## Misleading Indicators

- A successful `device.load_xclbin()` is not proof that the PL image changed.
- A zero return code from `fpgautil` is not proof that FPGA Manager accepted the image.
- XRT finding a kernel by name is not proof that the booted registers implement that kernel.
- A corrected host API is not proof that host, xclbin, and boot image now match.
- One passing run is not sufficient; repeat the test and validate every output byte.
- A constant-data PASS is not proof that the host packs nonuniform tensor data correctly.
- `PERF_CYCLES` is not a compute-only counter when the scheduler waits for host-driven loads.
- A Vitis `impl ERROR` wrapper message is not proof of a design error; inspect `runme.log` for
  an external `Killed` termination before changing the design.

## Required Build and Release Gates

Run the build only after sourcing the repository environment:

```bash
source fpga/my_env.sh
make -C fpga/vitis runtime FREQ_HZ=170000000 JOBS=1
```

Before deployment, all of the following must be true:

1. Vitis link and implementation completed without errors.
2. Setup and hold timing constraints are met in the routed reports.
3. `BOOT.BIN`, `dit_fa.xclbin`, and the host are from one runtime directory.
4. `sha256sum -c SHA256SUMS` passes before and after transfer.
5. The current RTL Git commit and build frequency are recorded with the test result.
6. No previous host process owns an AIE partition or XRT context.
7. The SD card's working `BOOT.BIN` is backed up before replacement.

## Deployment and Recovery

Install the matched payload atomically on the boot partition:

```bash
sha256sum -c SHA256SUMS
sudo sh -c '\
    sd=/run/media/mmcblk0p1; \
    test -e "$sd/BOOT.previous.BIN" || cp "$sd/BOOT.BIN" "$sd/BOOT.previous.BIN"; \
    cp BOOT.BIN "$sd/BOOT.BIN.new"; \
    cp dit_fa.xclbin "$sd/dit_fa.xclbin"; \
    cp dit_fa_xrt_test "$sd/dit_fa_xrt_test"; \
    sync; mv "$sd/BOOT.BIN.new" "$sd/BOOT.BIN"; sync'
sudo reboot
```

After reboot, confirm the expected XRT device and run the deterministic test:

```bash
xbutil examine
sudo /run/media/mmcblk0p1/dit_fa_xrt_test \
    /run/media/mmcblk0p1/dit_fa.xclbin
```

Run it at least four times. Require `completed_tiles=4`, zero process exit status, and complete
output verification every time.

If the board does not boot or the test no longer reaches XRT, restore `BOOT.previous.BIN` from
another Linux system or from the board's recovery path. If an AIE partition remains allocated,
perform a clean reboot before further diagnosis.

## Diagnostic Order

Use this order to avoid confusing independent failures:

1. Confirm the SD `BOOT.BIN` hash matches the runtime package.
2. Confirm the board xclbin and host hashes match that same package.
3. Reboot and inspect XRT device discovery.
4. Read control and argument registers with a known probe if launch still hangs.
5. Check FPGA Manager and PLM logs when any programming path was attempted.
6. Check AIE partition ownership after interrupted runs.
7. Only then investigate RTL scheduling, AXI traffic, or numerical behavior.

Do not infer an RTL defect from an XRT timeout until the booted hardware identity has been
proven.
