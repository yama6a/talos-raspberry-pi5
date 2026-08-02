#!/usr/bin/env bash
#
# Shared helpers for every script here. Source it near the top: it self-locates the repo root, loads the
# committed versions.env, and derives what a flat file cannot hold.
# It sets no shell options; each script keeps its own `set` line.

[[ -n "${_COMMON_SH:-}" ]] && return
_COMMON_SH=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERSIONS_FILE="${REPO_ROOT}/versions.env"
if [ ! -f "$VERSIONS_FILE" ]; then
  # die() is not defined yet, so error raw.
  printf '\033[1;31mERROR: missing %s (committed recipe; it should be in the repo checkout)\033[0m\n' \
    "$VERSIONS_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$VERSIONS_FILE"

MACHINERY_VERSION="${TALOS_VERSION}"        # the overlay is rebuilt against this (must match TALOS_VERSION)
IMAGE_NAME="metal-arm64-rpi5.raw.xz"        # the staged raw disk image (the rpi5/grub imager emits .raw.xz)

# GHCR namespace. Derived from the repo slug, lowercased because GHCR rejects uppercase, so a fork publishes
# to its own namespace with no edit. CI sets GITHUB_REPOSITORY; locally it falls back to upstream.
GHCR_SERVER="ghcr.io"
: "${GITHUB_REPOSITORY:=yama6a/talos-raspberry-pi5}"
IMAGE_REPO="${GHCR_SERVER}/$(printf '%s' "$GITHUB_REPOSITORY" | tr '[:upper:]' '[:lower:]')"

CACHE_DIR="${REPO_ROOT}/.cache"
INPUTS_FILE="${CACHE_DIR}/build-inputs.json"   # written by resolve_inputs.sh, read by everything after it

say()  { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; }

PASS=0; FAIL=0
ok()  { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
# Returns non-zero if anything failed, so a caller can `summary || exit 1`.
summary() {
  printf '\n=============== summary: %d passed, %d failed ===============\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

require() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null && continue
    case "$t" in
      docker) die "docker not found on PATH (Docker Desktop, Rancher Desktop or docker.io; needs an arm64 Linux VM)" ;;
      jq)     die "jq not found on PATH (brew install jq / apt install jq)" ;;
      go)     die "go not found on PATH (https://go.dev/dl/); the overlay is rebuilt from source" ;;
      zstd)   die "zstd not found on PATH (brew install zstd / apt install zstd)" ;;
      xz)     die "xz not found on PATH (brew install xz / apt install xz-utils)" ;;
      gh)     die "gh not found on PATH (https://cli.github.com/); only publish needs it" ;;
      crane)  die "crane not found on PATH (brew install crane, or the go-containerregistry release binary). Talos's own installer target shells out to it" ;;
      *)      die "$t not found on PATH" ;;
    esac
  done
}

# macOS ships `shasum` and no `sha256sum`; most Linux images ship both. Prefer the coreutils tool.
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
sha512() { if command -v sha512sum >/dev/null; then sha512sum "$@"; else shasum -a 512 "$@"; fi; }
# Hash stdin or a file down to the bare hex, no filename column.
sha256hex() { sha256 "$@" | awk '{print $1}'; }
sha512hex() { sha512 "$@" | awk '{print $1}'; }

# The kres Makefiles upstream need GNU make >= 4; macOS's /usr/bin/make is 3.81 and dies with "missing
# separator". Homebrew installs GNU make as `gmake`, Linux ships it as `make`, so probe rather than hardcode.
# Echoes the absolute path; the caller puts its dir first on PATH so recursive $(MAKE) resolves to it too.
gnu_make() {
  local m
  for m in gmake make; do
    command -v "$m" >/dev/null || continue
    # Captured, not piped into head/grep -q: an early-exiting consumer can SIGPIPE the producer, and every
    # caller of this runs under pipefail.
    case "$("$m" --version 2>/dev/null)" in "GNU Make "[4-9]*|"GNU Make "[1-9][0-9]*) ;; *) continue ;; esac
    command -v "$m"; return 0
  done
  die "GNU make >= 4 not found (macOS: brew install make, which installs it as gmake; Debian/Ubuntu: apt install make)"
}

# load_inputs: read the resolver's build-inputs.json into shell vars and derive the cache paths from it.
# Every script after resolve_inputs.sh calls this.
load_inputs() {
  [ -f "$INPUTS_FILE" ] || die "missing ${INPUTS_FILE}, run: make resolve"
  local j="$INPUTS_FILE"
  PKGS_REF=$(jq -r '.pkgs_ref' "$j")            # the exact pkgs commit Talos names in its Makefile
  PKGS_DESC=$(jq -r '.pkgs_describe' "$j")      # ... as `git describe` renders it, which tags the kernel image
  KERNEL_VERSION=$(jq -r '.kernel_version' "$j")
  KERNEL_COMMIT=$(jq -r '.kernel_commit' "$j")
  KERNEL_SOURCE=$(jq -r '.kernel_source' "$j")  # which firmware ref we found the commit through
  BUILD_KEY=$(jq -r '.build_key' "$j")
  FINGERPRINT=$(jq -r '.fingerprint' "$j")
  KERNEL_KEY=$(jq -r '.kernel_key' "$j")   # narrower than the fingerprint: keys the cross-run kernel cache
  [ "$(jq -r '.talos' "$j")" = "$TALOS_VERSION" ] \
    || die "${INPUTS_FILE} was resolved for $(jq -r '.talos' "$j"), but versions.env now says ${TALOS_VERSION}. Re-run: make resolve"
  BUILD_DIR="${CACHE_DIR}/${BUILD_KEY}"   # build scratch: upstream checkouts, kernel tarball, staged image
  OUT_DIR="${BUILD_DIR}/out"              # release artifacts land here
  META_FILE="${OUT_DIR}/build-meta.env"   # what the build resolved only by building; validate/publish read it
}

# load_meta: the build's own output facts (kernel version actually compiled, the image tags it produced).
load_meta() {
  [ -f "$META_FILE" ] || die "missing ${META_FILE}, run: make build"
  # shellcheck disable=SC1090
  source "$META_FILE"
}
