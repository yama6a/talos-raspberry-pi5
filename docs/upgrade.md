# Upgrading Talos

What to check before merging a Talos minor or major, and what the bump means for a node that upgrades versus
a board flashed fresh from the new image.

A patch release (`v1.13.8` to `v1.13.9`) is a digest swap and automerges. A minor is not. Renovate labels it
`needs-review` and stops.

## What a minor moves

| Input | Pinned by | What a minor can do to it |
|---|---|---|
| kernel version | derived from Talos's `DefaultKernelVersion`, see [kernel.md](kernel.md) | a new patch level that no `raspberrypi/firmware` channel carries yet |
| `siderolabs/pkgs` commit | derived from Talos's `PKGS ?=` line | new kernel patches that are already in the fork, or collide with it |
| stock kernel config | `config-arm64` at that pkgs commit | move a symbol `kernel/pi5-rpi.fragment` asserts |
| overlay machinery API | `SBCOVERLAY_VERSION` compiles against `pkg/machinery@TALOS_VERSION` | change `overlay.Options`, `InstallOptions` or the adapter signature, so REBASE 3 stops compiling |
| imager and installer | Talos's own Makefile, driven by `build/Makefile.talos` | rename a target, drop a flag, change the boot layout or the cmdline source |
| extensions | digest pins in `versions.env` | tighten the `compatibility.talos.version` constraint |
| machine config defaults | nothing here, it is the user's config | deprecate v1alpha1 fields, remove `talosctl` flags, emit new documents from `gen config` |
| the upgrade flow itself | the running node's `machined` runs the new installer | change how the installer is invoked, what it preserves, how the cmdline is rebuilt |

## What CI proves

| | preflight | build on main | nothing here |
|---|---|---|---|
| kernel version resolves to a fork commit | yes | | |
| pkgs checkout matches Talos, skip list names real patches | yes | | |
| `pkg.yaml` and Dockerfile rewrites still anchor | yes | | |
| overlay compiles against the new machinery | yes | | |
| pkgs patches apply to the fork | | yes | |
| fragment survives `olddefconfig`, kernel compiles | | yes | |
| imager produces an image, UKI label matches, extensions baked | | yes | |
| the board boots, `end0` comes up, NVMe is the root | | | yes |
| an existing node survives the upgrade | | | yes |
| Longhorn attaches a volume afterwards | | | yes |

A red build on main costs nothing: `build.yaml` gates publish and release on the build succeeding. A bad
image reaching a node costs a reflash and an etcd member removal, see [upstream.md](upstream.md).

## Checklist

1. Read the release notes. Section headings first, then anything matching the terms below.

   ```
   gh api repos/siderolabs/talos/releases/tags/v1.14.0 --jq .body > /tmp/rn.md
   grep -n '^### ' /tmp/rn.md
   grep -n -i 'grub\|sd-boot\|uki\|cmdline\|kernel arg\|install section\|unattended\|overlay\|arm64\|extension\|noexec\|isolation\|iscsi\|upgrade\|deprecat\|removed' /tmp/rn.md
   ```

   Read the whole section for every hit, then the `Changes from siderolabs/pkgs` and
   `Changes from siderolabs/tools` lists. Fix commits with `bootloader`, `installer`, `upgrade`, `volume` or
   `mount` in the subject are worth opening.

2. Resolve the kernel.

   ```
   make resolve
   ```

   Expected: a `linux` line naming a commit, `via firmware/master` or another channel, or
   `via linux rpi-X.Y.y@<sha>, no firmware release` when Raspberry Pi skipped that patch level in firmware
   but the fork merged it. A `die` here means the fork has not merged it. Wait, or hold the bump. Do not pin
   a nearby kernel, see [kernel.md](kernel.md).

