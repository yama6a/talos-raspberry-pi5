#!/usr/bin/env bash
# Builds the Pi 5 Talos image: the pinned Talos release rebased onto a raspberrypi/linux kernel, with the Pi 5
# boot chain and two system extensions baked in. Runs natively on arm64 Linux and macOS/Apple Silicon.
# The three rebases are the whole trick; see docs/build.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
REGISTRY_PORT="5010"                       # 5001 is often taken by kind
REGISTRY_HOST="localhost:${REGISTRY_PORT}" # local build registry
REGISTRY_USER="talos-rpi5"                 # path component in the local registry
REGISTRY_NAME="talos-registry"             # registry container name
# renovate: datasource=docker
REGISTRY_IMAGE="registry:3"
BUILDER_NAME="talos-bx"                    # standalone buildx builder; the one inside dockerd cannot do this build
SRCSERVER_NAME="talos-srcserver"           # local HTTP server for the (non-byte-stable) kernel tarball
SRCSERVER_PORT="8099"
# renovate: datasource=docker
SRCSERVER_IMAGE="nginx:alpine"

# ---- state ----
GMAKE=""            # set by check_prerequisites
TALOS_MK=""         # set by derive_paths, after load_inputs supplies BUILD_DIR
CHK=""
PKGS_PATCH_SKIP=""
SRCDIR=""           # set by fetch_kernel_source
KSHA256=""
KSHA512=""
BAKEINS=""          # set by stage_kernel_config
PKGS_TAG=""         # set by resolve_kernel_image_refs
KIMG=""
KERNEL_CACHE_REF=""
KVER=""             # set by filter_module_list, the kernel the build actually produced
TALOS_TAG=""        # set by write_build_meta
SBCOVERLAY_TAG=""

# ---- functions ----

derive_paths() {
  TALOS_MK="${REPO_ROOT}/build/Makefile.talos"
  CHK="${BUILD_DIR}/checkouts"
  PKGS_PATCH_SKIP="$(grep -vE '^[[:space:]]*(#|$)' "${REPO_ROOT}/kernel/patch-skip.txt")"
}

check_prerequisites() {
  local gmake_dir
  say "checking prerequisites"
  case "$(uname -m)" in arm64|aarch64) ;; *) warn "not arm64, the kernel build will be emulated and very slow" ;; esac
  GMAKE="$(gnu_make)"
  docker info >/dev/null 2>&1 || die "docker not responding (start Docker Desktop / Rancher Desktop, or the docker service)"
  gmake_dir="$(dirname "$GMAKE")"
  export PATH="${gmake_dir}:${PATH}"   # so a recursive $(MAKE) in the upstream Makefiles is GNU make too
  mkdir -p "$BUILD_DIR" "$OUT_DIR"
  echo "   build dir  ${BUILD_DIR}"
}

# `bldr` (siderolabs' build tool) needs BuildKit's merge operation, which the builder built into dockerd
# refuses; a standalone docker-container builder supports it.
start_local_registry() {
  say "local registry on ${REGISTRY_HOST}"
  # Filter in the daemon rather than `docker ps | grep -q`, which can SIGPIPE docker ps and, under pipefail,
  # read as "absent" and then fail on a name collision.
  [ -n "$(docker ps -q -f "name=^${REGISTRY_NAME}$")" ] || \
    docker run -d --restart=unless-stopped -p "127.0.0.1:${REGISTRY_PORT}:5000" --name "$REGISTRY_NAME" "$REGISTRY_IMAGE" >/dev/null
}

start_buildx_builder() {
  local cfg
  say "buildx builder ${BUILDER_NAME} (supports BuildKit merge)"
  if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
    cfg="$(mktemp)"; printf '[registry."%s"]\n  http = true\n  insecure = true\n' "$REGISTRY_HOST" > "$cfg"
    docker buildx create --name "$BUILDER_NAME" --driver docker-container \
      --driver-opt network=host --buildkitd-config "$cfg" >/dev/null
  fi
  docker buildx use "$BUILDER_NAME"
  docker buildx inspect --bootstrap "$BUILDER_NAME" >/dev/null
}

