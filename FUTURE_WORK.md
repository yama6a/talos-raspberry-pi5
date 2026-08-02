# Future work

The goal of this repo is to stop existing. One upstream gap keeps it alive; when that closes, a Talos release
plus an Image Factory schematic ID replaces everything here.

Background and evidence for all of this: [docs/upstream.md](docs/upstream.md).

## The only blocker

The official `rpi_5` overlay ships U-Boot built from `rpi_arm64_defconfig`, which has no
`brcm,bcm2712-pcie` driver, so U-Boot cannot read the NVMe it was loaded from. Everything else this build does
is either obsolete, a consequence of building a custom kernel, or configuration available to anyone.

## Test plan

The two unknowns are separable, and that is the whole trick. Do NOT start by fixing U-Boot.

### Step 1: prove the vanilla kernel path, on SD, on the spare board

The official U-Boot implements `brcm,bcm2712-sdhci`, so it CAN boot from an SD card. That exercises the
vanilla kernel, the vanilla DTBs and the vanilla RP1 ethernet path without touching U-Boot at all.

1. Build a factory image from a schematic with the official overlay, both extensions, radios off and a console
   forced on:

   ```yaml
   overlay:
     name: rpi_5
     image: siderolabs/sbc-raspberrypi
     options:
       configTxtAppend: |
         dtoverlay=disable-wifi
         dtoverlay=disable-bt
   customization:
     systemExtensions:
       officialExtensions:
         - siderolabs/iscsi-tools
         - siderolabs/util-linux-tools
   ```

   The official `config.txt` sets `enable_uart=0` under `[pi5]`, so to get a serial console you have to replace
   it wholesale with `configTxt`, not append to it.

2. `dd` it to an SD card and boot the spare 4th board with it. Attach a USB-UART.
3. The only question that matters: does `end0` come up, and does the node answer on the Talos API in
   maintenance mode?

   ```bash
   arp -n <ip>                              # not "(incomplete)"
   talosctl -n <ip> get links end0 --insecure
   talosctl -n <ip> get disks --insecure    # nvme0n1 visible to LINUX, which is not the same as to U-Boot
   ```

This costs an SD card and half an hour, cannot break anything, and answers the expensive question. The
existing EEPROM `BOOT_ORDER` already tries SD before NVMe, and a node in maintenance mode writes nothing, so
even on a live node pulling the card returns it to the NVMe install. Use the spare anyway.

If `end0` does NOT come up, the migration is dead for now and you have spent nothing. Post the console output
on the Pi 5 ethernet issues; nobody in those threads has a console, which is likely why they are stuck.

### Step 2: only if step 1 passed, fix U-Boot

Fork `siderolabs/sbc-raspberrypi` and cherry-pick the U-Boot patch set from the open PR that adds BCM2712 and
RP1 support to the `rpi_arm64` build. Two changes:

- add the patches plus a build step producing `arm64/u-boot/rpi_5/u-boot.bin`
- point `installers/rpi_5/src/main.go` at that path instead of `rpi_generic`

Then build an image with the stock Talos imager and that overlay, with **no kernel build**:

```
ghcr.io/siderolabs/imager:<talos version>  rpi5 --arch arm64 \
  --overlay-name=rpi_5 --overlay-image=<your overlay fork> \
  --system-extension-image=... --system-extension-image=...
```

Flash the spare, boot from NVMe, run the same checks as step 1.

### Step 3: help it land upstream

The maintainer's stated blocker on the U-Boot issue is community testers on both D0 and D1 BCM2712 stepping,
not the code. The cluster's boards report `Raspberry Pi 5 Model B Rev 1.1`. Reporting a tested result on both
steppings is the single highest-value contribution available here, and it is the only path that ends with no
repo to maintain.

## What gets deleted when this lands

Roughly 80% of this repo, and the build goes from tens of minutes to a couple:

- the whole kernel build, and with it REBASE 1, REBASE 2 and REBASE 3
- `kernel/pi5-rpi.fragment` and `kernel/patch-skip.txt`, plus the pkgs patch dry-run gating
- `lib/resolve_inputs.sh`, since there is no kernel version to derive or `raspberrypi/firmware` to walk
- the local registry container, the standalone buildx builder, and the Dockerfile-frontend mirror
- `BUILD_KEY` and the multi-GB `.cache` tree
- `build/Makefile.talos`, absorbed from the community builder

What survives, in some form: publishing, tagging, the SBOM and provenance, and `validate.sh`. If the overlay
fork route is taken rather than full upstreaming, that fork is what this repo becomes.

If it lands fully upstream, the cluster repo pins a schematic ID and a Talos version, and this repo is
archived.

## Smaller items, independent of the above

- **Console arg.** This build passes `console=ttyAMA0,115200`; the Pi 5 debug UART is `ttyAMA10`, which is what
  the official overlay uses. Ours is probably wrong and nobody has needed it badly enough to notice.
- **`BLK_DEV_NVME=y`.** Stock ships it as a module and boots NVMe roots everywhere that way. Building it in is
  a choice, and it is part of why the module list needs filtering. Revisit if REBASE 2 ever becomes annoying.
- **No hardware test in CI.** Offline validation cannot prove the Pi 5 boot chain, which is exactly the class of
  bug that took the node down. A self-hosted runner on the spare board that flashes and boots each release
  would close that, and is the only way to catch a U-Boot regression before it reaches a live node.