3. Diff the pkgs patch set against the last release.

   ```
   OLD=$(gh release download --repo yama6a/talos-raspberry-pi5 --pattern build-inputs.json -O - | jq -r .pkgs_ref)
   NEW=$(jq -r .pkgs_ref .cache/build-inputs.json)
   diff <(gh api "repos/siderolabs/pkgs/contents/kernel/build/patches?ref=$OLD" --jq '.[].name' | sort) \
        <(gh api "repos/siderolabs/pkgs/contents/kernel/build/patches?ref=$NEW" --jq '.[].name' | sort)
   ```

   For every added patch, read its entry in `kernel/build/patches/README.md` at `$NEW`, then dry-run it
   against the fork at the commit `make resolve` printed:

   ```
   mkdir patches && gh api "repos/siderolabs/pkgs/contents/kernel/build/patches?ref=$NEW" \
     --jq '.[] | select(.name | endswith(".patch")) | .download_url' | xargs -n1 -I{} curl -fsSLO --output-dir patches {}
   K=$(jq -r .kernel_commit .cache/build-inputs.json)
   curl -fsSL "https://github.com/raspberrypi/linux/archive/$K.tar.gz" | tar xz
   cd "linux-$K"
   for p in ../patches/00*.patch; do echo "== $p"; patch -p1 -N --dry-run < "$p" | tail -3; done
   ```

   | `patch` says | Meaning | Do |
   |---|---|---|
   | `Reversed (or previously applied)` on every hunk | the fork already has it | add the slug to `kernel/patch-skip.txt` with the reason |
   | applies cleanly | the fork lacks it | nothing, the build applies it |
   | some hunks fail | real collision | read both sides. Fork has an equivalent: skip. Fork lacks it: rebase the patch, or skip and record what is lost |
   | applies `with fuzz` | context did not match | treat as a collision and read it. `patch` defaults to fuzz 2 and will drop a hunk into a lookalike block |

   A slug is the filename minus its `NNNN-` prefix. Numbers move on every pkgs bump.

   For every removed patch, delete its slug from `kernel/patch-skip.txt`. A slug that matches no patch fails
   the build before the kernel download.

4. Re-check the reason behind every existing skip entry. The fork rebases, so what was true at the last
   kernel can be false at this one.

   ```
   grep -n 'MACB_CAPS_PCIE_POSTED_WRITES\|MACB_CAPS_EEE' drivers/net/ethernet/cadence/macb.h
   grep -n 'tx_pending' drivers/net/ethernet/cadence/macb_main.c
   ```

   Expected: both capability bits defined, `tx_pending` used in the TSR read path. If the fork dropped its
   own TX-stall recovery, pkgs' watchdog patch is no longer redundant and the skip is wrong.

5. Diff the stock config for the symbols the fragment asserts.

   ```
   for r in $OLD $NEW; do curl -fsSL "https://raw.githubusercontent.com/siderolabs/pkgs/$r/kernel/build/config-arm64" -o "config-$r"; done
   for s in $(grep -oE '^CONFIG_[A-Z0-9_]+' kernel/pi5-rpi.fragment); do
     diff <(grep "^$s[= ]\|^# $s " "config-$OLD") <(grep "^$s[= ]\|^# $s " "config-$NEW") && continue
     echo "MOVED: $s"
   done
   ```

   Expected: nothing printed. A moved symbol is not a failure by itself, since the fragment wins on
   `olddefconfig`, but a new dependency can make a bake-in unmet and that only shows up in the build.

6. Run preflight.

   ```
   make preflight
   ```

   Expected: `PREFLIGHT PASSED`. It clones the three upstreams, checks the skip list against real patch
   names, applies the build's `pkg.yaml` rewrites to prove their anchors still exist, and compiles the overlay
   against the new machinery. The same job runs on the PR.

7. Check what preflight does not. Machinery can add fields without breaking the compile, and the imager can
   change under a flag that still exists.

   ```
   T=$(grep '^TALOS_VERSION' versions.env | cut -d'"' -f2)
   curl -fsSL "https://raw.githubusercontent.com/siderolabs/talos/$T/pkg/machinery/overlay/overlay.go" | grep -v '^//'
   curl -fsSL "https://raw.githubusercontent.com/siderolabs/talos/$T/Makefile" | grep -E '^(kernel|initramfs|imager|installer-base|installer):'
   curl -fsSL "https://raw.githubusercontent.com/siderolabs/talos/$T/cmd/installer/cmd/imager/root.go" | grep -oE '"(overlay-name|overlay-image|base-installer-image|system-extension-image)"'
   ```

   Expected: `Options` still has `Name` and `KernelArgs`, `InstallOptions` still has `MountPrefix` and
   `ArtifactsPath`; all five targets; all four flags. The overlay's `profiles/rpi5/rpi5.yaml` says
   `bootloader: grub`; check the notes for anything that changes how grub is installed or where the cmdline
   comes from on grub-booted arm64.