clone_upstream() {
  say "checkouts: talos ${TALOS_VERSION}, pkgs ${PKGS_DESC}, overlay ${SBCOVERLAY_VERSION:0:12}"
  "$GMAKE" -f "$TALOS_MK" CHECKOUTS="$CHK" \
    TALOS_VERSION="$TALOS_VERSION" PKGS_REF="$PKGS_REF" SBCOVERLAY_VERSION="$SBCOVERLAY_VERSION" checkouts
}

# The resolver read PKGS from Talos's Makefile over HTTP; the clone is the ground truth. A few commits of pkgs
# drift propagate through the kernel image tag, the overlay and the installer, so stop if they disagree.
assert_pkgs_matches_resolver() {
  local got
  got="$(git -C "$CHK/pkgs" describe --tag --always --match 'v[0-9]*')"
  [ "$got" = "$PKGS_DESC" ] || die "pkgs checkout describes as ${got}, but Talos ${TALOS_VERSION} names ${PKGS_DESC}"
}

# Fail seconds in rather than mid-kernel-build if a skip entry has gone stale.
assert_patch_skips_exist() {
  local slugs slug f s
  slugs="$(for f in "$CHK/pkgs/kernel/build/patches"/*.patch; do
    [ -e "$f" ] || continue
    s="$(basename "$f" .patch)"; case "$s" in [0-9]*-*) s="${s#*-}" ;; esac; printf '%s\n' "$s"
  done)"
  while read -r slug; do
    [ -n "$slug" ] || continue
    printf '%s\n' "$slugs" | grep -qxF "$slug" && continue
    die "kernel/patch-skip.txt names a patch that pkgs ${PKGS_DESC} does not have: '${slug}'. Either pkgs dropped it, so
delete the entry, or pkgs reworded its subject, so update the entry to whichever of these is the same patch:
${slugs}"
  done <<< "$PKGS_PATCH_SKIP"
}

# GitHub's /archive/ tarballs are NOT byte-stable (different CDN nodes serve different gzip), so bldr's own
# download can hash differently from ours. Fetch once, serve it locally, and bldr gets exactly the bytes we
# hashed. Reused across re-runs: the commit is part of BUILD_KEY, so a cached tarball here can only be the
# right one, and the version check below still runs on it.
fetch_kernel_source() {
  local srcver
  SRCDIR="${BUILD_DIR}/srcserve"; mkdir -p "$SRCDIR"
  if [ -s "$SRCDIR/linux.tar.gz" ]; then
    echo "   reusing the cached kernel tarball"
  else
    curl -fL --retry 3 --no-progress-meter -o "${SRCDIR}/linux.tar.gz.part" \
      "https://github.com/raspberrypi/linux/archive/${KERNEL_COMMIT}.tar.gz"
    mv "${SRCDIR}/linux.tar.gz.part" "$SRCDIR/linux.tar.gz"
  fi
  # Guards a resolver bug: the fetched tree's own Makefile version MUST be what Talos expects.
  srcver="$(tar -xzOf "$SRCDIR/linux.tar.gz" "linux-${KERNEL_COMMIT}/Makefile" 2>/dev/null \
    | awk -F' *= *' '/^VERSION/{v=$2} /^PATCHLEVEL/{p=$2} /^SUBLEVEL/{s=$2} END{print v"."p"."s}')"
  [ "$srcver" = "$KERNEL_VERSION" ] || die "the tarball at ${KERNEL_COMMIT} is linux ${srcver:-unknown}, expected ${KERNEL_VERSION} (Talos ${TALOS_VERSION}), so this is probably a resolver bug"
  KSHA256="$(sha256hex "$SRCDIR/linux.tar.gz")"
  KSHA512="$(sha512hex "$SRCDIR/linux.tar.gz")"
}

serve_kernel_source() {
  docker rm -f "$SRCSERVER_NAME" >/dev/null 2>&1 || true
  trap 'docker rm -f "$SRCSERVER_NAME" >/dev/null 2>&1 || true' EXIT
  docker run -d --name "$SRCSERVER_NAME" -p "127.0.0.1:${SRCSERVER_PORT}:80" \
    -v "$SRCDIR:/usr/share/nginx/html:ro" "$SRCSERVER_IMAGE" >/dev/null
}

