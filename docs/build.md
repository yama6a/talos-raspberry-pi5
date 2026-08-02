# The build

## What runs

| Step | Script | Does |
|---|---|---|
| `make resolve` | `lib/resolve_inputs.sh` | pure HTTP, ~10s. Writes `.cache/build-inputs.json` |
| `make build` | `lib/build.sh` | checkouts, three rebases, kernel, overlay, installer, raw image |
| `make validate` | `lib/validate.sh` | offline checks against the built artifacts |
| `make publish` | `lib/publish.sh` | GHCR push, SBOM, checksums, generated notes |
| `make release` | `lib/release.sh` | the GitHub release, last so nothing strands a tag |

`build.sh` in order:

1. local registry container plus a `docker-container` buildx builder
2. clone `siderolabs/pkgs`, `siderolabs/talos` and `talos-rpi5/sbc-raspberrypi5` at their resolved refs
3. REBASE 1, kernel source and config
4. build the kernel, the long pole
5. REBASE 2, module list
6. REBASE 3, overlay port
7. build the overlay
8. mirror Talos's Dockerfile frontend into the local registry, then build the installer and the raw image

The registry is local (`localhost:5010`) because it is fast, works offline, and supports the BuildKit merge
operation that siderolabs' `bldr` needs. The builder inside dockerd refuses that operation, which is why the
build creates its own `docker-container` builder.

## Prerequisites

- An arm64 host. macOS on Apple Silicon or arm64 Linux. An amd64 host works only under emulation and is
  unusably slow for a kernel build.
- Docker with an arm64 Linux VM, and room for the build. Reserve 60 GB or more; the kernel objdir plus the
  BuildKit snapshots are what fill it.
- GNU make >= 4. macOS ships 3.81, which the upstream Makefiles refuse to run; `brew install make` installs
  it as `gmake` and the build finds it.
- `docker git curl jq go python3 perl`. The build checks and names each one. `xz` and `zstd` are only needed
  inside the validation container, not on the host.

Roughly 40 minutes on an M2 Pro (12 cores), 65 minutes on a 4-core arm64 GitHub runner.

## The build cache

`.cache/<build-key>/` per set of upstream inputs, so bumping a version lands in a fresh directory and the
previous one stays intact. The key hashes the resolved pkgs commit, kernel commit, overlay commit and both
extension digests. It deliberately does NOT cover the build scripts, so editing one reuses the existing
checkouts and downloaded kernel tarball instead of forcing a cold rebuild.

The `fingerprint` in `build-inputs.json` is the stricter one: it covers the recipe files too, and is what CI
compares to decide whether a push needs a rebuild at all.

`make clean` removes the current key's directory, `make distclean` removes `.cache` entirely.

## The three rebases

Things the pinned Talos release and the community overlay cannot do for themselves. All automated.

**1. Kernel source and config.** Point the kernel source at `raspberrypi/linux` at the resolved commit, layer
`kernel/pi5-rpi.fragment` over siderolabs/pkgs' stock arm64 config, and reconcile with `make olddefconfig`
under the real clang toolchain. Every `=y` line in the fragment is then re-asserted against the reconciled
`.config`, so an unmet dependency fails in seconds rather than after a 40-minute compile. Also gates pkgs'
own kernel patches, below. See [kernel.md](kernel.md).

The kernel tarball is downloaded once and served from a local HTTP container for the rest of the build.
GitHub's `/archive/` tarballs are not byte-stable across requests, so a hash taken on the host would not
match what the builder downloads for itself.

**2. Module list.** `talos/hack/modules-arm64.txt` names drivers this config does not build (`bnxt_re` and
friends) and treats `nvme` as a module when it is built in here, so the initramfs step fails on the first
missing `.ko`. The build intersects the list with the module tree the kernel actually produced.

That rewrite is the only change made to the Talos checkout, and it would make `git describe --dirty` report
`-dirty`. That string stamps the OS version, so nodes would report `<version>-dirty` and a clean `talosctl`
would warn it is "older than client", because semver ranks a `-dirty` prerelease below the clean release. The
file is marked `assume-unchanged` so every describe in the build stays clean while the modified content still
feeds the installer.

**3. Overlay port.** The overlay copies U-Boot, `config.txt` and the device trees onto the EFI partition. It
targets older Talos machinery, and a newer overlay API added a `ctx` argument to every method, so it does not
compile as-is. The build bumps its machinery dependency to match the pinned Talos and patches `main.go`.

Each rebase asserts the anchor it edits and fails naming what upstream moved, rather than silently producing
a wrong image.

## The Dockerfile frontend mirror

Talos's Dockerfile opens with a `# syntax =` line naming a frontend image on Docker Hub, and BuildKit allows
60 seconds to resolve it, which it misses often enough to fail whole builds an hour in. So before the
installer stage the build pulls that image through the docker daemon, republishes it to the local registry,
and rewrites the `# syntax =` line to point there. Same motivation as the local kernel source server: nothing
remote sits on the critical path once the build is running, and a re-run works offline.

