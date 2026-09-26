# Why this repo exists

One upstream gap keeps this build alive. This is the audit and its evidence, so nobody has to redo it.

## The gap

- The Pi 5 boots from NVMe. U-Boot has to load the next stage from that same NVMe.
- The U-Boot in the official `rpi_5` overlay has no BCM2712 PCIe driver. So it cannot read the disk the
  firmware just loaded it from, and boot stops before Linux starts.
- The kernel is not the reason.

## The test that showed it

An HA node was upgraded to an Image Factory image with `overlay: rpi_5` plus `siderolabs/iscsi-tools` and
`siderolabs/util-linux-tools`. The upgrade itself did the right things:

```
probing bootloader on "/dev/nvme0n1"
found GRUB bootloader on "/dev/nvme0n1"
executing: grub-install --boot-directory=/boot --removable --efi-directory=/boot/EFI --target=arm64-efi /dev/nvme0n1
META: loading from /dev/nvme0n1p4
```

Then the node rebooted and never came back, with no layer-2 presence at all:

```
arp -n <node>     ->  (incomplete)
nc -vz <node> 50000 -> no route to host
```

- Recovery took a reflash of the NVMe and a rejoin.
- Before trying this on a node you care about: a replaced node needs its stale etcd member removed and its
  node-local PVCs deleted.

## Root cause

- `installers/rpi_5` in the official overlay copies `arm64/u-boot/rpi_generic/u-boot.bin` to
  `/boot/EFI/u-boot.bin`. That is the only U-Boot in the overlay, built from the Pi 4-era
  `rpi_arm64_defconfig`.
- The overlay builds a U-Boot release whose `pcie_brcmstb.c` matches only `brcm,bcm2711-pcie`.

| Binding | community `talos-rpi5/u-boot` | official overlay's U-Boot | upstream U-Boot from v2026.07 |
|---|---|---|---|
| `brcm,bcm2712` | yes | yes | yes |
| `brcm,bcm2712-pm` | yes | yes | yes |
| `brcm,bcm2712-sdhci` | yes | yes | yes |
| `brcm,bcm2712-pcie` | yes | no | yes |

- Upstream U-Boot has the driver from v2026.07, under `CONFIG_PCI_BRCMSTB`, which `rpi_arm64_defconfig`
  already sets. No `rpi_5_defconfig` is needed.
- `sdhci` is present. That is why the official overlay boots from an SD card and not from NVMe.

Where the boot chain stops:

1. The EEPROM bootloader reads `BOOT_ORDER` and `PCIE_PROBE`, finds the NVMe with its own PCIe support, and
   loads `u-boot.bin` from the FAT partition.
2. U-Boot starts and must load GRUB from the same NVMe with its own PCIe driver.
3. No driver claims `brcm,bcm2712-pcie`, so U-Boot cannot see the NVMe.
4. Boot halts in U-Boot. No kernel, no NIC, no ARP.

The overlay's `0002-rpi-add-NVMe-to-boot-order.patch` puts NVMe in the boot order. U-Boot just cannot
enumerate it.

## Kernel and DTB move together

On this image, RP1 comes up through the fork's own drivers:

```
rp1_pci 0002:01:00.0: probe with driver rp1_pci failed with error -22
rp1 0002:01:00.0: chip_id 0x20001927
rp1-firmware rp1_firmware: RP1 Firmware version ...
macb 1f00100000.ethernet eth0: Cadence GEM rev 0x00070109
macb 1f00100000.ethernet end0: Link is Up - 1Gbps/Full
```

- So `MFD_RP1` and `FIRMWARE_RP1` are in use here.
- The `rp1_pci` failure is harmless. The fork carries a legacy `rp1-pci` driver and the newer `rp1` MFD. The
  legacy one loses, and the working one binds after it.
- The overlay's `internal/base/pkg.yaml` takes `/dtb` from the kernel image it gets. So the device tree
  always follows the kernel, and a stock Talos kernel gets vanilla DTBs.
