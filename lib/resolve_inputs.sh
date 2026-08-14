#!/usr/bin/env bash
# Resolves what the Talos release implies but does not pin: the pkgs commit, the kernel version it expects,
# and the raspberrypi/linux commit carrying that version. Writes .cache/build-inputs.json.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
RAW="https://raw.githubusercontent.com"
API="https://api.github.com"
FW_CHANNELS="master stable next oldstable"  # raspberrypi/firmware refs to try first; master is its current kernel
FW_HISTORY_PAGE=100                         # failsafe: how far back to walk master's extra/git_hash history
# Only files that can change what gets built, so editing one cuts a new build revision. Docs, workflows and
# the renovate config are excluded because they cannot.
RECIPE_FILES="lib/build.sh build/Makefile.talos kernel/pi5-rpi.fragment kernel/patch-skip.txt"

# ---- state ----
AUTH=()             # set by use_github_token, read by get
PKGS_DESC=""        # set by resolve_pkgs
PKGS_REF=""
KERNEL_VERSION=""   # set by resolve_kernel_version
KERNEL_COMMIT=""    # set by resolve_kernel_commit
KERNEL_SOURCE=""
BUILD_KEY=""        # set by compute_keys
RECIPE_HASH=""
FINGERPRINT=""
KERNEL_KEY=""

# ---- functions ----

# GitHub allows 60 unauthenticated requests an hour and walk_firmware_history can spend most of that.
use_github_token() {
  [ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  return 0
}

# Buffers the whole response: piping curl into an early-exiting awk/head closes the pipe under it and curl
# fails the pipeline with exit 56.
get() { curl -fsSL --retry 3 ${AUTH[@]+"${AUTH[@]}"} "$@"; }

# Talos names the pkgs commit in its own Makefile, as `<tag>-<n>-g<sha>` or a bare tag.
resolve_pkgs() {
  local makefile
  makefile="$(get "${RAW}/siderolabs/talos/${TALOS_VERSION}/Makefile")" \
    || die "cannot fetch siderolabs/talos ${TALOS_VERSION}'s Makefile (does the tag exist?)"
  PKGS_DESC="$(printf '%s\n' "$makefile" | awk -F' *\\?= *' '/^PKGS \?=/{print $2; exit}')"
  [ -n "$PKGS_DESC" ] || die "could not read PKGS from siderolabs/talos ${TALOS_VERSION}'s Makefile (upstream moved the line?)"
  case "$PKGS_DESC" in *-g*) PKGS_REF="${PKGS_DESC##*-g}" ;; *) PKGS_REF="$PKGS_DESC" ;; esac
  echo "   pkgs        ${PKGS_DESC}  (commit ${PKGS_REF})"
}

