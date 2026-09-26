# Upgrade runbook

Work through this before merging a Talos minor or major. What a minor can move, and why each check exists,
is in [upgrade.md](../upgrade.md). Below, `$OLD` and `$NEW` are the pkgs refs of the last release and the bump.

1. Read the release notes. Headings first, then every hit for the terms below:

   ```
   gh api repos/siderolabs/talos/releases/tags/vX.Y.Z --jq .body > /tmp/rn.md
   grep -n '^### ' /tmp/rn.md
   grep -n -i 'grub\|sd-boot\|uki\|cmdline\|kernel arg\|install section\|unattended\|overlay\|arm64\|extension\|noexec\|isolation\|iscsi\|upgrade\|deprecat\|removed' /tmp/rn.md
   ```

   Read the whole section for each hit, then the `Changes from siderolabs/pkgs` and
   `Changes from siderolabs/tools` lists. Open fix commits with `bootloader`, `installer`, `upgrade`,
   `volume` or `mount` in the subject.

2. Resolve the kernel:

   ```
   make resolve
   ```

   Expected: a `linux` line naming a commit, via a firmware channel or via `linux rpi-X.Y.y@<sha>, no firmware
   release`. A `die` means the fork has not merged that version. Wait, or hold the bump. See the
   [build runbook](build.md#resolve-the-kernel-by-hand).

3. Diff the pkgs patch set against the last release:

   ```
   OLD=$(gh release download --repo yama6a/talos-raspberry-pi5 --pattern build-inputs.json -O - | jq -r .pkgs_ref)
   NEW=$(jq -r .pkgs_ref .cache/build-inputs.json)
   diff <(gh api "repos/siderolabs/pkgs/contents/kernel/build/patches?ref=$OLD" --jq '.[].name' | sort) \
        <(gh api "repos/siderolabs/pkgs/contents/kernel/build/patches?ref=$NEW" --jq '.[].name' | sort)
   ```

   For every added patch, read its entry in `kernel/build/patches/README.md` at `$NEW`. Then dry-run it
   against the fork commit `make resolve` printed:

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
   | applies cleanly | the fork lacks it | nothing. The build applies it |
   | some hunks fail | a real collision | read both sides. Fork has an equivalent: skip it. Fork lacks it: rebase the patch, or skip it and record what is lost |
   | applies `with fuzz` | the context did not match | treat it as a collision. Fuzz 2 can drop a hunk into a lookalike block |

   For every removed patch, delete its slug from `kernel/patch-skip.txt`.

4. Re-check the reason behind every existing skip entry. The fork rebases, so a reason can go stale:

   ```
   grep -n 'MACB_CAPS_PCIE_POSTED_WRITES\|MACB_CAPS_EEE' drivers/net/ethernet/cadence/macb.h
   grep -n 'tx_pending' drivers/net/ethernet/cadence/macb_main.c
   ```

   Expected: both capability bits defined, and `tx_pending` used in the TSR read path. If the fork dropped
   its own TX-stall recovery, pkgs' watchdog patch is needed again and its skip entry is wrong.

5. Diff the stock config for every symbol the fragment asserts:

   ```
   for r in $OLD $NEW; do curl -fsSL "https://raw.githubusercontent.com/siderolabs/pkgs/$r/kernel/build/config-arm64" -o "config-$r"; done
   for s in $(grep -oE '^CONFIG_[A-Z0-9_]+' kernel/pi5-rpi.fragment); do
     diff <(grep "^$s[= ]\|^# $s " "config-$OLD") <(grep "^$s[= ]\|^# $s " "config-$NEW") && continue
     echo "MOVED: $s"
   done
   ```

   Expected: nothing printed. The fragment wins on `olddefconfig`, but a new dependency can leave a bake-in
   unmet, and only the build shows that.

6. Run preflight:

   ```
   make preflight
   ```

   Expected: `PREFLIGHT PASSED`. The same job runs on the PR.

7. Check what preflight does not. Machinery can add fields without breaking the compile, and the imager can
   change behind a flag that still exists:

   ```
   T=$(grep '^TALOS_VERSION' versions.env | cut -d'"' -f2)
   curl -fsSL "https://raw.githubusercontent.com/siderolabs/talos/$T/pkg/machinery/overlay/overlay.go" | grep -v '^//'
   curl -fsSL "https://raw.githubusercontent.com/siderolabs/talos/$T/Makefile" | grep -E '^(kernel|initramfs|imager|installer-base|installer):'
   curl -fsSL "https://raw.githubusercontent.com/siderolabs/talos/$T/cmd/installer/cmd/imager/root.go" | grep -oE '"(overlay-name|overlay-image|base-installer-image|system-extension-image)"'
   ```

   Expected: `Options` still has `Name` and `KernelArgs`, `InstallOptions` still has `MountPrefix` and
   `ArtifactsPath`, all five targets, all four flags. The overlay's `profiles/rpi5/rpi5.yaml` still says
   `bootloader: grub`. Check the notes for changes to how grub installs or where arm64 grub reads the cmdline.

8. Check the extension constraints. The pins in `versions.env` predate the new minor:

   ```
   for img in $(grep -oE 'ghcr.io/siderolabs/[a-z-]+:[^"]+' versions.env); do
     crane export "$img" - | tar -xO manifest.yaml | grep -A2 compatibility
   done
   ```

   Expected: a `version:` constraint the new Talos meets. The imager refuses an extension that does not, so
   this fails the build, not the node. Renovate brings new extension digests in the combined PR.

9. Validate the cluster's machine configs with the new `talosctl`:

   ```
   talosctl validate --mode metal --config controlplane.yaml
   talosctl validate --mode metal --config worker.yaml
   ```

   Expected: no errors. Deprecation warnings name what to migrate before a later release removes the field.
   Check the notes for removed `talosctl` flags that any script uses.

10. Merge, then watch the build:

    ```
    gh run watch --repo yama6a/talos-raspberry-pi5
    ```

    Expected: `VALIDATION PASSED`, a release tagged `vX.Y.Z-1` and three OCI tags. A red run published
    nothing. Fix it on a branch and merge again.

11. Upgrade one worker, not a control plane node:

    ```
    talosctl upgrade --nodes <worker> --image ghcr.io/yama6a/talos-raspberry-pi5:vX.Y.Z-1
    talosctl -n <worker> version                    # the new tag, kernel label = the resolved version
    talosctl -n <worker> get links end0             # up, 1Gbps
    talosctl -n <worker> get extensions             # iscsi-tools, util-linux-tools
    talosctl -n <worker> reboot                     # comes back from NVMe on its own
    ```

    Then attach a Longhorn volume to a pod pinned to that node and write to it. Only then upgrade the other
    workers, then the control plane nodes one at a time.

12. Roll back if the node misbehaves:

    ```
    talosctl -n <worker> rollback
    ```

    A node that does not come back at all hit the U-Boot failure in [upstream.md](../upstream.md). Reflash
    the previous release's raw image and rejoin the node. For a control plane node, also remove its stale
    etcd member.
