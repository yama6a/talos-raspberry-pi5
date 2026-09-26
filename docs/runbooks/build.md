# Build runbook

The reasons behind the build are in [build.md](../build.md) and [kernel.md](../kernel.md).

## Prerequisites

- An arm64 host: macOS on Apple Silicon, or arm64 Linux. An amd64 host works only under emulation, which is
  too slow for a kernel build.
- Docker with an arm64 Linux VM and about 60 GB free. The kernel objdir and the BuildKit snapshots fill it.
- GNU make 4 or later. macOS ships 3.81, which the upstream Makefiles refuse. `brew install make` installs it
  as `gmake`, and the build finds it.
- `docker git curl jq go python3 perl crane`. The build names each missing tool. Talos's installer target
  calls `crane`.

A cold build takes about 40 minutes on an M2 Pro and 90 on a 4-core arm64 GitHub runner. With a kernel cache
hit it takes about 8.

## Build locally

1. Check the pins without compiling:

   ```
   make preflight
   ```

   Expected: `PREFLIGHT PASSED`.

2. Build and check the image:

   ```
   make build
   make validate
   ```

   Expected: `VALIDATION PASSED`.

3. Free the disk when done. `make clean` removes the current build's dir. `make distclean` removes `.cache`.

## Re-check the patch skip list

Run this after a pkgs bump, against the cached kernel source.

1. Dry-run every pkgs patch:

   ```
   KEY=$(jq -r .build_key .cache/build-inputs.json)
   SRC=$(mktemp -d) && tar -xzf ".cache/$KEY/srcserve/linux.tar.gz" -C "$SRC" --strip-components=1
   for p in ".cache/$KEY/checkouts/pkgs/kernel/build/patches"/*.patch; do
     patch -d "$SRC" -p1 -N --dry-run --silent < "$p" > /dev/null 2>&1 \
       && echo "applies  $(basename "$p")" || echo "CONFLICT $(basename "$p")"
   done
   ```

2. For each `CONFLICT`, grep the fork for a symbol the patch adds. Add the slug to `kernel/patch-skip.txt`
   only when the fork already carries the fix.

## Resolve the kernel by hand

Run this when `make resolve` finds no `raspberrypi/linux` commit for the version Talos expects.

1. Check what each firmware channel carries:

   ```
   for b in master stable next oldstable; do
     h=$(curl -fsSL "https://raw.githubusercontent.com/raspberrypi/firmware/$b/extra/git_hash" | tr -d '[:space:]')
     v=$(curl -fsSL "https://raw.githubusercontent.com/raspberrypi/linux/$h/Makefile" \
           | awk -F' = ' '/^VERSION/{a=$2}/^PATCHLEVEL/{p=$2}/^SUBLEVEL/{c=$2} END{print a"."p"."c}')
     echo "$b -> $v ($h)"
   done
   ```

2. For older versions, list the firmware commits that changed the linux hash:

   ```
   gh api "repos/raspberrypi/firmware/commits?path=extra/git_hash&sha=master" --jq '.[].sha'
   ```

3. With no firmware ref at all, list the stable merges on the fork branch, newest first:

   ```
   gh api "repos/raspberrypi/linux/commits?sha=rpi-X.Y.y&per_page=100" \
     --jq '.[] | select(.parents | length > 1) | "\(.sha) \(.commit.message | split("\n")[0])"'
   ```

4. Wait for the fork to merge that version, or move `TALOS_VERSION` in `versions.env` to a release whose
   kernel exists. Never pin a nearby kernel. See [kernel.md](../kernel.md).

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `missing separator` in a Makefile | make 3.81 | install GNU make 4 or later |
| `mergeop has been disabled` | the build's own buildx builder is gone | re-run, the build creates it |
| `no space left on device` during kernel finalize | the Docker VM disk is too small | raise it, or set `PRUNE_BUILD_CACHE=true` |
| `BAKE-IN MISSING: <SYM>` | a fragment symbol did not survive `olddefconfig`, usually an unmet dependency | fix `kernel/pi5-rpi.fragment` |
| `cannot stat .../<mod>.ko` at initramfs | the module list drifted | re-run. REBASE 2 handles it |
| `pkgs checkout describes as X, but Talos names Y` | an upstream tag moved | `make resolve`, then re-run |
| `FAILED: pkgs patch does not apply to raspberrypi/linux: <slug>` | a pkgs patch collides with the fork | see below |
| `kernel/patch-skip.txt names a patch that pkgs does not have` | pkgs dropped or renamed it | match the entry to a slug in the error's list |
| `kernel/build/pkg.yaml patch loop not found` or `anchor not found` | upstream restructured a file the build rewrites | re-derive the anchor in `lib/preflight.sh` |
| `grep: write error: Broken pipe`, then the build dies | a pipe into `head -1` or `grep -q` closed early, and `pipefail` failed the build | read the file with an awk that exits, not a pipe |
| `cannot pull docker/dockerfile-upstream from Docker Hub` | stale stored Hub credentials | `docker login` or `docker logout`. Every image here is public |
| `DeadlineExceeded ... resolving docker.io/docker/dockerfile-upstream` | the frontend mirror step did not run | re-run the build |
| `Directory not empty` from `checkouts` on macOS | Finder wrote `.DS_Store` into a tree being removed | re-run. The target retries three times first |

A patch that does not apply:

1. Dry-run it by hand with `patch -p1 -N --dry-run` against the extracted tree.
2. `Reversed (or previously applied)` means the fork already has the fix. Add the slug to
   `kernel/patch-skip.txt`.
3. A real conflict means the patch needs a rebase onto the fork.

`patch` defaults to fuzz 2. So a hunk that reports "applied" can still land on loose context. Read it.

To check for stale Hub credentials: `DOCKER_CONFIG=$(mktemp -d) docker pull alpine` bypasses them.