# pkgs ships a stock arm64 config. Point the kernel source at raspberrypi/linux, for the RP1 and BCM2712
# drivers that exist only in that fork, and fetch it from the local server instead of cdn.kernel.org.
point_pkgs_at_rpi_kernel() {
  perl -0pi -e "s/  linux_version: .*\n  linux_sha256: .*\n  linux_sha512: .*\n/  linux_version: ${KERNEL_COMMIT}\n  linux_sha256: ${KSHA256}\n  linux_sha512: ${KSHA512}\n/" "$CHK/pkgs/Pkgfile"
  # .* rather than \S+ because the stock cdn URL has spaces inside a {{ }} template.
  perl -0pi -e 's{- url: https://cdn\.kernel\.org/.*\.tar\.xz\n\s+destination: linux\.tar\.xz}{- url: "http://localhost:'"${SRCSERVER_PORT}"'/linux.tar.gz"\n        destination: linux.tar.gz}' "$CHK/pkgs/kernel/prepare/pkg.yaml"
  perl -i -pe 's/tar -xJf linux\.tar\.xz/tar -xzf linux.tar.gz/' "$CHK/pkgs/kernel/prepare/pkg.yaml"
  grep -q 'localhost:'"${SRCSERVER_PORT}" "$CHK/pkgs/kernel/prepare/pkg.yaml" || die "kernel source URL rewrite failed"
}

stage_kernel_config() {
  cp "${REPO_ROOT}/kernel/pi5-rpi.fragment" "$CHK/pkgs/kernel/build/pi5-rpi.fragment"
  # Read from the fragment so the two cannot drift: every `CONFIG_X=y` line becomes an assertion inside the
  # build container, checked after olddefconfig reconciles the merge.
  BAKEINS="$(grep -oE '^CONFIG_[A-Z0-9_]+=y' "${REPO_ROOT}/kernel/pi5-rpi.fragment" | tr '\n' ' ')"
}

# pkgs' kernel patches target vanilla kernel.org; we build raspberrypi/linux, where some are already merged or
# collide. Gate each on a dry-run: apply what applies, skip only what patch-skip.txt names, fail on anything
# else, so a pkgs bump that adds a patch we cannot apply stops the build instead of dropping a fix.
gate_kernel_patches() {
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
}

# Merge the fragment, reconcile with olddefconfig, then verify every bake-in before compiling, so an unmet
# dependency fails in seconds rather than after a 40-minute build.
inject_config_merge() {
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
}

# The pkgs checkout is already dirty from the rewrites above, and `--dirty` is a flag not a content hash, so
# this is the same string `make kernel` computes for the image tag.
resolve_kernel_image_refs() {
  PKGS_TAG="$(cd "$CHK/pkgs" && git describe --tag --always --dirty --match 'v[0-9]*')"
  KIMG="${REGISTRY_HOST}/${REGISTRY_USER}/kernel:${PKGS_TAG}"
  KERNEL_CACHE_REF="${IMAGE_REPO}:kernel-${KERNEL_KEY}"
}

# Fill the cross-run cache. Silently skipped without a token, so a local build never asks for one.
push_kernel_cache() {
  local token
  token="${GHCR_TOKEN:-${GITHUB_TOKEN:-}}"
  [ -n "$token" ] || return 0
  if printf '%s' "$token" | docker login "$GHCR_SERVER" -u "${GHCR_USER:-${GITHUB_REPOSITORY%%/*}}" --password-stdin >/dev/null 2>&1; then
    docker pull -q "$KIMG" >/dev/null 2>&1 && docker tag "$KIMG" "$KERNEL_CACHE_REF" \
      && docker push -q "$KERNEL_CACHE_REF" >/dev/null 2>&1 \
      && echo "   cached as ${KERNEL_CACHE_REF}" \
      || warn "could not cache the kernel image; the next run will recompile"
  else
    warn "GHCR login failed, kernel not cached; the next run will recompile"
  fi
  return 0
}

