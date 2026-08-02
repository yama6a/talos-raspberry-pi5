#!/usr/bin/env bash
# Builds the Pi 5 Talos image: the pinned Talos release rebased onto a raspberrypi/linux kernel, with the
# Pi 5 boot chain and two system extensions baked in. Touches no hardware and publishes nothing; run
# lib/validate.sh next, then lib/publish.sh.
# Three rebases carry the pinned Talos release onto the Pi kernel, see the REBASE markers below and
# docs/build.md. Runs natively on arm64 Linux and macOS/Apple Silicon.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
REGISTRY_PORT="5010"                       # 5001 is often taken by kind
REGISTRY_HOST="localhost:${REGISTRY_PORT}" # local build registry
REGISTRY_USER="talos-rpi5"                 # path component in the local registry
REGISTRY_NAME="talos-registry"             # registry container name
# renovate: datasource=docker
REGISTRY_IMAGE="registry:3"                # local build-registry image
BUILDER_NAME="talos-bx"                    # standalone buildx builder; the one inside dockerd cannot do this build
SRCSERVER_NAME="talos-srcserver"           # local HTTP server for the (non-byte-stable) kernel tarball
SRCSERVER_PORT="8099"
# renovate: datasource=docker
SRCSERVER_IMAGE="nginx:alpine"             # serves the kernel tarball to the build

require docker git curl jq go python3 perl
load_inputs

TALOS_MK="${REPO_ROOT}/build/Makefile.talos"
CHK="${BUILD_DIR}/checkouts"
PKGS_PATCH_SKIP="$(grep -vE '^[[:space:]]*(#|$)' "${REPO_ROOT}/kernel/patch-skip.txt")"

say "checking prerequisites"
case "$(uname -m)" in arm64|aarch64) ;; *) warn "not arm64, the kernel build will be emulated and very slow" ;; esac
GMAKE="$(gnu_make)"
docker info >/dev/null 2>&1 || die "docker not responding (start Docker Desktop / Rancher Desktop, or the docker service)"
GMAKE_DIR="$(dirname "$GMAKE")"
export PATH="${GMAKE_DIR}:${PATH}"   # so a recursive $(MAKE) in the upstream Makefiles is GNU make too
mkdir -p "$BUILD_DIR" "$OUT_DIR"
echo "   build dir  ${BUILD_DIR}"

# `bldr` (siderolabs' build tool) needs BuildKit's merge operation, which stacks image layers without
# re-copying them. The builder built into dockerd refuses it; a standalone docker-container builder supports it.
say "local registry on ${REGISTRY_HOST}"
docker ps --format '{{.Names}}' | grep -qx "$REGISTRY_NAME" || \
  docker run -d --restart=unless-stopped -p "127.0.0.1:${REGISTRY_PORT}:5000" --name "$REGISTRY_NAME" "$REGISTRY_IMAGE" >/dev/null

say "buildx builder ${BUILDER_NAME} (supports BuildKit merge)"
if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
  cfg="$(mktemp)"; printf '[registry."%s"]\n  http = true\n  insecure = true\n' "$REGISTRY_HOST" > "$cfg"
  docker buildx create --name "$BUILDER_NAME" --driver docker-container \
    --driver-opt network=host --buildkitd-config "$cfg" >/dev/null
fi
docker buildx use "$BUILDER_NAME"
docker buildx inspect --bootstrap "$BUILDER_NAME" >/dev/null

say "checkouts: talos ${TALOS_VERSION}, pkgs ${PKGS_DESC}, overlay ${SBCOVERLAY_VERSION:0:12}"
"$GMAKE" -f "$TALOS_MK" CHECKOUTS="$CHK" \
  TALOS_VERSION="$TALOS_VERSION" PKGS_REF="$PKGS_REF" SBCOVERLAY_VERSION="$SBCOVERLAY_VERSION" checkouts

