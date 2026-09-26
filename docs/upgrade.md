# Upgrading Talos

The checklist for a Talos minor or major is in the [upgrade runbook](runbooks/upgrade.md).

- A patch release is a digest swap and automerges.
- A minor or major never automerges. Renovate labels it `needs-review` and stops, and a person works through
  the runbook.

## What a minor moves

| Input | Pinned by | What a minor can do to it |
|---|---|---|
| kernel version | derived from Talos's `DefaultKernelVersion`, see [kernel.md](kernel.md) | name a patch level no `raspberrypi/firmware` channel carries yet |
| `siderolabs/pkgs` commit | derived from Talos's `PKGS ?=` line | add kernel patches the fork already has, or that collide with it |
| stock kernel config | `config-arm64` at that pkgs commit | move a symbol `kernel/pi5-rpi.fragment` asserts |
| overlay machinery API | `pkg/machinery` at `TALOS_VERSION` | change `overlay.Options`, `InstallOptions` or the adapter signature, so REBASE 3 stops compiling |
| imager and installer | Talos's own Makefile, driven by `build/Makefile.talos` | rename a target, drop a flag, change the boot layout or the cmdline source |
| extensions | digest pins in `versions.env` | tighten the `compatibility.talos.version` constraint |
| machine config defaults | the user's config, nothing here | deprecate v1alpha1 fields, remove `talosctl` flags, add documents to `gen config` |
| the upgrade flow | the node's `machined` running the new installer | change how the installer runs, what it keeps, how it rebuilds the cmdline |

## What CI proves

| Check | preflight | build on main | nothing here |
|---|---|---|---|
| kernel version resolves to a fork commit | yes | | |
| pkgs checkout matches Talos, skip list names real patches | yes | | |
| `pkg.yaml` and Dockerfile rewrites still find their anchors | yes | | |
| overlay compiles against the new machinery | yes | | |
| pkgs patches apply to the fork | | yes | |
| fragment survives `olddefconfig`, kernel compiles | | yes | |
| imager produces an image, UKI label matches, extensions baked | | yes | |
| the board boots, `end0` comes up, NVMe is the root | | | yes |
| an existing node survives the upgrade | | | yes |
| Longhorn attaches a volume afterwards | | | yes |

- A red build on main costs nothing. `build.yaml` publishes and releases only after a green build.
- A bad image on a node costs a reflash and an etcd member removal. See [upstream.md](upstream.md).

## Upgraded nodes versus fresh installs

Talos keeps an upgraded node's machine config. Only `talosctl gen config` picks up new defaults. So the same
image behaves differently depending on how a node got it.

| | Upgraded from an older release | Flashed fresh, config from `gen config` on the new minor |
|---|---|---|
| kernel, drivers, boot chain | the new image's | the new image's |
| machine config | unchanged. Deprecated fields keep working for now | the new minor's defaults and documents |
| new defaults from the release notes | absent until you add the document | present |
| install section | kept, and still the source of the kernel cmdline on grub | absent, the cmdline comes from the UKI |
| test first | one worker, then reboot it | one board, then reboot it |

From Talos 1.14 on:

| | Upgraded | Fresh |
|---|---|---|
| workload isolation (`SecurityProfileConfig`) | off, no document | on. The in-tree iSCSI plugin stops working. Longhorn uses its own CSI driver. Nobody has checked whether Longhorn v1's `iscsiadm` through `nsenter` still reaches the host `iscsid` inside the sandbox. Test it, or set `workloadIsolation: false` |
| filesystem trim (`FilesystemTrimConfig`) | off, no document | weekly. `util-linux-tools` supplies `fstrim` either way |
| install | `.machine.install` kept, cmdline rebuilt from it on every upgrade | `UnattendedInstall` document, cmdline read from the UKI. The imager wrote the overlay's `KernelArgs` into that UKI, so the two agree |
| `noexec` mounts | only STATE, ETCD and LOG | same. `/var` stays `nosuid,nodev` |
| `talosctl apply-config --mode=reboot` | gone. Config applies without a reboot by default | same |