# A cold compile is over an hour and CI runners are ephemeral, so reuse a kernel built from identical inputs.
# KERNEL_KEY covers the pkgs commit, the linux commit, the config fragment and the patch-skip list and nothing
# else, so editing this script or bumping the overlay does not throw the kernel away.
build_or_reuse_kernel() {
  if [ "${KERNEL_CACHE:-true}" = "true" ] && docker pull -q "$KERNEL_CACHE_REF" >/dev/null 2>&1; then
    say "reusing the cached kernel ${KERNEL_CACHE_REF}, skipping the compile"
    docker tag "$KERNEL_CACHE_REF" "$KIMG"
    docker push -q "$KIMG" >/dev/null || die "cannot push the cached kernel into the local registry"
  else
    say "build kernel (clang/ThinLTO, the long pole; verifies bake-ins early then compiles)"
    "$GMAKE" -f "$TALOS_MK" CHECKOUTS="$CHK" REGISTRY="$REGISTRY_HOST" REGISTRY_USERNAME="$REGISTRY_USER" kernel
    push_kernel_cache
  fi
}

# The kernel image is in the local registry now, so BuildKit's cache is disposable and it is where the tens of
# GB sit. But throwing it away costs a full recompile on any retry, so only do it when space is short: the
# GitHub runner pool is heterogeneous, usually ~114 GB free here, occasionally ~20 GB.
prune_buildkit_cache_if_tight() {
  local free_mb
  free_mb="$(df -Pm "$BUILD_DIR" | awk 'NR==2 {print $4}')"
  if [ "${PRUNE_BUILD_CACHE:-false}" = "true" ] && [ "${free_mb:-0}" -lt "${PRUNE_BELOW_MB:-40000}" ]; then
    say "only ${free_mb} MB free, pruning the BuildKit cache"
    docker buildx prune -af >/dev/null 2>&1 || true
    df -Pm "$BUILD_DIR" | awk 'NR==2 {print "   now " $4 " MB free"}'
  else
    echo "   ${free_mb} MB free, keeping the BuildKit cache for a cheap retry"
  fi
}

# The stock list names drivers our config does not build (bnxt_re and friends), and nvme is built in rather
# than a module, so the initramfs step fails on the first missing .ko. Intersect it with the real module tree.
filter_module_list() {
  local cid mf
  say "REBASE 2, filter modules-arm64.txt to modules the kernel actually built"
  docker pull -q "$KIMG" >/dev/null
  cid="$(docker create "$KIMG" sh)"; docker export "$cid" 2>/dev/null | tar t 2>/dev/null > "$BUILD_DIR/kfiles.txt"; docker rm "$cid" >/dev/null
  # One awk reading the FILE, not `grep ... | head -1`: that SIGPIPEs grep on a large listing and pipefail
  # kills the build. A STRING regex, not /.../: an unescaped slash inside [^/] would end a regex literal.
  KVER="$(awk 'match($0, "usr/lib/modules/[^/]+") { s=substr($0, RSTART, RLENGTH); sub(/.*\//, "", s); print s; exit }' "$BUILD_DIR/kfiles.txt")"
  [ -n "$KVER" ] || die "no module tree in ${KIMG}; the kernel build produced no modules"
  grep "usr/lib/modules/${KVER}/" "$BUILD_DIR/kfiles.txt" | sed "s#usr/lib/modules/${KVER}/##" | grep -vE '/$' | sort -u > "$BUILD_DIR/kexist.txt"
  mf="$CHK/talos/hack/modules-arm64.txt"
  grep -Fxf "$BUILD_DIR/kexist.txt" "$mf" > "$mf.new" && mv "$mf.new" "$mf"
  keep_describe_clean hack/modules-arm64.txt
  echo "   modules list pinned to kernel ${KVER}"
}

# A modified file makes `git describe --dirty` report `-dirty`, and that string stamps the OS version
# (--build-arg=TAG), so nodes would report <version>-dirty and a clean talosctl would call it "older than
# client" (semver ranks a -dirty prerelease below the clean release). assume-unchanged keeps describe clean
# while the modified content still feeds the build. Idempotent across re-runs.
keep_describe_clean() {
  git -C "$CHK/talos" update-index --assume-unchanged "$1"
}

