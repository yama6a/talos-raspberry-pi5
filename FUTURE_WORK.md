# Future work

The goal of this repo is to stop existing. One upstream gap keeps it alive. When it closes, a Talos release
plus an Image Factory schematic ID replaces everything here. The evidence is in [docs/upstream.md](docs/upstream.md).

## The blocker

- The official `rpi_5` overlay ships a U-Boot with no `brcm,bcm2712-pcie` driver, so U-Boot cannot read the
  NVMe it was loaded from.
- Upstream U-Boot has the driver from v2026.07. The overlay has not moved there, because its own NVMe patches
  do not apply to it.
- Everything else this build does is obsolete, a consequence of the custom kernel, or config anyone can set.

## Why test

- A pass on your board lets you drop the custom kernel build for a schematic ID.
- The overlay's U-Boot bump ([#33](https://github.com/siderolabs/sbc-raspberrypi/pull/33)) waits on
  rebasing the NVMe patches. The maintainer's stated blocker on
  [#96](https://github.com/siderolabs/sbc-raspberrypi/issues/96) is test reports on both D0 and D1 BCM2712
  stepping. A tested report on either stepping is the most useful thing a reader can contribute.

## Test plan

The kernel question and the U-Boot question are separate. Test the kernel first, and do not start by fixing
U-Boot.

### Step 1: prove the vanilla kernel path on SD

The official U-Boot has `brcm,bcm2712-sdhci`, so it can boot from SD. That tests the vanilla kernel, the
vanilla DTBs and the vanilla RP1 ethernet path without U-Boot's PCIe.

1. Build a factory image from a schematic with the official overlay, both extensions and the radios off:

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

   The official `config.txt` sets `enable_uart=0` under `[pi5]`. For a serial console, replace it whole
   with `configTxt`. Appending does not work.

2. Write it to an SD card with `dd` and boot a Pi 5 from it. Attach a USB-UART if you have one.
3. Check that `end0` comes up and the node answers on the Talos API in maintenance mode:

   ```bash
   arp -n <ip>                              # not "(incomplete)"
   talosctl -n <ip> get links end0 --insecure
   talosctl -n <ip> get disks --insecure    # nvme0n1 visible to Linux, not the same as to U-Boot
   ```

If `end0` does not come up, the move off this repo is blocked, and the test cost nothing. Post the console
output on the Pi 5 ethernet issues. Nobody in those threads has a console.

### Step 2: fix U-Boot, only if step 1 passed

1. Fork `siderolabs/sbc-raspberrypi`. Set `uboot_version` in `Pkgfile` to v2026.07 or later.
2. Rebase `artifacts/u-boot/patches/0005` to `0008` onto it. From v2026.10, first try dropping `0006` and
   `0007`, because upstream `09b1c0f9` does the same address translation.
3. Build an image with the stock Talos imager and that overlay, with no kernel build:

   ```
   ghcr.io/siderolabs/imager:<talos version>  rpi5 --arch arm64 \
     --overlay-name=rpi_5 --overlay-image=<your overlay fork> \
     --system-extension-image=... --system-extension-image=...
   ```

4. Write it to the NVMe, boot from it, and run the checks from step 1.

`installers/rpi_5` keeps copying `rpi_generic/u-boot.bin`. That binary is the one that gains the driver.

### Step 3: report the result

Name the BCM2712 stepping. It separates two failures:

- **No NVMe boot at all**: `brcm,bcm2712-pcie` is missing. Every stepping.
- **A hang at the U-Boot splash, or a kernel panic in `brcmuart_init`**: reported only on D0, which
  [#97](https://github.com/siderolabs/sbc-raspberrypi/pull/97) identifies as board revision `e04171`.

Quote the revision code as printed, and do not map it to a stepping yourself:

```bash
talosctl -n <ip> dmesg | grep -i 'machine model'   # Raspberry Pi 5 Model B Rev <x.y>
grep Revision /proc/cpuinfo                        # the revision code, for example e04171
```

Any Talos release at or above the overlay's `MinVersion` works. Image Factory offers `rpi_5` only from there.

Post on [#96](https://github.com/siderolabs/sbc-raspberrypi/issues/96) or
[#33](https://github.com/siderolabs/sbc-raspberrypi/pull/33) with the revision code, the U-Boot version, SD
or NVMe, and the Talos version.

## What goes when this lands

- the kernel build, and with it REBASE 1, REBASE 2 and REBASE 3
- `kernel/pi5-rpi.fragment`, `kernel/patch-skip.txt` and the pkgs patch gating
- `lib/resolve_inputs.sh`
- the local registry, the standalone buildx builder and the Dockerfile frontend mirror
- `BUILD_KEY` and the `.cache` tree
- `build/Makefile.talos`

What stays: publishing, tagging, the SBOM and provenance, and `lib/validate.sh`. If an overlay fork is the
answer, this repo becomes that fork. If it all lands upstream, a consumer pins a schematic ID and a Talos
version, and this repo gets archived.

## Smaller items

- **Console arg.** The build passes `console=ttyAMA0,115200`. The Pi 5 debug UART is `ttyAMA10`, which the
  official overlay uses. Ours is probably wrong.
- **`BLK_DEV_NVME=y`.** Stock builds it as a module and boots NVMe roots that way. Building it in is a choice,
  and it is part of why REBASE 2 exists. Revisit it if REBASE 2 gets in the way.
- **No hardware test in CI.** Offline validation cannot prove the boot chain, and a boot chain fault is what
  took a node down here. A self-hosted runner on a spare board that flashes and boots each release would
  catch a U-Boot regression before a live node does.
