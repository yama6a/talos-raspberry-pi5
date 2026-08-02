# Why this repo exists

Upstream has caught up on almost everything this build was created for. One gap is left, and it is enough to
keep the whole thing alive. This is the audit, with the evidence, so the next person does not have to redo it.

## Short version

The Pi 5 boots from NVMe. U-Boot is what loads the bootloader off that NVMe, and the U-Boot the official
`rpi_5` overlay ships has no BCM2712 PCIe driver, so it cannot read the disk it was itself loaded from. Boot
halts inside U-Boot before Linux ever starts.

Nothing about the kernel. The kernel is no longer the reason.

## Why it was created

At the time, none of these existed:

- No official Talos Pi 5 image, and no `rpi_5` overlay in `siderolabs/sbc-raspberrypi`.
- No RP1 ethernet in vanilla Linux, so the wired NIC needed the `raspberrypi/linux` fork.
- The community `talos-rpi5/talos-builder` published prebuilt images, but its releases tracked an older Talos
  minor, and its overlay targeted older Talos machinery.

So the build drove the community pipeline and rebased it onto a current Talos. That reasoning was correct then
and is mostly obsolete now.

## What upstream fixed

| Landed | What |
|---|---|
| Linux 6.18 | `raspberrypi,rp1-gem` bound by the ordinary `macb` driver, plus `rp1-common.dtsi` / `rp1-nexus.dtsi` describing RP1 as a PCI device. Verified absent at 6.12, 6.15, 6.16 and 6.17 |
| `siderolabs/sbc-raspberrypi` | an `rpi_5` overlay with Pi 5 DTBs, including the D0-stepping variants `bcm2712d0-rpi-5-b.dtb` and `bcm2712-d-rpi-5-b.dtb` |
| its `profiles/rpi_5/rpi_5.yaml` | `bootloader: grub`, which is exactly what REBASE 4 used to force by hand |
| `machinery` `sbcs.go` | `rpi_5` registered with a `MinVersion`, so Image Factory offers it |

Floor to remember: RP1 ethernet needs Linux >= 6.18. Below that the fork is unavoidable.

The stock Talos arm64 kernel config already sets `MACB`, `PINCTRL_RP1`, `COMMON_CLK_RP1`, `PCIE_BRCMSTB`,
`ARM64_4K_PAGES`, `ISCSI_TCP`, `INET_DIAG_DESTROY`, `WATCHDOG`, `BCM2835_WDT`, `PINCTRL_BCM2712` and
`BCM2712_MIP`. Ten of the sixteen lines in `kernel/pi5-rpi.fragment` are assertions against that config, not
changes to it.

## The test that settled it

An HA node was upgraded to an Image Factory image built from the official overlay: schematic
`overlay: rpi_5` plus `siderolabs/iscsi-tools` and `siderolabs/util-linux-tools`, via
`talosctl upgrade --image factory.talos.dev/metal-installer/<schematic>:<version>`.

The upgrade itself succeeded and did the right things:

```
probing bootloader on "/dev/nvme0n1"
found GRUB bootloader on "/dev/nvme0n1"
executing: grub-install --boot-directory=/boot --removable --efi-directory=/boot/EFI --target=arm64-efi /dev/nvme0n1
META: loading from /dev/nvme0n1p4
```

Then the node rebooted and never came back. Not "no Kubernetes" and not "no IP":

```
arp -n <node>     ->  (incomplete)          no layer-2 presence at all
nc -vz <node> 50000 -> no route to host
```

Recovered by reflashing the NVMe and rejoining the node. Worth knowing before you try this on anything you
care about: a replaced node needs its stale etcd member removed and its node-local PVCs deleted before the
cluster is whole again.

## Root cause

`installers/rpi_5` in the official overlay embeds the literal string
`arm64/u-boot/rpi_generic/u-boot.bin` and copies it to `/boot/EFI/u-boot.bin`. That is the only U-Boot binary
in the overlay image; there is no `rpi_5` build. It comes from `make rpi_arm64_defconfig`, the Pi 4-era
generic config.

Which BCM2712 device-tree bindings each U-Boot implements:

| Binding | community `talos-rpi5/u-boot` | official `rpi_generic` |
|---|---|---|
| `brcm,bcm2712` | yes | yes |
| `brcm,bcm2712-pm` | yes | yes |
| `brcm,bcm2712-sdhci` | yes | yes |
| **`brcm,bcm2712-pcie`** | **yes** | **absent** |

The community fork adds a whole `brcm_pcie_bcm2712_cfg` to `drivers/pci/pcie_brcmstb.c`. Upstream U-Boot does
not have it either: no `rpi_5_defconfig` exists, and its `pcie_brcmstb.c` matches only `brcm,bcm2711-pcie`.

The boot chain, and where it stops:

1. The Pi 5's EEPROM bootloader reads `BOOT_ORDER` and `PCIE_PROBE`, enumerates the NVMe with its OWN PCIe
   support, reads the FAT partition, and loads whatever `config.txt` names as `kernel=`, which is `u-boot.bin`.
2. U-Boot starts and now has to load GRUB from that same NVMe, using its own PCIe driver.
3. No driver claims `brcm,bcm2712-pcie`. The NVMe is invisible to U-Boot.
4. Boot halts in U-Boot. No kernel, no NIC, no ARP.

The overlay does carry a `0002-rpi-add-NVMe-to-boot-order.patch`, which is presumably why this shipped: NVMe is
in the boot order, it just cannot be enumerated. `sdhci` being present is why the official overlay boots fine
from an SD card and not at all from NVMe.

## Kernel and DTB are a matched pair

This is the part that makes the migration all-or-nothing.

On this build's image, RP1 comes up through the fork's own drivers:

