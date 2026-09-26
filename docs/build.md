# The build

Procedures, prerequisites and troubleshooting are in the [build runbook](runbooks/build.md).

## Steps

| Target | Script | Does |
|---|---|---|
| `make resolve` | `lib/resolve_inputs.sh` | HTTP only. Writes `.cache/build-inputs.json` |
| `make preflight` | `lib/preflight.sh` | the checks that need no Docker and no kernel |
| `make build` | `lib/build.sh` | checkouts, three rebases, kernel, overlay, installer, raw image |
| `make validate` | `lib/validate.sh` | offline checks on the built artifacts |
| `make publish` | `lib/publish.sh` | GHCR push, SBOM, checksums, release notes |
| `make release` | `lib/release.sh` | the GitHub release, last so a failed run strands no tag |

## Local registry and builder

- The build runs its own registry on `localhost:5010` and its own `docker-container` buildx builder.
- siderolabs' `bldr` needs BuildKit's merge operation. The builder inside dockerd refuses it.
- A local registry is also fast and works offline on a re-run.

## Nothing remote on the critical path

- GitHub's `/archive/` tarballs are not byte-stable across requests. So the build downloads the kernel
  source once and serves it from a local container. `bldr` then hashes the same bytes the build did.
- BuildKit resolves Talos's Dockerfile frontend from Docker Hub with a 60-second deadline, and misses it
  often enough to fail builds an hour in. So the build mirrors that image into the local registry first.

## Preflight scope

- `lib/preflight.sh` is also `build.sh`'s library. `build.sh` sources it, so a preflight check cannot drift
  from the build.
- Preflight skips everything that needs the kernel tree: patch replay, `olddefconfig`, the compile, the
  imager. Those only mean something inside the pkgs toolchain.
- The failure they would catch costs one red `build` workflow. `build.yaml` publishes and releases only after
  a green build, so a bad bump never ships.
- `.github/workflows/preflight.yaml` runs preflight on any PR that moves a pin. `ci.yaml`'s `main-is-green`
  job fails a PR while main's last `build` run is red.
- Renovate waits for both before it merges the combined non-major PR. A Talos minor or major never
  automerges. A person reviews it with the [upgrade runbook](runbooks/upgrade.md).
- Branch protection enforces neither check. A person can merge past them, Renovate cannot.

## Caches

| Key | Covers | Used for |
|---|---|---|
| `build_key` | upstream inputs only | the `.cache/<build_key>/` dir. A script edit reuses checkouts and the kernel tarball |
| `fingerprint` | upstream inputs plus the recipe files | CI's decision to rebuild at all. See [releases.md](releases.md) |
| `kernel_key` | pkgs commit, linux commit, fragment, `patch-skip.txt` | the kernel cache below |

- **Kernel cache**: a cold kernel compile takes over an hour, and CI runners are ephemeral. So after a
  compile the build pushes the kernel image to `ghcr.io/<owner>/<repo>:kernel-<kernel_key>`. A later run
  with the same key pulls it and skips the compile.
- The kernel cache is best-effort. A missing token skips the push, and a miss only costs compile time.
  `KERNEL_CACHE=false` forces a compile.
- A wrong `kernel_key` cannot ship a mislabeled image. Validation checks the UKI label against the kernel
  that was built.
- **BuildKit cache**: `PRUNE_BUILD_CACHE=true` prunes only when free space is under `PRUNE_BELOW_MB`. A
  retry then keeps the cache that makes it cheap.

## The three rebases

The pinned Talos release and the community overlay cannot do these for themselves. Each rebase checks the
anchor it edits and fails naming what upstream moved.

1. **Kernel source and config.** Point pkgs' kernel recipe at `raspberrypi/linux`, layer the fragment, and
   check every bake-in after `olddefconfig`. An unmet dependency then fails in seconds, not after the compile.
   See [kernel.md](kernel.md).
2. **Module list.** Talos's arm64 module list names drivers this config does not build, and `nvme` is built
   in. The build intersects the list with the real module tree.
3. **Overlay port.** The community overlay targets older Talos machinery. The build bumps its machinery
   dependency and patches `main.go` so it compiles.

- The Talos checkout edits are marked `assume-unchanged`. A dirty tree would stamp `-dirty` onto the OS
  version, and `talosctl` would then call a clean release "older than client".

## pkgs kernel patches

- pkgs writes its kernel patches against vanilla kernel.org. Some are already in `raspberrypi/linux`, or
  collide with the fork's own fix for the same bug.
- The build dry-runs each patch. It applies what applies, skips only the slugs in `kernel/patch-skip.txt`,
  and fails on anything else. So a pkgs bump that adds a patch this build cannot apply stops the build and
  does not drop the fix.
- A slug is the patch filename without its `NNNN-` prefix, because pkgs renumbers its files. A slug that
  matches no patch fails the build before the kernel download.
- To re-check the skip list after a pkgs bump, see the [build runbook](runbooks/build.md#re-check-the-patch-skip-list).

## Validation

Offline, no hardware. The checks run in a Linux container, because macOS cannot loop-mount Linux filesystems.

- `xz -t` passes and the compressed size is plausible.
- The raw image has the `EFI`, `BOOT` and `META` partitions. First boot creates `STATE` and `EPHEMERAL`.
- The EFI partition holds `config.txt` with Wi-Fi and Bluetooth off, `u-boot.bin`, `bcm2712-rpi-5-b.dtb`
  and both `.dtbo` overlays.
- The installer UKI's `.uname` equals the kernel that was compiled.
- The UKI's initrd holds both extensions.

None of this proves the Pi 5 boot chain works. Only booting a board does.