# Both halves rather than a reconciled dump: the reconciled .config only exists inside a build stage that
# ships nothing, and `stock + fragment + olddefconfig` is the complete statement of what was compiled anyway.
stage_kernel_config_assets() {
  cp "$CHK/pkgs/kernel/build/config-arm64" "$OUT_DIR/kernel-config-arm64.base"
  cp "${REPO_ROOT}/kernel/pi5-rpi.fragment" "$OUT_DIR/kernel-config-arm64.fragment"
}

# The overlay copies u-boot, config.txt and the dtbs onto the EFI partition. It targets older machinery, and a
# newer Talos's overlay API added a ctx argument to every method, so it will not compile as-is.
port_overlay_to_machinery() {
  local osrc="$CHK/sbc-raspberrypi5/installers/rpi5/src"
  say "REBASE 3, port sbc-raspberrypi5 overlay to machinery ${MACHINERY_VERSION}"
  ( cd "$osrc" && GOWORK=off GOFLAGS=-mod=mod go get "github.com/siderolabs/talos/pkg/machinery@${MACHINERY_VERSION}" && GOWORK=off go mod tidy )
  perl -i -pe 's/adapter\.Execute\(&RpiInstaller\{\}\)/adapter.Execute(context.Background(), &RpiInstaller{})/' "$osrc/main.go"
  perl -i -pe 's/func \(i \*RpiInstaller\) GetOptions\(extra/func (i *RpiInstaller) GetOptions(_ context.Context, extra/' "$osrc/main.go"
  perl -i -pe 's/func \(i \*RpiInstaller\) Install\(options/func (i *RpiInstaller) Install(_ context.Context, options/' "$osrc/main.go"
  grep -q '"context"' "$osrc/main.go" || perl -0pi -e 's/(import \(\n)/$1\t"context"\n/' "$osrc/main.go"
  ( cd "$osrc" && GOWORK=off CGO_ENABLED=0 go build -o /dev/null . ) || die "overlay does not compile against ${MACHINERY_VERSION}"
}

build_overlay() {
  say "build overlay"
  "$GMAKE" -f "$TALOS_MK" CHECKOUTS="$CHK" REGISTRY="$REGISTRY_HOST" REGISTRY_USERNAME="$REGISTRY_USER" overlay
}

# Talos's Dockerfile names a `# syntax =` frontend image that BuildKit fetches from Docker Hub with a 60s
# deadline it misses often enough to fail whole builds. Republish it locally and point the Dockerfile there,
# so the build stops depending on Hub reachability and works offline on a re-run.
mirror_dockerfile_frontend() {
  local dockerfile="$CHK/talos/Dockerfile" upstream local_ref anon_cfg d
  upstream="$(awk 'NR==1 && /^#[[:space:]]*syntax[[:space:]]*=/{print $NF}' "$dockerfile")"
  [ -n "$upstream" ] || die "no '# syntax =' on line 1 of the talos Dockerfile (upstream changed?)"
  local_ref="${REGISTRY_HOST}/${REGISTRY_USER}/dockerfile-frontend:$(printf '%s' "$upstream" | sha256hex | cut -c1-12)"
  say "mirror the Dockerfile frontend ${upstream} -> local registry"
  if ! docker pull -q "$upstream" >/dev/null 2>&1; then
    # Stale stored Docker Hub credentials are the usual cause and docker does not fall back on its own. The
    # image is public, so retry with the credentials stripped rather than making the user fix their keychain.
    warn "authenticated pull failed; retrying anonymously (your stored Docker Hub credentials look stale, 'docker login' would fix them)"
    anon_cfg="$(mktemp -d)"
    jq 'del(.credsStore) | del(.credHelpers) | .auths = {}' "${DOCKER_CONFIG:-${HOME}/.docker}/config.json" \
      > "${anon_cfg}/config.json" 2>/dev/null || printf '{}' > "${anon_cfg}/config.json"
    for d in contexts cli-plugins; do
      [ -e "${DOCKER_CONFIG:-${HOME}/.docker}/$d" ] && ln -s "${DOCKER_CONFIG:-${HOME}/.docker}/$d" "${anon_cfg}/$d"
    done
    DOCKER_CONFIG="$anon_cfg" docker pull -q "$upstream" >/dev/null \
      || die "cannot pull ${upstream} from Docker Hub, authenticated or anonymously (is Hub reachable?)"
  fi
  docker tag "$upstream" "$local_ref"
  docker push -q "$local_ref" >/dev/null || die "cannot push ${local_ref} to the local registry"
  perl -i -pe "s{^#\\s*syntax\\s*=.*}{# syntax = ${local_ref}}" "$dockerfile"
  keep_describe_clean Dockerfile
}