```
rp1_pci 0002:01:00.0: probe with driver rp1_pci failed with error -22
rp1 0002:01:00.0: chip_id 0x20001927
rp1-firmware rp1_firmware: RP1 Firmware version ...
macb 1f00100000.ethernet eth0: Cadence GEM rev 0x00070109
macb 1f00100000.ethernet end0: Link is Up - 1Gbps/Full
```

So `MFD_RP1` and `FIRMWARE_RP1` are load-bearing here, not decoration. (The `rp1_pci` failure above is
harmless: the fork carries both a legacy `rp1-pci` driver and the newer `rp1` MFD, the legacy one loses and the
working one binds after it.)

Vanilla reaches the same place by a different route: an `rp1_nexus` node with `compatible = "pci1de4,1"` from
`rp1-nexus.dtsi`, upstream `clk-rp1` and `pinctrl-rp1`, and `macb` matching `raspberrypi,rp1-gem`. No MFD, no
firmware driver.

Two mechanisms, selected by which DTB you boot, and you cannot mix one kernel with the other's DTBs. That
sounds like a barrier and is not: `internal/base/pkg.yaml` in the overlay pulls `/dtb` straight out of the
kernel image it is given, so the device tree follows the kernel automatically. Hand it a stock Talos kernel
and it compiles vanilla DTBs to match.

So swapping the kernel is mechanically cheap. What is unproven is whether the vanilla RP1 bring-up works on
this hardware at all, because the U-Boot failure meant it never got to run. That is what
[../FUTURE_WORK.md](../FUTURE_WORK.md) step 1 exists to answer.

## System extensions contribute nothing to this question

`iscsi-tools` and `util-linux-tools` are required for Longhorn either way, and both paths supply them the same
way. The kernel side of iSCSI is stock and built in, not modules:

```
CONFIG_ISCSI_TCP=y   CONFIG_SCSI_ISCSI_ATTRS=y   CONFIG_BLK_DEV_DM=y   CONFIG_DM_CRYPT=y   CONFIG_NFS_FS=y
```

Built in means no `.ko`, which is why the module inventory this build filters in REBASE 2 has zero iSCSI
entries. That is correct, not a gap.

The extensions themselves are userspace (`iscsid`, `iscsiadm`, `fstrim`) and Talos has no package manager, so
they must be baked. Here they are digest pins in `versions.env` passed as `--system-extension-image=`; on
Image Factory they are names in the schematic. Factory bakes nothing by default: a bare `rpi_5` schematic and
one with both extensions produce different schematic IDs.

## Audit: which steps still earn their place

| Step | Verdict | Why |
|---|---|---|
| Community U-Boot, via the community overlay | **load-bearing** | the only source of `brcm,bcm2712-pcie` |
| Fork kernel plus `MFD_RP1`, `FIRMWARE_RP1`, `MBOX_RP1`, `COMMON_CLK_RP1_SDIO`, `BCM2712_IOMMU` | **in use, not proven necessary** | the RP1 bring-up this image runs on. Vanilla has its own path, untested here |
| REBASE 1, kernel source and config | load-bearing | follows from the above |
| REBASE 2, module list filter | consequence only | exists only because this build uses a different kernel |
| REBASE 3, overlay machinery port | consequence only | the community overlay targets old machinery; the official one does not need it |
| REBASE 4, force the `rpi5` grub profile | **obsolete** | the official profile is already `bootloader: grub`, and the upgrade log confirms grub ran |
| 4K pages | **obsolete as a reason** | stock Talos arm64 is already 4K. Kept as an assertion because the kernel source is a Pi tree whose own defconfig is 16K |
| iSCSI, device-mapper, NFS kernel support | **obsolete as a reason** | all stock, all built in |
| The two system extensions | required either way | not a reason for or against this repo |
| Ten of sixteen fragment symbols | assertions | stock already sets them |

## Upstream state

The fix exists. Twice. Neither has landed.

| | |
|---|---|
| `sbc-raspberrypi` PR "add Raspberry Pi 5 support to rpi_generic U-Boot build" | the real fix. ~4200 added lines, 14 topical U-Boot patches including a BCM2712 PCIe controller driver and RP1 ethernet. CI unstable, open for months |
| `sbc-raspberrypi` PR "rpi_5: build dedicated u-boot with RP1 support" | describes 23 patches, but the actual diff is one line pointing the installer at an `rpi_5/u-boot.bin` that the build never produces. Incomplete as submitted |
| `sbc-raspberrypi` PR "remove rpi_5 installer and unify Pi 5 into rpi_generic" | cleanup, explicitly blocked on the U-Boot patches landing first |
| `sbc-raspberrypi` issue "rpi_5 overlay ships rpi_generic's u-boot binary" | maintainer: open to reviewing the patch, but wants community members to test on both D0 and D1 stepping before merging |
| `sbc-raspberrypi` issues on Pi 5 ethernet | three open, long threads, all against the vanilla RP1 path this build does not use |

The blocker is test coverage on both BCM2712 steppings, not code. See [../FUTURE_WORK.md](../FUTURE_WORK.md).

## What would still need doing after U-Boot is fixed

Not a migration plan, just the residue, so nobody assumes U-Boot is the last step:

- The vanilla RP1 ethernet path has never been booted here, and it is the subject of those three open issues.
- Wire `dtoverlay=disable-wifi` and `dtoverlay=disable-bt` through the overlay's `configTxtAppend` option. The
  `.dtbo` files ship; the official `config.txt` just does not enable them.
- The official `config.txt` sets `enable_uart=0` under `[pi5]`, so override `configTxt` if you want a console
  to debug with. That absent console is plausibly why those ethernet issues have stayed open so long.