# The resolver read PKGS from Talos's Makefile over HTTP; the clone is the ground truth. If they disagree the
# tag moved under us, and a few commits of pkgs drift propagate through the kernel image tag, the overlay and
# the installer, so stop here.
GOT=$(git -C "$CHK/pkgs" describe --tag --always --match 'v[0-9]*')
[ "$GOT" = "$PKGS_DESC" ] || die "pkgs checkout describes as ${GOT}, but Talos ${TALOS_VERSION} names ${PKGS_DESC}"

# Fail here, seconds in, rather than mid-kernel-build if a skip entry has gone stale.
PKGS_PATCH_SLUGS=$(for f in "$CHK/pkgs/kernel/build/patches"/*.patch; do
  [ -e "$f" ] || continue
  s=$(basename "$f" .patch); case "$s" in [0-9]*-*) s=${s#*-} ;; esac; printf '%s\n' "$s"
done)
while read -r slug; do
  [ -n "$slug" ] || continue
  printf '%s\n' "$PKGS_PATCH_SLUGS" | grep -qxF "$slug" && continue
  die "kernel/patch-skip.txt names a patch that pkgs ${PKGS_DESC} does not have: '${slug}'. Either pkgs dropped it, so
delete the entry, or pkgs reworded its subject, so update the entry to whichever of these is the same patch:
${PKGS_PATCH_SLUGS}"
done <<< "$PKGS_PATCH_SKIP"

# ---- REBASE 1: kernel source + Pi 5 config + patch gating -------------------
# pkgs ships a stock arm64 config (already 4K pages). We point the kernel source at raspberrypi/linux, for
# the RP1 and BCM2712 drivers that exist only in that fork, layer a small fragment on top, and let the
# kernel's own `olddefconfig` fill in everything we did not set, under the real clang toolchain.
say "REBASE 1, kernel source -> raspberrypi/linux ${KERNEL_COMMIT:0:12} (${KERNEL_VERSION}, from ${KERNEL_SOURCE}) + Pi 5 fragment"

# GitHub's /archive/ tarballs are NOT byte-stable (different CDN nodes serve different gzip), so the sha bldr
# downloads can differ from one we hash here. Download once and serve it locally so bldr fetches exactly the
# bytes we hashed.
# Reused across re-runs: the commit is part of BUILD_KEY, so a cached tarball in this dir can only be the
# right one, and the version check below still runs on it. Saves re-fetching ~250 MB every run.
SRCDIR="${BUILD_DIR}/srcserve"; mkdir -p "$SRCDIR"
if [ -s "$SRCDIR/linux.tar.gz" ]; then
  echo "   reusing the cached kernel tarball"
else
  curl -fL --retry 3 --no-progress-meter -o "${SRCDIR}/linux.tar.gz.part" \
    "https://github.com/raspberrypi/linux/archive/${KERNEL_COMMIT}.tar.gz"
  mv "${SRCDIR}/linux.tar.gz.part" "$SRCDIR/linux.tar.gz"
fi
# Guards a resolver bug: the fetched tree's own Makefile version MUST be what Talos expects.
SRCVER=$(tar -xzOf "$SRCDIR/linux.tar.gz" "linux-${KERNEL_COMMIT}/Makefile" 2>/dev/null \
  | awk -F' *= *' '/^VERSION/{v=$2} /^PATCHLEVEL/{p=$2} /^SUBLEVEL/{s=$2} END{print v"."p"."s}')
[ "$SRCVER" = "$KERNEL_VERSION" ] || die "the tarball at ${KERNEL_COMMIT} is linux ${SRCVER:-unknown}, expected ${KERNEL_VERSION} (Talos ${TALOS_VERSION}), so this is probably a resolver bug"
KSHA256=$(sha256hex "$SRCDIR/linux.tar.gz")
KSHA512=$(sha512hex "$SRCDIR/linux.tar.gz")
docker rm -f "$SRCSERVER_NAME" >/dev/null 2>&1 || true
trap 'docker rm -f "$SRCSERVER_NAME" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$SRCSERVER_NAME" -p "127.0.0.1:${SRCSERVER_PORT}:80" \
  -v "$SRCDIR:/usr/share/nginx/html:ro" "$SRCSERVER_IMAGE" >/dev/null

# Pkgfile: pin the kernel version + the local file's hashes.
perl -0pi -e "s/  linux_version: .*\n  linux_sha256: .*\n  linux_sha512: .*\n/  linux_version: ${KERNEL_COMMIT}\n  linux_sha256: ${KSHA256}\n  linux_sha512: ${KSHA512}\n/" "$CHK/pkgs/Pkgfile"
# Fetch from the locally-served tarball instead of cdn.kernel.org, and extract it as .tar.gz.
# The pattern uses .* rather than \S+ because the stock cdn URL has spaces inside a {{ }} template.
perl -0pi -e 's{- url: https://cdn\.kernel\.org/.*\.tar\.xz\n\s+destination: linux\.tar\.xz}{- url: "http://localhost:'"${SRCSERVER_PORT}"'/linux.tar.gz"\n        destination: linux.tar.gz}' "$CHK/pkgs/kernel/prepare/pkg.yaml"
perl -i -pe 's/tar -xJf linux\.tar\.xz/tar -xzf linux.tar.gz/' "$CHK/pkgs/kernel/prepare/pkg.yaml"
grep -q 'localhost:'"${SRCSERVER_PORT}" "$CHK/pkgs/kernel/prepare/pkg.yaml" || die "kernel source URL rewrite failed"

cp "${REPO_ROOT}/kernel/pi5-rpi.fragment" "$CHK/pkgs/kernel/build/pi5-rpi.fragment"
# The symbols the fragment must actually deliver after olddefconfig reconciles it. Read from the fragment so
# the two cannot drift: every `CONFIG_X=y` line becomes an assertion inside the build container.
BAKEINS=$(grep -oE '^CONFIG_[A-Z0-9_]+=y' "${REPO_ROOT}/kernel/pi5-rpi.fragment" | tr '\n' ' ')

# pkgs' kernel patches target vanilla kernel.org; we build raspberrypi/linux, where some are already merged
# or collide. Gate each on a dry-run: apply what applies, skip only what patch-skip.txt names, fail on
# anything else, so a pkgs bump that adds a patch we cannot apply stops the build instead of dropping a fix.
python3 - "$CHK/pkgs/kernel/build/pkg.yaml" "$(printf '%s' "$PKGS_PATCH_SKIP" | tr '\n' ' ')" <<'PY'
import sys
p,skip=sys.argv[1],sys.argv[2].strip()
s=open(p).read()
anchor='''          patch -p1 < $patch || (echo "Failed to apply patch $patch" && exit 1)
          echo "Applied patch $patch"
'''
block=f'''          slug=$(basename $patch .patch); case "$slug" in [0-9]*-*) slug=${{slug#*-}} ;; esac
          if patch -p1 -N --dry-run --silent < $patch >/dev/null 2>&1; then
            patch -p1 -N < $patch
            echo "Applied patch $slug"
          elif echo "{skip}" | tr ' ' '\\n' | grep -qxF "$slug"; then
            echo "Skipped patch $slug (kernel/patch-skip.txt)"
          else
            echo "FAILED: pkgs patch does not apply to raspberrypi/linux: $slug"
            echo "  pkgs patches target kernel.org, we build the rpi fork, so collisions are expected"
            echo "  fix already in the rpi tree -> add '$slug' to kernel/patch-skip.txt"
            echo "  fix genuinely missing       -> rebase the patch onto the rpi tree, or skip it deliberately"
            echo "  rejects: /src/**/*.rej"
            exit 1
          fi
'''
assert anchor in s, "kernel/build/pkg.yaml patch loop not found (upstream changed?)"
open(p,"w").write(s.replace(anchor, block, 1))
PY

# Merge the fragment, reconcile with olddefconfig, then verify every bake-in before compiling, so an unmet
# dependency fails in seconds rather than after a 40-minute build.
python3 - "$CHK/pkgs/kernel/build/pkg.yaml" "$BAKEINS" <<'PY'
import sys
p,bakeins=sys.argv[1],sys.argv[2].split()
s=open(p).read()
anchor="        cp -v /pkg/config-${CARCH} .config\n        cp -v /pkg/certs/* certs/\n"
checks=" \\\n            ".join(bakeins)
block=anchor+f'''        if [ "${{CARCH}}" = "arm64" ] && [ -f /pkg/pi5-rpi.fragment ]; then
          cat /pkg/pi5-rpi.fragment >> .config
          make ARCH="${{ARCH}}" LLVM=1 olddefconfig
          for s in \\
            {checks} ; do
            grep -qx "$s" .config || {{ echo "BAKE-IN MISSING: $s"; exit 1; }}
          done
          grep -qx '# CONFIG_ARM64_16K_PAGES is not set' .config || {{ echo "ERROR: 16K pages set"; exit 1; }}
          echo ">> Pi 5 kernel config reconciled and bake-ins verified"
        fi
'''
assert anchor in s, "kernel/build/pkg.yaml anchor not found (upstream changed?)"
open(p,"w").write(s.replace(anchor, block, 1))
PY

say "build kernel (clang/ThinLTO, the long pole; verifies bake-ins early then compiles)"
"$GMAKE" -f "$TALOS_MK" CHECKOUTS="$CHK" REGISTRY="$REGISTRY_HOST" REGISTRY_USERNAME="$REGISTRY_USER" kernel

# ---- REBASE 2: module list -------------------------------------------------
# The stock list names drivers our config does not build (bnxt_re and friends), and nvme is built in rather
# than a module, so the initramfs step fails on the first missing .ko. Intersect it with the real module tree.
# The kernel image is in the local registry now, so BuildKit's cache is disposable, and it is where the tens
# of GB sit. CI sets this because a GitHub runner can be as small as ~37 GB free; locally leave it off so a
# re-run does not recompile.
if [ "${PRUNE_BUILD_CACHE:-false}" = "true" ]; then
  say "pruning the BuildKit cache (PRUNE_BUILD_CACHE)"
  docker buildx prune -af >/dev/null 2>&1 || true
  df -h "$BUILD_DIR" | tail -1
fi

say "REBASE 2, filter modules-arm64.txt to modules the kernel actually built"
PKGS_TAG=$(cd "$CHK/pkgs" && git describe --tag --always --dirty --match 'v[0-9]*')
KIMG="${REGISTRY_HOST}/${REGISTRY_USER}/kernel:${PKGS_TAG}"
docker pull -q "$KIMG" >/dev/null
cid=$(docker create "$KIMG" sh); docker export "$cid" 2>/dev/null | tar t 2>/dev/null > "$BUILD_DIR/kfiles.txt"; docker rm "$cid" >/dev/null
KVER=$(grep -oE 'usr/lib/modules/[^/]+' "$BUILD_DIR/kfiles.txt" | head -1 | cut -d/ -f4)
[ -n "$KVER" ] || die "no module tree in ${KIMG}; the kernel build produced no modules"
grep "usr/lib/modules/${KVER}/" "$BUILD_DIR/kfiles.txt" | sed "s#usr/lib/modules/${KVER}/##" | grep -vE '/$' | sort -u > "$BUILD_DIR/kexist.txt"
MF="$CHK/talos/hack/modules-arm64.txt"
grep -Fxf "$BUILD_DIR/kexist.txt" "$MF" > "$MF.new" && mv "$MF.new" "$MF"
# This rewrite is the ONLY change to the talos checkout, but it makes `git describe --dirty` report `-dirty`,
# and that string stamps the OS version (--build-arg=TAG), so nodes would report <version>-dirty and a clean
# talosctl would warn it is "older than client" (semver ranks a -dirty prerelease below the clean release).
# Mark the file assume-unchanged so every describe in the build stays clean; the modified content still feeds
# the installer build. Idempotent across re-runs.
git -C "$CHK/talos" update-index --assume-unchanged hack/modules-arm64.txt
echo "   modules list pinned to kernel ${KVER}"

# The kernel config, for the release. Both halves rather than a reconciled dump: the reconciled .config only
# exists inside a build stage that ships nothing, and `stock + fragment + olddefconfig` is the complete and
# reproducible statement of what was compiled anyway.
cp "$CHK/pkgs/kernel/build/config-arm64" "$OUT_DIR/kernel-config-arm64.base"
cp "${REPO_ROOT}/kernel/pi5-rpi.fragment" "$OUT_DIR/kernel-config-arm64.fragment"

# ---- REBASE 3: overlay port ------------------------------------------------
# The overlay copies u-boot, config.txt and the dtbs onto the EFI partition. It targets older machinery, and
# a newer Talos's overlay API added a ctx argument to every method, so it will not compile as-is.
say "REBASE 3, port sbc-raspberrypi5 overlay to machinery ${MACHINERY_VERSION}"
OSRC="$CHK/sbc-raspberrypi5/installers/rpi5/src"
( cd "$OSRC" && GOWORK=off GOFLAGS=-mod=mod go get "github.com/siderolabs/talos/pkg/machinery@${MACHINERY_VERSION}" && GOWORK=off go mod tidy )
perl -i -pe 's/adapter\.Execute\(&RpiInstaller\{\}\)/adapter.Execute(context.Background(), &RpiInstaller{})/' "$OSRC/main.go"
perl -i -pe 's/func \(i \*RpiInstaller\) GetOptions\(extra/func (i *RpiInstaller) GetOptions(_ context.Context, extra/' "$OSRC/main.go"
perl -i -pe 's/func \(i \*RpiInstaller\) Install\(options/func (i *RpiInstaller) Install(_ context.Context, options/' "$OSRC/main.go"
grep -q '"context"' "$OSRC/main.go" || perl -0pi -e 's/(import \(\n)/$1\t"context"\n/' "$OSRC/main.go"
( cd "$OSRC" && GOWORK=off CGO_ENABLED=0 go build -o /dev/null . ) || die "overlay does not compile against ${MACHINERY_VERSION}"

say "build overlay"
"$GMAKE" -f "$TALOS_MK" CHECKOUTS="$CHK" REGISTRY="$REGISTRY_HOST" REGISTRY_USERNAME="$REGISTRY_USER" overlay

# Talos's Dockerfile names a `# syntax =` frontend image that BuildKit fetches from Docker Hub, with a 60s
# deadline it misses often enough to fail whole builds. Same fix as the kernel tarball: pull it once through
# the docker daemon, republish it to the local registry, and point the Dockerfile there. The build stops
# depending on Hub reachability at that moment, and works offline on a re-run.
DOCKERFILE="$CHK/talos/Dockerfile"
UPSTREAM_FRONTEND=$(awk 'NR==1 && /^#[[:space:]]*syntax[[:space:]]*=/{print $NF}' "$DOCKERFILE")
[ -n "$UPSTREAM_FRONTEND" ] || die "no '# syntax =' on line 1 of the talos Dockerfile (upstream changed?)"
LOCAL_FRONTEND="${REGISTRY_HOST}/${REGISTRY_USER}/dockerfile-frontend:$(printf '%s' "$UPSTREAM_FRONTEND" | sha256hex | cut -c1-12)"
say "mirror the Dockerfile frontend ${UPSTREAM_FRONTEND} -> local registry"
if ! docker pull -q "$UPSTREAM_FRONTEND" >/dev/null 2>&1; then
  # Stale stored Docker Hub credentials are the usual cause, and docker does not fall back on its own. The
  # image is public, so retry with the credentials stripped rather than making the user fix their keychain.
  warn "authenticated pull failed; retrying anonymously (your stored Docker Hub credentials look stale, 'docker login' would fix them)"
  ANON_CFG="$(mktemp -d)"
  jq 'del(.credsStore) | del(.credHelpers) | .auths = {}' "${DOCKER_CONFIG:-${HOME}/.docker}/config.json" \
    > "${ANON_CFG}/config.json" 2>/dev/null || printf '{}' > "${ANON_CFG}/config.json"
  for d in contexts cli-plugins; do
    [ -e "${DOCKER_CONFIG:-${HOME}/.docker}/$d" ] && ln -s "${DOCKER_CONFIG:-${HOME}/.docker}/$d" "${ANON_CFG}/$d"
  done
  DOCKER_CONFIG="$ANON_CFG" docker pull -q "$UPSTREAM_FRONTEND" >/dev/null \
    || die "cannot pull ${UPSTREAM_FRONTEND} from Docker Hub, authenticated or anonymously (is Hub reachable?)"
fi
docker tag "$UPSTREAM_FRONTEND" "$LOCAL_FRONTEND"
docker push -q "$LOCAL_FRONTEND" >/dev/null || die "cannot push ${LOCAL_FRONTEND} to the local registry"
perl -i -pe "s{^#\\s*syntax\\s*=.*}{# syntax = ${LOCAL_FRONTEND}}" "$DOCKERFILE"
# Same reason as modules-arm64.txt above: keep `git describe` clean so the OS version is not stamped -dirty.
git -C "$CHK/talos" update-index --assume-unchanged Dockerfile

say "build installer + imager -> raw disk image (grub/rpi5 profile)"
"$GMAKE" -f "$TALOS_MK" CHECKOUTS="$CHK" REGISTRY="$REGISTRY_HOST" REGISTRY_USERNAME="$REGISTRY_USER" \
  EXTENSIONS="${ISCSI_EXT} ${UTIL_EXT}" installer

# The imager writes under the metal name even on the rpi5 profile; glob as a fallback so an upstream rename
# does not silently look like a build failure.
IMAGER_RAW_XZ="$CHK/talos/_out/metal-arm64.raw.xz"
if [ ! -f "$IMAGER_RAW_XZ" ]; then
  IMAGER_RAW_XZ=$(find "$CHK/talos/_out" -maxdepth 1 -name '*.raw.xz' | head -1)
  [ -n "$IMAGER_RAW_XZ" ] || die "the imager produced no .raw.xz in $CHK/talos/_out"
  warn "imager output is $(basename "$IMAGER_RAW_XZ"), not metal-arm64.raw.xz"
fi
cp "$IMAGER_RAW_XZ" "${OUT_DIR}/${IMAGE_NAME}"

TALOS_TAG=$(cd "$CHK/talos" && git describe --tag --always --dirty --match 'v[0-9]*')
SBCOVERLAY_TAG=$(cd "$CHK/sbc-raspberrypi5" && git describe --tag --always --dirty)-${PKGS_TAG}

# What only the build knows. validate.sh and publish.sh read this back.
cat > "$META_FILE" <<EOF
KVER="${KVER}"
PKGS_TAG="${PKGS_TAG}"
TALOS_TAG="${TALOS_TAG}"
SBCOVERLAY_TAG="${SBCOVERLAY_TAG}"
KERNEL_TARBALL_SHA256="${KSHA256}"
INSTALLER_IMG="${REGISTRY_HOST}/${REGISTRY_USER}/installer:${TALOS_TAG}-arm64"
IMAGE_FILE="${OUT_DIR}/${IMAGE_NAME}"
EOF

say "BUILD COMPLETE"
echo "   image:     ${OUT_DIR}/${IMAGE_NAME}"
echo "   installer: ${REGISTRY_HOST}/${REGISTRY_USER}/installer:${TALOS_TAG}-arm64  (local registry)"
echo "   kernel:    ${KVER}"
echo "   next:      make validate"