8. Check the extension constraints. The pins in `versions.env` predate the new minor.

   ```
   for img in $(grep -oE 'ghcr.io/siderolabs/[a-z-]+:[^"]+' versions.env); do
     crane export "$img" - | tar -xO manifest.yaml | grep -A2 compatibility
   done
   ```

   Expected: a `version:` constraint the new Talos satisfies. The imager refuses an extension that does not,
   so this fails the build rather than the node. Extensions are rebuilt for every Talos minor and Renovate
   brings the new digests in the combined PR; merge order does not matter.

9. Validate the cluster's machine configs with the new `talosctl`.

   ```
   talosctl validate --mode metal --config controlplane.yaml
   talosctl validate --mode metal --config worker.yaml
   ```

   Expected: no errors. Deprecation warnings name what to migrate before the field is removed a release or
   two later. Also check the notes for removed `talosctl` flags used by any script here.

10. Merge, then watch the build.

    ```
    gh run watch --repo yama6a/talos-raspberry-pi5
    ```

    Expected: `VALIDATION PASSED`, a release tagged `vX.Y.Z-1`, three OCI tags. A red run means an item above
    was missed, and nothing was published. Fix on a branch, merge again.

11. Upgrade one worker, not a control plane node.

    ```
    talosctl upgrade --nodes <worker> --image ghcr.io/yama6a/talos-raspberry-pi5:vX.Y.Z-1
    talosctl -n <worker> version                    # expected: the new tag, kernel label = the resolved version
    talosctl -n <worker> get links end0             # expected: up, 1Gbps
    talosctl -n <worker> get extensions             # expected: iscsi-tools, util-linux-tools
    talosctl -n <worker> reboot                     # expected: comes back from NVMe on its own
    ```

    Then attach a Longhorn volume to a pod pinned to that node and write to it. Only after that, the rest
    of the workers, then the control plane one at a time.

12. Roll back if the node misbehaves.

    ```
    talosctl -n <worker> rollback
    ```

    A node that does not come back at all is the U-Boot failure mode from [upstream.md](upstream.md):
    reflash the previous release's raw image, rejoin, remove the stale etcd member if it was a control plane
    node.

## Existing clusters versus fresh installs

The same image behaves differently depending on how a node got it, because Talos keeps an upgraded node's
existing machine config and only `talosctl gen config` picks up new defaults.

| | Upgraded from an older release of this repo | Flashed fresh from the new image, config from `gen config` on the new minor |
|---|---|---|
| kernel, drivers, boot chain | the new image's | the new image's |
| machine config | unchanged, deprecated fields keep working for now | the new minor's defaults and documents |
| new defaults from the notes | absent until you add the document | present |
| the install section | kept, and still the source of the kernel cmdline on grub | absent on 1.14+, the cmdline comes from the UKI |
| what to test first | one worker, then reboot it | one board, then reboot it |

For 1.14 specifically:

| | Upgraded | Fresh |
|---|---|---|
| workload isolation (`SecurityProfileConfig`) | off, no document | on by default. The in-tree iSCSI plugin stops working; Longhorn uses its own CSI driver. Whether Longhorn v1's `iscsiadm` through `nsenter` still reaches the host `iscsid` inside the sandbox is not verified here. Test it, or set `workloadIsolation: false` |
| filesystem trim (`FilesystemTrimConfig`) | off, no document | weekly by default. `util-linux-tools` supplies `fstrim` either way |
| install | `.machine.install` kept, cmdline rebuilt from it on every upgrade | `UnattendedInstall` document, no install section, cmdline read from the UKI. The imager wrote the overlay's `KernelArgs` into that UKI, so the two agree |
| `/var` mount flags | `nosuid,nodev` | same. `noexec` on `/var` shipped in the 1.14 alphas and was dropped before the release (`6fa811a0d`); only STATE, ETCD and LOG are `noexec` |
| `talosctl apply-config --mode=reboot` | gone, applies without a reboot by default | same |
| Longhorn pod security | `enforce: privileged` on its namespace, as before | same |

