#!/usr/bin/env bash
# The cheap half of the build: the upstream checkouts still look the way the build expects, the files the
# build rewrites still have their anchors, and the overlay still builds against this Talos's machinery. No
# Docker, no kernel source, no compiler.
#
# Doubles as build.sh's library: build.sh sources this file and calls the same functions, so a check here can
# never drift from what the build actually does. Some functions below are only used by build.sh.
#
# Scope is deliberate. Anything needing the kernel tree is left to the real build, because a bad bump costs
# one red build workflow and nothing else: build.yaml gates publish and release on the build succeeding.
set -euo pipefail

[[ -n "${_PREFLIGHT_SH:-}" ]] && return 0
_PREFLIGHT_SH=1

_PREFLIGHT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_PREFLIGHT_DIR}/common.sh"

# ---- state shared with build.sh ----
GMAKE=""            # set by setup_gmake
TALOS_MK=""         # set by derive_paths, after load_inputs supplies BUILD_DIR
CHK=""
PKGS_PATCH_SKIP=""
SRCDIR=""           # set by fetch_kernel_source
KSHA256=""
KSHA512=""
BAKEINS=""          # set by stage_kernel_config

derive_paths() {
  TALOS_MK="${REPO_ROOT}/build/Makefile.talos"
  CHK="${BUILD_DIR}/checkouts"
  PKGS_PATCH_SKIP="$(grep -vE '^[[:space:]]*(#|$)' "${REPO_ROOT}/kernel/patch-skip.txt")"
}

# The upstream Makefiles need GNU make >= 4 and recurse into $(MAKE), so its dir goes first on PATH.
setup_gmake() {
  local gmake_dir
  GMAKE="$(gnu_make)"
  gmake_dir="$(dirname "$GMAKE")"
  export PATH="${gmake_dir}:${PATH}"
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

# pkgs ships a stock arm64 config. Point the kernel source at raspberrypi/linux, for the RP1 and BCM2712
# drivers that exist only in that fork, and fetch it from the local server instead of cdn.kernel.org.
point_pkgs_at_rpi_kernel() {
  local port="${1:?srcserver port}"
  perl -0pi -e "s/  linux_version: .*\n  linux_sha256: .*\n  linux_sha512: .*\n/  linux_version: ${KERNEL_COMMIT}\n  linux_sha256: ${KSHA256}\n  linux_sha512: ${KSHA512}\n/" "$CHK/pkgs/Pkgfile"
  # .* rather than \S+ because the stock cdn URL has spaces inside a {{ }} template.
  perl -0pi -e 's{- url: https://cdn\.kernel\.org/.*\.tar\.xz\n\s+destination: linux\.tar\.xz}{- url: "http://localhost:'"${port}"'/linux.tar.gz"\n        destination: linux.tar.gz}' "$CHK/pkgs/kernel/prepare/pkg.yaml"
  perl -i -pe 's/tar -xJf linux\.tar\.xz/tar -xzf linux.tar.gz/' "$CHK/pkgs/kernel/prepare/pkg.yaml"
  grep -q 'localhost:'"${port}" "$CHK/pkgs/kernel/prepare/pkg.yaml" || die "kernel source URL rewrite failed"
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

# Talos's Dockerfile names a `# syntax =` frontend image on line 1. build.sh republishes it locally; both need
# to find it, and an upstream restructure that drops the line is a build failure worth catching early.
dockerfile_frontend_ref() {
  local upstream
  upstream="$(awk 'NR==1 && /^#[[:space:]]*syntax[[:space:]]*=/{print $NF}' "$CHK/talos/Dockerfile")"
  [ -n "$upstream" ] || die "no '# syntax =' on line 1 of the talos Dockerfile (upstream changed?)"
  printf '%s' "$upstream"
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

preflight_print_result() {
  say "PREFLIGHT PASSED"
  echo "   talos      ${TALOS_VERSION}"
  echo "   pkgs       ${PKGS_DESC}"
  echo "   kernel     ${KERNEL_VERSION} (${KERNEL_COMMIT:0:12}, via ${KERNEL_SOURCE})"
  echo "   overlay    ${SBCOVERLAY_VERSION:0:12} builds against machinery ${MACHINERY_VERSION}"
  echo
  echo "   Not proven, and only a real build can: the pkgs patches still apply to the rpi fork, the config"
  echo "   fragment survives olddefconfig, the kernel compiles, the imager produces a bootable image."
}

# ---- main, only when run directly ----

preflight_main() {
  require git curl jq go python3 perl
  load_inputs
  derive_paths
  setup_gmake
  mkdir -p "$BUILD_DIR"
  clone_upstream
  assert_pkgs_matches_resolver
  assert_patch_skips_exist

  # Deliberately no kernel tarball here. Replaying the patch series and olddefconfig on the host would need a
  # 250 MB download and a clang that is not the one in the pkgs toolchain image, to pre-empt a failure whose
  # entire cost is one red build workflow: build.yaml gates publish and release on the build succeeding, so a
  # bad bump never reaches GHCR or a release. Not worth the machinery. The rewrites below still get checked,
  # because they are pure file edits and cost nothing.
  say "checking the rewrites the build makes to upstream files still have their anchors"
  stage_kernel_config
  gate_kernel_patches
  inject_config_merge
  echo "   kernel/build/pkg.yaml took both rewrites"
  dockerfile_frontend_ref >/dev/null && echo "   talos Dockerfile still declares a '# syntax =' frontend"

  port_overlay_to_machinery

  preflight_print_result
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  preflight_main
fi
