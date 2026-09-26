# The kernel

Procedures, including resolving a kernel by hand, are in the [build runbook](runbooks/build.md).

## Why a fork kernel

- The image uses the `raspberrypi/linux` fork because it is the configuration known to boot these boards.
  Nobody has proven that it is still necessary.
- Vanilla Linux drives the Pi 5 wired NIC from 6.18 on, and stock Talos turns it on.
- Vanilla and the fork bring RP1 up by different routes. RP1 is the Pi 5 south bridge that the NIC, USB and
  GPIO hang off.

| Route | Kernel side | Device tree side |
|---|---|---|
| fork, used here | `MFD_RP1` and `FIRMWARE_RP1`, which exist only in the fork | the fork's DTBs |
| vanilla, never booted here | `macb` matches `raspberrypi,rp1-gem` directly | `rp1-nexus.dtsi` describes RP1 as a PCI device |

- Both routes end at `macb` driving `end0`.
- The overlay compiles its device tree from whatever kernel image it gets. So kernel and DTB always match,
  and a swap to vanilla is cheap. The open question is whether the vanilla RP1 bring-up works on this
  hardware. [FUTURE_WORK.md](../FUTURE_WORK.md) has the test that settles it.
- The gap that is proven is U-Boot, not the kernel. See [upstream.md](upstream.md).
- Talos builds its kernel with hardened clang and ThinLTO and welds it into the initramfs and installer. So a
  foreign kernel cannot be dropped in. The build runs Talos's own kernel recipe with the source swapped.

## Why the kernel version is derived, never pinned

- Talos hardcodes the kernel version it expects as `DefaultKernelVersion`. The imager writes that string
  into the boot image's `.uname` field, whatever was compiled.
- A different compiled version ships a mislabeled image. `kubectl get nodes` and `talosctl version` then
  report Talos's number, not the running kernel's.
- The imager cannot be made to report the truth. So the build compiles exactly the version Talos expects,
  and the label is right by construction.
- `lib/resolve_inputs.sh` maps that version to a `raspberrypi/linux` commit. The fork has no version tags,
  so the mapping goes through `raspberrypi/firmware` first, then the fork's own branch history.
- Three independent checks guard the label: the resolver, the downloaded tarball's `Makefile`, and
  validation of the built UKI. A mislabeled image is the kind of fault nobody notices for months.
- Never pin a nearby kernel when resolution fails. That is exactly the mislabeling above.

## siderolabs/pkgs

- Not pinned either. Talos's own `Makefile` names the pkgs commit it was built against, and the build checks
  out exactly that commit.
- That checkout's `git describe` tags the kernel image and feeds the overlay and the installer. So a few
  commits of drift would reach the whole build, and the build stops on any mismatch.
- pkgs also supplies the stock arm64 kernel config and the kernel patches that `kernel/patch-skip.txt`
  gates. See [build.md](build.md).

## The config fragment

- `kernel/pi5-rpi.fragment` layers over pkgs' stock arm64 config. `make olddefconfig` fills in the rest.
- Most of its lines only restate what stock already sets. The build re-checks every `=y` line after
  `olddefconfig`, so an upstream config change cannot drop a driver without failing the build.
- The fragment's own comments give the reason for each line.

## Known limitation

- The Pi 5 `macb` TX-stall wedge
  ([sbc-raspberrypi#91](https://github.com/siderolabs/sbc-raspberrypi/issues/91)) is not fixed by a recent
  kernel.
- A recent kernel only makes it possible to turn EEE off, which is the mitigation. That is runtime config,
  so this image cannot carry it.