## The 1.14.0 to 1.14.1 record

Checked on 2026-09-17, against `v1.14.1` and pkgs `v1.14.0-25-gf694e1b`.

| Item | Result |
|---|---|
| why 1.14.0 never shipped | the 1.14.0 imager staged the overlay's EFI assets under the BOOT source dir, so `config.txt`, `u-boot.bin`, the DTB and the overlays were missing from the EFI partition and `make validate` failed. Fixed upstream in `09681e8` (siderolabs/talos#14226), in 1.14.1 |
| kernel | 6.18.48 to 6.18.51. No firmware ref: `raspberrypi/firmware` master went 6.18.50 to 6.18.52. Resolved through the fork branch to `457be933`, stable 6.18.51 plus six Pi commits, all of which are also in the 6.18.52 firmware |
| pkgs patches | one added, `security-lockdown-lock-down-the-kernel-in-EFI-Secure-`, applies cleanly |
| existing skip entries | both macb capability bits and `tx_pending` still in the fork at 6.18.51 |
| stock config | no fragment symbol moved |
| overlay, imager, installer | machinery API, make targets and imager flags unchanged |
| extensions | same digests as 1.14.0 |
| not verified | the kernel compiles, the imager runs, a board boots |

## The 1.13.9 to 1.14.0 record

Checked on 2026-09-06, against `v1.14.0` and pkgs `v1.14.0-15-g2f03590`.

| Item | Result |
|---|---|
| kernel | 6.18.44 to 6.18.48, `firmware/master` HEAD carries it |
| pkgs patches | one dropped (`mm-page_table_check`), nine added: four `net-cadence-macb` EEE patches and five `libceph` ones |
| the four EEE patches | already in the fork, and already in the 6.18.44 that `v1.13.9-8` shipped. `patch -N` reports every hunk of three as previously applied; the fourth's `macb_get_eee`, `macb_set_eee` and `gem_ethtool_ops` entries are present verbatim. Added to `patch-skip.txt`. No change to the running kernel |
| the five libceph patches | apply cleanly, the build takes them |
| existing skip entries | `MACB_CAPS_PCIE_POSTED_WRITES` and the `tx_pending` breadcrumb are both still in the fork at 6.18.48 |
| overlay | compiles against machinery v1.14.0; the API only added the `ctx` argument REBASE 3 already patches in |
| imager, installer | all five make targets and all four imager flags present; Dockerfile frontend `docker/dockerfile-upstream:1.26.0-labs` |
| extensions | `iscsi-tools` requires `>= v1.1.0`, `util-linux-tools` `>= v1.0.0` |
| `hack/modules-arm64.txt` | present, REBASE 2 unaffected |
| release notes, relevant | workload isolation default for new clusters; `UnattendedInstall` replaces `.machine.install` in `gen config`, and a config with no install section reads its cmdline from the UKI (`68a436656`); `--mode=reboot` removed; `FilesystemTrimConfig` default for new clusters; `ghcr.io/siderolabs/installer` no longer published, which does not touch this repo since it builds its own |
| release notes, not relevant here | `multipath-tools` config migration; secure boot lockdown default; every v1alpha1 deprecation, all still supported |
| not verified | the kernel compiles, the imager runs, a board boots: the build and a canary node. Longhorn v1 under `workloadIsolation: true` on a fresh 1.14 cluster |

Why pkgs added the EEE series matters here: it targets the RP1 LPI-wake race behind the silent network
death in [sbc-raspberrypi#91](https://github.com/siderolabs/sbc-raspberrypi/issues/91), which is the wedge
[kernel.md](kernel.md) describes. The fork got there first, so this repo's kernel has had it since 6.18.44.
Nothing about that changes with 1.14; the runtime EEE mitigation stays runtime.