- Whether the vanilla RP1 bring-up works on this hardware is unknown, because the U-Boot failure stopped the
  test first. [FUTURE_WORK.md](../FUTURE_WORK.md) step 1 answers it.

## What each part of the build is still for

| Part | Status | Why |
|---|---|---|
| community U-Boot, through the community overlay | required | the only shipped U-Boot with `brcm,bcm2712-pcie` |
| fork kernel with `MFD_RP1`, `FIRMWARE_RP1`, `MBOX_RP1`, `COMMON_CLK_RP1_SDIO`, `BCM2712_IOMMU` | in use, not proven necessary | vanilla has its own RP1 path, untested here |
| REBASE 1, kernel source and config | required | follows from the fork kernel |
| REBASE 2, module list filter | a consequence | exists only because the kernel differs |
| REBASE 3, overlay machinery port | a consequence | the community overlay targets old machinery |
| 4K pages | an assertion | stock Talos is already 4K. The Pi tree's own defconfig is 16K |
| the two system extensions | required either way | Longhorn needs them on any image |
| most fragment symbols | assertions | stock already sets them |

- The kernel side of iSCSI, device-mapper and NFS is stock and built in. So REBASE 2 finds no iSCSI modules
  to filter, which is correct.
- The extensions are userspace (`iscsid`, `iscsiadm`, `fstrim`), and Talos has no package manager, so they
  must be baked in. Image Factory bakes nothing by default, so a schematic must name both.

## Upstream state

The driver is upstream. The missing piece is an overlay release that builds a U-Boot with it.

| Where | State |
|---|---|
| [sbc-raspberrypi#33](https://github.com/siderolabs/sbc-raspberrypi/pull/33) | Renovate's U-Boot bump to v2026.07. Four of the overlay's seven U-Boot patches fail to apply: `0005` to `0007` (NVMe address translation) and `0008` (`rpi_arm64_defconfig`). Cannot merge as-is |
| U-Boot v2026.10 | `09b1c0f9 nvme: Fix missing address translation for PCIe inbound access` does what `0006` and `0007` patch in. The overlay can likely drop those two |
| [sbc-raspberrypi#88](https://github.com/siderolabs/sbc-raspberrypi/pull/88) | 14 out-of-tree U-Boot patches, including a BCM2712 PCIe driver. The maintainer wants them upstream first. The PCIe half now is |
| [sbc-raspberrypi#97](https://github.com/siderolabs/sbc-raspberrypi/pull/97) | a 23-patch set the maintainer declined to carry |
| [sbc-raspberrypi#93](https://github.com/siderolabs/sbc-raspberrypi/pull/93) | cleanup that unifies the Pi 5 into `rpi_generic`. Blocked on the above |
| [sbc-raspberrypi#96](https://github.com/siderolabs/sbc-raspberrypi/issues/96) | the maintainer wants test reports on both D0 and D1 stepping before merging |
| [#81](https://github.com/siderolabs/sbc-raspberrypi/issues/81), [#82](https://github.com/siderolabs/sbc-raspberrypi/issues/82), [#91](https://github.com/siderolabs/sbc-raspberrypi/issues/91) | Pi 5 ethernet, all on the vanilla RP1 path this build does not use |

The path out: the overlay moves U-Boot to v2026.07 or later, rebases or drops its NVMe patches, and ships.
Then someone boots an Image Factory `rpi_5` image from NVMe on both steppings. U-Boot needs only the NVMe to
hand off to GRUB, not RP1 ethernet. See [FUTURE_WORK.md](../FUTURE_WORK.md).

## Left to do after U-Boot is fixed

- Boot the vanilla RP1 ethernet path here. Those three open issues are about it.
- Turn Wi-Fi and Bluetooth off with `dtoverlay=disable-wifi` and `dtoverlay=disable-bt` through the overlay's
  `configTxtAppend`. The `.dtbo` files ship, but the official `config.txt` does not enable them.
- The official `config.txt` sets `enable_uart=0` under `[pi5]`. Replace `configTxt` to get a debug console.
  The missing console is a likely reason those ethernet issues stay open.
