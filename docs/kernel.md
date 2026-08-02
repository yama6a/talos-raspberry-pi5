# The kernel

## Why a fork kernel at all

Not because vanilla lacks RP1 any more. Vanilla carries the Pi 5's wired NIC as of Linux 6.18, and stock Talos
enables it. The fork is here because kernel and device tree are a matched pair, and the community overlay this
build depends on for its Pi 5 U-Boot ships the fork's DTBs, which expect the fork's RP1 drivers. Swapping the
kernel means swapping the overlay, which means losing the only U-Boot that can boot a Pi 5 from NVMe.

Full reasoning, and what would have to change to drop the fork, in [upstream.md](upstream.md).

On this image RP1 comes up through `MFD_RP1` and `FIRMWARE_RP1`, which are fork-only. Vanilla instead
describes RP1 as a PCI device in `rp1-nexus.dtsi` and needs neither. Both routes end at `macb` driving `end0`.

Talos welds a hardened clang/ThinLTO kernel into its initramfs and installer, so you cannot drop a foreign
kernel in. The kernel has to be rebuilt through Talos's own recipe, with the source swapped underneath.

## Why the kernel version is derived, never pinned

Talos hardcodes the kernel version it expects, as `DefaultKernelVersion` in `pkg/machinery/constants`, and
the imager stamps THAT string onto the boot image's `.uname` field regardless of what was actually compiled.

If the two differ the image ships mislabeled: the running kernel is real and correct, but the UKI, and
anything reading it such as `kubectl get nodes` or `talosctl version`, reports Talos's number instead. There
is no way to make the imager report the truth, so instead the build compiles exactly what Talos expects and
the two match by construction.

`lib/resolve_inputs.sh` does that, over plain HTTP with no clones:

1. Read `DefaultKernelVersion` out of the pinned Talos tag.
2. Find the `raspberrypi/linux` commit carrying that version. The fork has no per-version tags, only rebased
   branches, so the mapping goes through `raspberrypi/firmware`: each firmware ref's `extra/git_hash` names
   the linux commit that ref's kernel was built from. The four channel HEADs (`master`, `stable`, `next`,
   `oldstable`) are tried first, and `master` usually matches.
3. Failing that, walk `master`'s `extra/git_hash` history, which is a dense index of every recent kernel,
   newest first.

The build then re-checks the downloaded tarball's own `Makefile` version, and validation re-checks the
compiled kernel against the UKI label at the end. Three independent checks, because a mislabeled image is
the kind of thing nobody notices for months.

## If kernel resolution fails

`make resolve` found no firmware ref carrying the version Talos wants. That means either a very old Talos is
being rebuilt, or Raspberry Pi skipped that patch level. Inspect by hand:

```
for b in master stable next oldstable; do
  h=$(curl -fsSL "https://raw.githubusercontent.com/raspberrypi/firmware/$b/extra/git_hash" | tr -d '[:space:]')
  v=$(curl -fsSL "https://raw.githubusercontent.com/raspberrypi/linux/$h/Makefile" \
        | awk -F' = ' '/^VERSION/{a=$2}/^PATCHLEVEL/{p=$2}/^SUBLEVEL/{c=$2} END{print a"."p"."c}')
  echo "$b -> $v ($h)"
done

# older versions: the linux commit is the git_hash at each historical master commit that changed it
gh api "repos/raspberrypi/firmware/commits?path=extra/git_hash&sha=master" --jq '.[].sha'
```

Then either wait for a firmware channel to ship that version, or move `TALOS_VERSION` to a release whose
expected kernel does exist. Do not pin a nearby kernel: that is exactly the mislabeling above.

## siderolabs/pkgs

Not pinned either. Talos's `PKGS ?=` Makefile line names the commit it was built against, and the build
checks that exact commit out. That checkout's `git describe` tags the kernel image and is passed on as
`PKGS=` to the overlay and `PKG_KERNEL=` to the installer, so a few commits of drift would propagate through
the whole build. The build hard-fails if the checkout describes as anything else.

pkgs also supplies the stock arm64 kernel config, which is already 4K pages, and the kernel patches that
`kernel/patch-skip.txt` gates. See [build.md](build.md).

## The config fragment

`kernel/pi5-rpi.fragment` is appended to pkgs' stock arm64 config, then `make olddefconfig` fills in
everything not set explicitly. Every `=y` line in the fragment is re-asserted afterwards, so an unmet
dependency fails the build rather than silently dropping a driver. The assertion list is generated from the
fragment itself, so the two cannot drift.

What each line does relative to the stock config, which is what to check before editing one:

| Symbols | Against the stock Talos arm64 config |
|---|---|
| `MFD_RP1`, `MBOX_RP1`, `FIRMWARE_RP1`, `COMMON_CLK_RP1_SDIO`, `BCM2712_IOMMU` | absent. The real additions, and the reason for the whole build |
| `BLK_DEV_NVME` | stock builds it as a module; here it is `=y` |
| `ARM64_4K_PAGES`, `PCIE_BRCMSTB`, `MACB`, `BCM2835_WDT`, `WATCHDOG`, `PINCTRL_RP1`, `COMMON_CLK_RP1`, `PINCTRL_BCM2712`, `BCM2712_MIP`, `INET_DIAG_DESTROY` | already `=y`. Asserted so a config change upstream cannot drop one silently |

**4K pages.** The kernel source is a Pi tree, whose own `bcm2712_defconfig` is 16K. Some storage software
does not cope with 16K, so the fragment holds the config at Talos's 4K.

**NVMe built in.** Takes the module out of the boot path. The cost is that `nvme.ko` no longer exists, which
is part of why the module list needs filtering.

**`INET_DIAG_DESTROY`** lets a privileged pod force-close established sockets with `ss -K`, which is how a
wedged `macb` NIC gets recovered without a reboot.

## Known kernel-side limitation

A recent kernel does not fix the Pi 5 `macb` TX-stall wedge
([sbc-raspberrypi#91](https://github.com/siderolabs/sbc-raspberrypi/issues/91)). What the recent kernel buys
is the ability to turn EEE off at all, which is the mitigation. The mitigation itself is runtime
configuration, not something this image can carry.
