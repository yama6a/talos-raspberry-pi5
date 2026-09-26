# Talos Linux for the Raspberry Pi 5

Current Talos on a `raspberrypi/linux` kernel, so the Pi 5's onboard networking, USB and GPIO work. Every
release ships a raw disk image for the first install and an installer image for upgrades.

## Why this exists

- Talos publishes no Pi 5 image, and the official `rpi_5` overlay cannot boot one from NVMe.
- Its U-Boot has no BCM2712 PCIe driver, so it cannot read the disk the firmware loaded it from. Boot stops
  before Linux starts.
- This build pairs a `raspberrypi/linux` kernel with the community overlay, whose Pi 5 U-Boot has that driver.
- Upstream U-Boot has the driver too. The official overlay does not build that U-Boot yet, so the official
  image stays SD-only. Closing that gap is upstream's job.

Booting from an SD card? The official overlay may work for you and costs far less maintenance. Use it. The
audit of what upstream has caught up on is in [docs/upstream.md](docs/upstream.md), and the plan to retire this
repo is in [FUTURE_WORK.md](FUTURE_WORK.md).

## What is in the image

- Talos on a `raspberrypi/linux` kernel, built with the same clang, ThinLTO and hardened config as stock Talos.
- RP1 and BCM2712 south-bridge drivers, so the wired NIC, USB and GPIO work.
- 4K kernel pages.
- NVMe and PCIe built in.
- The Pi 5 boot chain on the EFI partition: U-Boot, `config.txt`, `bcm2712-rpi-5-b.dtb` and overlays.
- Wi-Fi and Bluetooth off, with `dtoverlay=disable-wifi` and `dtoverlay=disable-bt`.
- Two system extensions: `iscsi-tools`, because Longhorn needs `iscsid`, and `util-linux-tools` for `fstrim`.

## Install

1. Set the Pi 5 bootloader to try NVMe. Flash the EEPROM with `BOOT_ORDER`, and for a third-party PCIe board
   with no ID EEPROM also `PCIE_PROBE=1`.
2. Download `metal-arm64-rpi5.raw.xz` from a [release](../../releases), and write it to the boot disk:

   ```
   xz -d metal-arm64-rpi5.raw.xz
   sudo dd if=metal-arm64-rpi5.raw of=/dev/<disk> bs=4M status=progress conv=fsync
   ```

   Use the whole device, not a partition. Find it with `lsblk` on Linux or `diskutil list` on macOS.

3. Slot the NVMe drive in and power on with no SD card. The Pi boots into Talos maintenance mode.
4. Configure it as usual, with `talosctl gen config` and `talosctl apply-config`.

## Upgrade

```
talosctl upgrade --nodes <node-ip> --image ghcr.io/yama6a/talos-raspberry-pi5:vX.Y.Z-N
```

- No reflash. Talos upgrades are atomic A/B with rollback.
- Pin `vX.Y.Z@sha256:...` and let Renovate bump the digest. The tag scheme is in
  [docs/releases.md](docs/releases.md).
- Before moving to a new Talos minor, read [docs/upgrade.md](docs/upgrade.md).

## Build it yourself

```
make preflight  # checkouts, pkg.yaml rewrites and the overlay port, no Docker
make build      # about 40 min cold on an M2 Pro, about 8 with a kernel cache hit
make validate   # partition layout, Pi 5 boot bits, kernel label, baked extensions
```

- Needs an arm64 host, Docker with about 60 GB free, GNU make 4 or later, and
  `git curl jq go python3 perl crane`. See the [build runbook](docs/runbooks/build.md).
- To build a variant, edit [`versions.env`](versions.env) or [`kernel/pi5-rpi.fragment`](kernel/pi5-rpi.fragment).
- A fork publishes to its own GHCR namespace with no further edits.

## Known gaps

- **USB boot does not work.** USB comes up only once Linux has, not in U-Boot.
- **One board tested.** Only a Raspberry Pi 5 (8 GB) with a 52Pi RS-P11 NVMe board. The CM5 and other
  carriers are plausible but unverified.
- **No hardware test in CI.** Validation is offline: layout, boot bits, kernel label, extensions. First boot
  on real hardware is on you.

## Docs

| Doc | Holds |
|---|---|
| [docs/build.md](docs/build.md) | how the build works and why: the three rebases, caches, patch gating |
| [docs/kernel.md](docs/kernel.md) | why a fork kernel, and why its version is derived, never pinned |
| [docs/releases.md](docs/releases.md) | tag scheme, build revisions, what triggers a build |
| [docs/upgrade.md](docs/upgrade.md) | what a Talos minor can move, and upgraded versus fresh nodes |
| [docs/upstream.md](docs/upstream.md) | what upstream has caught up on, what has not, and the evidence |
| [FUTURE_WORK.md](FUTURE_WORK.md) | how to retire this repo, and the test plan to get there |

Procedures live in [docs/runbooks/](docs/runbooks): building, upgrading Talos, and verifying or cutting a
release.

## Credits

This rebases work other people did first.

- [talos-rpi5/talos-builder](https://github.com/talos-rpi5/talos-builder) is the reference community build.
  `build/Makefile.talos` adapts its Makefile. For a prebuilt Pi 5 image with less machinery, start there.
- [talos-rpi5/sbc-raspberrypi5](https://github.com/talos-rpi5/sbc-raspberrypi5) is the overlay that puts the
  Pi 5 boot chain on the EFI partition. [talos-rpi5/u-boot](https://github.com/talos-rpi5/u-boot) is the
  U-Boot fork behind it. This build uses both as they are.
- [siderolabs/talos](https://github.com/siderolabs/talos), [siderolabs/pkgs](https://github.com/siderolabs/pkgs)
  and [siderolabs/extensions](https://github.com/siderolabs/extensions) are Talos, its kernel recipe and the
  system extensions.
- [siderolabs/sbc-raspberrypi](https://github.com/siderolabs/sbc-raspberrypi) is the official overlay,
  including `rpi_5`.
- [raspberrypi/linux](https://github.com/raspberrypi/linux) is the kernel fork with the RP1 and BCM2712
  drivers. [raspberrypi/firmware](https://github.com/raspberrypi/firmware) maps a kernel version to a commit.
- Two write-ups made the first build possible:
  [kcirtap.io](https://kcirtap.io/posts/talos-rpi5-custom-kernel-build/) and
  [rcwz.pl](https://rcwz.pl/2025-10-04-installing-talos-on-raspberry-pi-5/).

## License

The code here is [MIT](LICENSE). The published images combine GPL-2.0, MPL-2.0 and other works, each under its
own license. [NOTICE](NOTICE) has the breakdown and the source pointer.