The rewrite gets the same `assume-unchanged` treatment as the module list, so it cannot make `git describe`
report `-dirty` and stamp that onto the OS version.

## pkgs kernel patches

siderolabs/pkgs carries kernel patches written against vanilla kernel.org. This builds `raspberrypi/linux`,
where some are already merged or collide with the fork's own fix for the same bug. Each patch is dry-run
first: whatever applies is applied, only the slugs in `kernel/patch-skip.txt` are skipped, and anything else
fails the build. So a pkgs bump that adds a patch we cannot apply stops the build instead of quietly dropping
a fix.

A slug is the patch filename minus its `NNNN-` prefix, because pkgs renumbers its patch files. A slug that
matches no patch also fails the build, before the kernel download. The first thing to check there is a
rename: the error prints every slug pkgs currently ships, so a reworded subject is visible side by side.

To re-check the list after a pkgs bump, dry-run each patch against the cached kernel source:

```
KEY=$(jq -r .build_key .cache/build-inputs.json)
SRC=$(mktemp -d) && tar -xzf ".cache/$KEY/srcserve/linux.tar.gz" -C "$SRC" --strip-components=1
for p in ".cache/$KEY/checkouts/pkgs/kernel/build/patches"/*.patch; do
  patch -d "$SRC" -p1 -N --dry-run --silent < "$p" >/dev/null 2>&1 \
    && echo "applies  $(basename "$p")" || echo "CONFLICT $(basename "$p")"
done
```

A conflict is not automatically a skip. Check whether the fork already carries the fix, by grepping for a
symbol the patch adds, before adding it to `patch-skip.txt`.

## Validation

Offline, no hardware. macOS cannot loop-mount Linux filesystems, so both checks run in a Linux container.

- Integrity and size: `xz -t` passes and the compressed image is in a plausible range.
- Partition layout: loop-mount the raw image and confirm `EFI`, `BOOT` and `META`. `STATE` and `EPHEMERAL` do
  not exist yet; first boot creates them.
- Pi 5 boot bits on the EFI partition: `config.txt` with the disable-wifi and disable-bt lines, `u-boot.bin`,
  `bcm2712-rpi-5-b.dtb`, `overlays/disable-{wifi,bt}.dtbo`.
- Kernel: read the installer UKI's `.uname` section and check it against the kernel that was actually
  compiled. A mismatch means a mislabeled image, see [kernel.md](kernel.md).
- Extensions: decompress the UKI's `.initrd` and confirm both extensions are in it.

None of this proves the Pi 5 boot chain works. Only booting a board does.

## Troubleshooting

- `missing separator` in a Makefile: you are on make 3.81. Install GNU make >= 4; the build finds `gmake`.
- `mergeop has been disabled`: the builder inside dockerd cannot run siderolabs' `bldr`. The build creates a
  `docker-container` buildx builder that can, so this means that step was skipped or the builder was deleted.
- `no space left on device` during kernel finalize: the Docker VM disk is too small. Raise it, or set
  `PRUNE_BUILD_CACHE=true` to drop the BuildKit cache once the kernel image is in the local registry.
- `BAKE-IN MISSING: <SYM>`: a config symbol did not survive `olddefconfig`, usually an unmet dependency.
  Adjust `kernel/pi5-rpi.fragment`.
- `cannot stat .../<mod>.ko` at initramfs: the module list drifted. REBASE 2 handles it, so re-run.
- `digest mismatch` on the kernel source: GitHub `/archive/` tarballs are not byte-stable. The local source
  server exists for exactly this. Nothing to do.
- `pkgs checkout describes as X, but Talos names Y`: an upstream tag moved. Re-run `make resolve`.
- `cannot pull docker/dockerfile-upstream from Docker Hub`: the daemon could not fetch Talos's Dockerfile
  frontend. Usually stale stored Hub credentials, which the CLI hands over and then hangs on instead of
  falling back to anonymous. `docker login` fixes it, and so does `docker logout`, because every image this
  build pulls is public. Confirm with `DOCKER_CONFIG=$(mktemp -d) docker pull alpine`, which bypasses them.
- `DeadlineExceeded ... resolving docker.io/docker/dockerfile-upstream` should not happen any more: the
  frontend is mirrored locally before the installer stage. Seeing it means the mirror step was skipped.
- `Directory not empty` from the `checkouts` target on macOS: Finder dropped a fresh `.DS_Store` into a tree
  `rm` was still walking. The target retries, so this only surfaces if it fails three times.

## Reference

- Boot assets and the imager: <https://www.talos.dev/latest/talos-guides/install/boot-assets/>
- Talos upgrades: <https://www.talos.dev/latest/talos-guides/upgrading-talos/>
