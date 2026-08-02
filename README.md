# Talos Linux for the Raspberry Pi 5

Current Talos, built on a `raspberrypi/linux` kernel so the Pi 5's onboard networking, USB and GPIO work.

Every release ships a raw disk image for the first install and an installer image for upgrades after that.

## Why this exists

Talos publishes no Pi 5 image, and the official `rpi_5` overlay cannot boot one from NVMe: it ships U-Boot
built for the Pi 4, which has no BCM2712 PCIe driver, so U-Boot cannot read the disk the firmware just loaded
it from. Boot stops there, before Linux starts. Verified by upgrading a node to it and watching the board go
dark.

This build pairs a `raspberrypi/linux` kernel with the community overlay and its Pi 5 U-Boot, which does have
that driver.

If you boot from an **SD card**, the official overlay may well work for you and is far less maintenance. Use
it. The full audit of what upstream has and has not caught up on is in [docs/upstream.md](docs/upstream.md),
and the plan to retire this repo is in [FUTURE_WORK.md](FUTURE_WORK.md).

## What is in the image

- Talos on a `raspberrypi/linux` kernel, built with the same clang/ThinLTO toolchain and hardened config as stock Talos.
- RP1 and BCM2712 south-bridge drivers, so the wired NIC, USB and GPIO work.
- 4K kernel pages.
- NVMe and PCIe built in.
- The Pi 5 boot chain on the EFI partition: U-Boot, `config.txt`, `bcm2712-rpi-5-b.dtb` and overlays.
- WiFi and Bluetooth off (`dtoverlay=disable-wifi`, `dtoverlay=disable-bt`).
- Two system extensions: `iscsi-tools` (Longhorn needs `iscsid`) and `util-linux-tools` (`fstrim`).

## Install

Download `metal-arm64-rpi5.raw.xz` from a [release](../../releases), then write it to the disk the Pi will
boot from. Any host, any block device.

```
xz -d metal-arm64-rpi5.raw.xz
sudo dd if=metal-arm64-rpi5.raw of=/dev/<disk> bs=4M status=progress conv=fsync
```

Find `<disk>` with `lsblk` on Linux or `diskutil list` on macOS, and use the whole device (`/dev/sda`,
`/dev/disk6`), not a partition. On macOS write to `/dev/rdisk6` instead, which is far faster, after
`diskutil unmountDisk`.

Slot the drive in, power on with no SD card, and the Pi boots into Talos maintenance mode. Configure it from
there as usual, with `talosctl gen config` and `talosctl apply-config`.

The Pi 5's bootloader must be set to try NVMe. If it is not, flash the EEPROM first with `BOOT_ORDER` and,
for third-party PCIe boards with no ID EEPROM, `PCIE_PROBE=1`.

## Upgrade

```
talosctl upgrade --nodes <node-ip> --image ghcr.io/yama6a/talos-raspberry-pi5:v1.13.7
```

No reflash: Talos upgrades are atomic A/B with rollback.

## Pinning

| Tag | Moves | Use it for |
|---|---|---|
| `v1.13.7` | on every rebuild of that Talos version | pin as `v1.13.7@sha256:...` and let Renovate bump the digest |
| `v1.13.7-2` | never | reproducing or rolling back to one exact build |
| `latest` | on every release | trying it out, nothing else |

## Verify a release

```
sha256sum -c sha256sums.txt
gh attestation verify oci://ghcr.io/yama6a/talos-raspberry-pi5:v1.13.7-2 --owner yama6a
gh attestation verify metal-arm64-rpi5.raw.xz --owner yama6a
```

`build-inputs.json` names the exact upstream commit of every source that went in, and `sbom.spdx.json` is the
SPDX record with per-component licenses.

## Build it yourself

```
make build      # ~40 min on an M2 Pro, ~65 min on a 4-core arm64 runner
make validate   # partition layout, Pi 5 boot bits, kernel label, baked extensions
```

Needs an arm64 host (macOS/Apple Silicon or arm64 Linux), Docker with 60 GB or so of free disk, GNU make >= 4,
and `git curl jq go python3 perl`. `make help` lists everything. Details in [docs/build.md](docs/build.md).

To build a variant, edit [`versions.env`](versions.env) or [`kernel/pi5-rpi.fragment`](kernel/pi5-rpi.fragment).
A fork publishes to its own GHCR namespace with no further edits.

## Known gaps

- **Booting from USB does not work.** USB only comes up once Linux has, not in U-Boot.
- Only tested on a Raspberry Pi 5 (8 GB) with a 52Pi RS-P11 NVMe board. The CM5 and other carriers are
  plausible but unverified here.
- No hardware test runs in CI. Releases are validated offline only: layout, boot bits, kernel label,
  extensions. First boot on real hardware is on you.

## Docs

- [docs/build.md](docs/build.md) how the build works, the three rebases, prerequisites, troubleshooting
- [docs/kernel.md](docs/kernel.md) why the kernel is derived rather than pinned, and the config choices
- [docs/upstream.md](docs/upstream.md) what upstream has caught up on, what has not, and the evidence
- [docs/releases.md](docs/releases.md) tag scheme, what triggers a build, how to verify one
- [FUTURE_WORK.md](FUTURE_WORK.md) how to retire this repo, and the test plan to get there

## Credits

This is a rebase of work other people did first.

- [talos-rpi5/talos-builder](https://github.com/talos-rpi5/talos-builder) is the reference community build,
  and `build/Makefile.talos` here is adapted from its Makefile. If you want a prebuilt Pi 5 image with less
  machinery around it, start there.
- [talos-rpi5/sbc-raspberrypi5](https://github.com/talos-rpi5/sbc-raspberrypi5) is the overlay that puts the
  Pi 5 boot chain on the EFI partition, and [talos-rpi5/u-boot](https://github.com/talos-rpi5/u-boot) is the
  U-Boot fork behind it. Both are used here as-is.
- [siderolabs/talos](https://github.com/siderolabs/talos), [siderolabs/pkgs](https://github.com/siderolabs/pkgs)
  and [siderolabs/extensions](https://github.com/siderolabs/extensions) are Talos itself, its kernel recipe
  and the system extensions.
- [siderolabs/sbc-raspberrypi](https://github.com/siderolabs/sbc-raspberrypi) is the official overlay,
  including `rpi_5`.
- [raspberrypi/linux](https://github.com/raspberrypi/linux) is the kernel fork with the RP1 and BCM2712
  drivers, and [raspberrypi/firmware](https://github.com/raspberrypi/firmware) is how a kernel version is
  mapped back to a commit here.
- Two write-ups that made the first build possible:
  [kcirtap.io](https://kcirtap.io/posts/talos-rpi5-custom-kernel-build/) and
  [rcwz.pl](https://rcwz.pl/2025-10-04-installing-talos-on-raspberry-pi-5/).

## License

The code here is [MIT](LICENSE). The images it publishes are an aggregate of GPL-2.0, MPL-2.0 and other
works, each keeping its own license; see [NOTICE](NOTICE) for the breakdown and the source pointer.