build_installer_and_image() {
  local imager_raw_xz
  say "build installer + imager -> raw disk image (grub/rpi5 profile)"
  "$GMAKE" -f "$TALOS_MK" CHECKOUTS="$CHK" REGISTRY="$REGISTRY_HOST" REGISTRY_USERNAME="$REGISTRY_USER" \
    EXTENSIONS="${ISCSI_EXT} ${UTIL_EXT}" installer
  # The imager writes under the metal name even on the rpi5 profile; glob as a fallback so an upstream rename
  # does not silently look like a build failure.
  imager_raw_xz="$CHK/talos/_out/metal-arm64.raw.xz"
  if [ ! -f "$imager_raw_xz" ]; then
    imager_raw_xz="$(find "$CHK/talos/_out" -maxdepth 1 -name '*.raw.xz' | head -1)"
    [ -n "$imager_raw_xz" ] || die "the imager produced no .raw.xz in $CHK/talos/_out"
    warn "imager output is $(basename "$imager_raw_xz"), not metal-arm64.raw.xz"
  fi
  cp "$imager_raw_xz" "${OUT_DIR}/${IMAGE_NAME}"
}

# What only the build knows. validate.sh and publish.sh read this back.
write_build_meta() {
  TALOS_TAG="$(cd "$CHK/talos" && git describe --tag --always --dirty --match 'v[0-9]*')"
  SBCOVERLAY_TAG="$(cd "$CHK/sbc-raspberrypi5" && git describe --tag --always --dirty)-${PKGS_TAG}"
cat > "$META_FILE" <<EOF
KVER="${KVER}"
PKGS_TAG="${PKGS_TAG}"
TALOS_TAG="${TALOS_TAG}"
SBCOVERLAY_TAG="${SBCOVERLAY_TAG}"
KERNEL_TARBALL_SHA256="${KSHA256}"
INSTALLER_IMG="${REGISTRY_HOST}/${REGISTRY_USER}/installer:${TALOS_TAG}-arm64"
IMAGE_FILE="${OUT_DIR}/${IMAGE_NAME}"
EOF
}

print_result() {
  say "BUILD COMPLETE"
  echo "   image:     ${OUT_DIR}/${IMAGE_NAME}"
  echo "   installer: ${REGISTRY_HOST}/${REGISTRY_USER}/installer:${TALOS_TAG}-arm64  (local registry)"
  echo "   kernel:    ${KVER}"
  echo "   next:      make validate"
}

# ---- main ----

require docker git curl jq go python3 perl crane
load_inputs
derive_paths
check_prerequisites
start_local_registry
start_buildx_builder
clone_upstream
assert_pkgs_matches_resolver
assert_patch_skips_exist

say "REBASE 1, kernel source -> raspberrypi/linux ${KERNEL_COMMIT:0:12} (${KERNEL_VERSION}, from ${KERNEL_SOURCE}) + Pi 5 fragment"
fetch_kernel_source
serve_kernel_source
point_pkgs_at_rpi_kernel
stage_kernel_config
gate_kernel_patches
inject_config_merge

resolve_kernel_image_refs
build_or_reuse_kernel
prune_buildkit_cache_if_tight

filter_module_list
stage_kernel_config_assets

port_overlay_to_machinery
build_overlay
mirror_dockerfile_frontend
build_installer_and_image

write_build_meta
print_result