# The imager stamps Talos's hardcoded kernel version onto the boot image whatever we compile, so we build
# exactly that version rather than pinning one of our own.
resolve_kernel_version() {
  local constants
  constants="$(get "${RAW}/siderolabs/talos/${TALOS_VERSION}/pkg/machinery/constants/constants.go")" \
    || die "cannot fetch constants.go from siderolabs/talos ${TALOS_VERSION}"
  KERNEL_VERSION="$(printf '%s\n' "$constants" \
    | grep -oE 'DefaultKernelVersion = "[0-9]+\.[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  [ -n "$KERNEL_VERSION" ] || die "could not read DefaultKernelVersion from siderolabs/talos ${TALOS_VERSION} (constants.go moved?)"
  echo "   kernel      ${KERNEL_VERSION}  (what Talos ${TALOS_VERSION} expects)"
}

# firmware_kernel <firmware-ref> -> "<linux-commit><TAB><version>", non-zero if that ref has no usable hash.
firmware_kernel() {
  local h mk
  h="$(get "${RAW}/raspberrypi/firmware/$1/extra/git_hash" 2>/dev/null | tr -d '[:space:]')" || return 1
  [[ "$h" =~ ^[0-9a-f]{40}$ ]] || return 1
  mk="$(get "${RAW}/raspberrypi/linux/$h/Makefile" 2>/dev/null)" || return 1
  printf '%s\t%s' "$h" "$(printf '%s\n' "$mk" \
    | awk -F' *= *' '/^VERSION/{v=$2}/^PATCHLEVEL/{p=$2}/^SUBLEVEL/{s=$2} END{print v"."p"."s}')"
}

# raspberrypi/linux has no per-version tags, only rebased branches, so map version to commit through
# raspberrypi/firmware: each ref's extra/git_hash names the linux commit its kernel was built from.
scan_firmware_channels() {
  local b o
  for b in $FW_CHANNELS; do
    o="$(firmware_kernel "$b" || true)"
    if [ -n "$o" ] && [ "${o##*$'\t'}" = "$KERNEL_VERSION" ]; then
      KERNEL_COMMIT="${o%%$'\t'*}"; KERNEL_SOURCE="firmware/${b}"; return 0
    fi
  done
  return 1
}

# master's extra/git_hash history is a dense index of every recent kernel, newest first.
walk_firmware_history() {
  local hist c o
  warn "no firmware channel HEAD carries ${KERNEL_VERSION}; walking master's extra/git_hash history"
  hist="$(get "${API}/repos/raspberrypi/firmware/commits?path=extra/git_hash&sha=master&per_page=${FW_HISTORY_PAGE}" 2>/dev/null || true)"
  for c in $(printf '%s' "$hist" | jq -r '.[].sha' 2>/dev/null); do
    o="$(firmware_kernel "$c" || true)"
    if [ -n "$o" ] && [ "${o##*$'\t'}" = "$KERNEL_VERSION" ]; then
      KERNEL_COMMIT="${o%%$'\t'*}"; KERNEL_SOURCE="firmware master@${c:0:10}"; return 0
    fi
  done
  return 1
}

resolve_kernel_commit() {
  scan_firmware_channels || walk_firmware_history || true
  [[ "$KERNEL_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "no raspberrypi/firmware ref provides linux ${KERNEL_VERSION} (what Talos ${TALOS_VERSION} expects).
Checked channels ${FW_CHANNELS} plus master's last ${FW_HISTORY_PAGE} extra/git_hash commits.
Resolve by hand (docs/kernel.md, 'If kernel resolution fails'), then either wait for a firmware channel to ship ${KERNEL_VERSION} or move TALOS_VERSION."
  echo "   linux       ${KERNEL_COMMIT}  (via ${KERNEL_SOURCE})"
}

# build_key names the cache dir and covers UPSTREAM inputs only, so editing a build script reuses the
# existing checkouts and kernel tarball. fingerprint adds the recipe and is what CI compares to decide
# whether to rebuild. kernel_key covers only what goes into the kernel image, so the cross-run kernel cache
# survives an edit to this script or to the overlay/extension pins.
compute_keys() {
  local f
  BUILD_KEY="${TALOS_VERSION}-$(printf '%s' \
    "${PKGS_REF}|${KERNEL_COMMIT}|${SBCOVERLAY_VERSION}|${ISCSI_EXT}|${UTIL_EXT}" | sha256hex | cut -c1-8)"
  RECIPE_HASH="$(cd "$REPO_ROOT" && for f in $RECIPE_FILES; do
    [ -f "$f" ] || die "recipe file ${f} is missing; RECIPE_FILES in resolve_inputs.sh is stale"
    sha256hex "$f"
  done | sha256hex)"
  FINGERPRINT="$(printf '%s' "${BUILD_KEY}|${MACHINERY_VERSION}|${RECIPE_HASH}" | sha256hex)"
  KERNEL_KEY="$(printf '%s' "${PKGS_REF}|${KERNEL_COMMIT}|$(sha256hex "${REPO_ROOT}/kernel/pi5-rpi.fragment")|$(sha256hex "${REPO_ROOT}/kernel/patch-skip.txt")" | sha256hex | cut -c1-16)"
}

# Both the build's input and the release's provenance record.
write_inputs_file() {
  mkdir -p "$CACHE_DIR"
  jq -n \
    --arg talos "$TALOS_VERSION" --arg pkgs_ref "$PKGS_REF" --arg pkgs_describe "$PKGS_DESC" \
    --arg kernel_version "$KERNEL_VERSION" --arg kernel_commit "$KERNEL_COMMIT" --arg kernel_source "$KERNEL_SOURCE" \
    --arg overlay "$SBCOVERLAY_VERSION" --arg iscsi_ext "$ISCSI_EXT" --arg util_ext "$UTIL_EXT" \
    --arg build_key "$BUILD_KEY" --arg recipe_hash "$RECIPE_HASH" --arg fingerprint "$FINGERPRINT" \
    --arg kernel_key "$KERNEL_KEY" \
    '{talos: $talos,
      pkgs_ref: $pkgs_ref, pkgs_describe: $pkgs_describe,
      kernel_version: $kernel_version, kernel_commit: $kernel_commit, kernel_source: $kernel_source,
      kernel_url: ("https://github.com/raspberrypi/linux/tree/" + $kernel_commit),
      overlay: $overlay, overlay_url: ("https://github.com/talos-rpi5/sbc-raspberrypi5/tree/" + $overlay),
      iscsi_ext: $iscsi_ext, util_ext: $util_ext,
      build_key: $build_key, recipe_hash: $recipe_hash, fingerprint: $fingerprint,
      kernel_key: $kernel_key}' \
    > "$INPUTS_FILE"
}

print_result() {
  say "resolved"
  echo "   build key   ${BUILD_KEY}"
  echo "   fingerprint ${FINGERPRINT}"
  echo "   kernel key  ${KERNEL_KEY}"
  echo "   written     ${INPUTS_FILE}"
}

# ---- main ----

require curl jq
use_github_token
say "resolving build inputs for Talos ${TALOS_VERSION}"
resolve_pkgs
resolve_kernel_version
resolve_kernel_commit
compute_keys
write_inputs_file
print_result
