# DIT-FA XRT Runtime

This directory is the complete board payload. The VCK190 must use the included
`BOOT.BIN`, because this non-DFX common platform configures the linked PL design
at boot. The existing PetaLinux `Image` and root filesystem remain unchanged.

`BUILD_INFO` records the RTL Git commit, requested kernel frequency, platform,
and toolchain. It is covered by `SHA256SUMS`.

Check the payload, install it on the SD boot partition, and reboot:

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

After the board returns, execute the deterministic four-tile test:

```bash
sudo /run/media/mmcblk0p1/dit_fa_xrt_test \
    /run/media/mmcblk0p1/dit_fa.xclbin
```

The test uses `seq=64`, `head_dim=64`, one head, and four compute tiles. Q and K
are zero, V is one, and every output byte must be one. The host also requires
the XRT buffer device address to fit below 4 GiB because the current RTL output
write address is 32 bits. A successful run reports four compute tiles and ten
loaded memory tiles.
