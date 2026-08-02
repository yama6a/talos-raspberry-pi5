#!/usr/bin/env bash
# Resolves everything the build needs but does not pin: which siderolabs/pkgs commit the Talos release was
# built against, which kernel version it expects, and which raspberrypi/linux commit carries that version.
# Pure curl + jq, no clones, a few seconds. Writes .cache/build-inputs.json, which is both the build's input
# and the release's provenance record. See docs/kernel.md for why the kernel is derived and never pinned.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
RAW="https://raw.githubusercontent.com"
API="https://api.github.com"
FW_CHANNELS="master stable next oldstable"  # raspberrypi/firmware refs to try first; master is its current kernel
FW_HISTORY_PAGE=100                         # failsafe: how far back to walk master's extra/git_hash history
# Files whose contents change the image. Hashed into the fingerprint, so editing one cuts a new build
# revision. NOT the docs, README, workflows or renovate config: those cannot change what gets built.
RECIPE_FILES="lib/build.sh build/Makefile.talos kernel/pi5-rpi.fragment kernel/patch-skip.txt"

require curl jq

# GitHub's unauthenticated API allows 60 requests an hour, and the failsafe below can spend most of that in
# one run. CI has a token; use it when present.
_auth=()
[ -n "${GITHUB_TOKEN:-}" ] && _auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
# Every fetch buffers the whole response before parsing. Piping curl into an early-exiting awk/head closes the
# pipe under it and curl fails the pipeline with exit 56.
get() { curl -fsSL --retry 3 ${_auth[@]+"${_auth[@]}"} "$@"; }

say "resolving build inputs for Talos ${TALOS_VERSION}"

# Talos names the pkgs commit it built against in its own Makefile, as `<tag>-<n>-g<sha>` or a bare tag.
TALOS_MAKEFILE=$(get "${RAW}/siderolabs/talos/${TALOS_VERSION}/Makefile") \
  || die "cannot fetch siderolabs/talos ${TALOS_VERSION}'s Makefile (does the tag exist?)"
PKGS_DESC=$(printf '%s\n' "$TALOS_MAKEFILE" | awk -F' *\\?= *' '/^PKGS \?=/{print $2; exit}')
[ -n "$PKGS_DESC" ] || die "could not read PKGS from siderolabs/talos ${TALOS_VERSION}'s Makefile (upstream moved the line?)"
case "$PKGS_DESC" in *-g*) PKGS_REF="${PKGS_DESC##*-g}" ;; *) PKGS_REF="$PKGS_DESC" ;; esac
echo "   pkgs        ${PKGS_DESC}  (commit ${PKGS_REF})"

# Talos hardcodes the kernel version it expects, and the imager stamps THAT onto the boot image's version
# field whatever we compile. So we build exactly that version rather than pinning one of our own.
TALOS_CONSTANTS=$(get "${RAW}/siderolabs/talos/${TALOS_VERSION}/pkg/machinery/constants/constants.go") \
  || die "cannot fetch constants.go from siderolabs/talos ${TALOS_VERSION}"
KERNEL_VERSION=$(printf '%s\n' "$TALOS_CONSTANTS" \
  | grep -oE 'DefaultKernelVersion = "[0-9]+\.[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
[ -n "$KERNEL_VERSION" ] || die "could not read DefaultKernelVersion from siderolabs/talos ${TALOS_VERSION} (constants.go moved?)"
echo "   kernel      ${KERNEL_VERSION}  (what Talos ${TALOS_VERSION} expects)"

# raspberrypi/linux has no per-version tags, only rebased branches, so map version to commit through
# raspberrypi/firmware: each firmware ref's extra/git_hash names the linux commit its kernel was built from.
# _fw_kver <firmware-ref> -> "<linux-commit><TAB><version>", non-zero if that ref has no usable hash.
_fw_kver() {
  local h mk
  h=$(get "${RAW}/raspberrypi/firmware/$1/extra/git_hash" 2>/dev/null | tr -d '[:space:]') || return 1
  [[ "$h" =~ ^[0-9a-f]{40}$ ]] || return 1
  mk=$(get "${RAW}/raspberrypi/linux/$h/Makefile" 2>/dev/null) || return 1
  printf '%s\t%s' "$h" "$(printf '%s\n' "$mk" \
    | awk -F' *= *' '/^VERSION/{v=$2}/^PATCHLEVEL/{p=$2}/^SUBLEVEL/{s=$2} END{print v"."p"."s}')"
}

KERNEL_COMMIT=""; KERNEL_SOURCE=""
for _b in $FW_CHANNELS; do
  _o=$(_fw_kver "$_b" || true)
  if [ -n "$_o" ] && [ "${_o##*$'\t'}" = "$KERNEL_VERSION" ]; then
    KERNEL_COMMIT="${_o%%$'\t'*}"; KERNEL_SOURCE="firmware/${_b}"; break
  fi
done
# Failsafe: master's extra/git_hash history is a dense index of every recent kernel, newest first.
if [ -z "$KERNEL_COMMIT" ]; then
  warn "no firmware channel HEAD carries ${KERNEL_VERSION}; walking master's extra/git_hash history"
  _hist=$(get "${API}/repos/raspberrypi/firmware/commits?path=extra/git_hash&sha=master&per_page=${FW_HISTORY_PAGE}" 2>/dev/null || true)
  for _c in $(printf '%s' "$_hist" | jq -r '.[].sha' 2>/dev/null); do
    _o=$(_fw_kver "$_c" || true)
    if [ -n "$_o" ] && [ "${_o##*$'\t'}" = "$KERNEL_VERSION" ]; then
      KERNEL_COMMIT="${_o%%$'\t'*}"; KERNEL_SOURCE="firmware master@${_c:0:10}"; break
    fi
  done
fi
[[ "$KERNEL_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "no raspberrypi/firmware ref provides linux ${KERNEL_VERSION} (what Talos ${TALOS_VERSION} expects).
Checked channels ${FW_CHANNELS} plus master's last ${FW_HISTORY_PAGE} extra/git_hash commits.
Resolve by hand (docs/kernel.md, 'If kernel resolution fails'), then either wait for a firmware channel to ship ${KERNEL_VERSION} or move TALOS_VERSION."
echo "   linux       ${KERNEL_COMMIT}  (via ${KERNEL_SOURCE})"

# build_key names the cache dir and covers the UPSTREAM inputs only, so editing a build script reuses the
# existing checkouts and kernel tarball instead of forcing a cold rebuild.
BUILD_KEY="${TALOS_VERSION}-$(printf '%s' \
  "${PKGS_REF}|${KERNEL_COMMIT}|${SBCOVERLAY_VERSION}|${ISCSI_EXT}|${UTIL_EXT}" | sha256hex | cut -c1-8)"

# fingerprint additionally covers the build recipe, and is what CI compares to decide whether to rebuild.
RECIPE_HASH=$(cd "$REPO_ROOT" && for f in $RECIPE_FILES; do
  [ -f "$f" ] || die "recipe file ${f} is missing; RECIPE_FILES in resolve_inputs.sh is stale"
  sha256hex "$f"
done | sha256hex)
FINGERPRINT=$(printf '%s' "${BUILD_KEY}|${MACHINERY_VERSION}|${RECIPE_HASH}" | sha256hex)

mkdir -p "$CACHE_DIR"
jq -n \
  --arg talos "$TALOS_VERSION" --arg pkgs_ref "$PKGS_REF" --arg pkgs_describe "$PKGS_DESC" \
  --arg kernel_version "$KERNEL_VERSION" --arg kernel_commit "$KERNEL_COMMIT" --arg kernel_source "$KERNEL_SOURCE" \
  --arg overlay "$SBCOVERLAY_VERSION" --arg iscsi_ext "$ISCSI_EXT" --arg util_ext "$UTIL_EXT" \
  --arg build_key "$BUILD_KEY" --arg recipe_hash "$RECIPE_HASH" --arg fingerprint "$FINGERPRINT" \
  '{talos: $talos,
    pkgs_ref: $pkgs_ref, pkgs_describe: $pkgs_describe,
    kernel_version: $kernel_version, kernel_commit: $kernel_commit, kernel_source: $kernel_source,
    kernel_url: ("https://github.com/raspberrypi/linux/tree/" + $kernel_commit),
    overlay: $overlay, overlay_url: ("https://github.com/talos-rpi5/sbc-raspberrypi5/tree/" + $overlay),
    iscsi_ext: $iscsi_ext, util_ext: $util_ext,
    build_key: $build_key, recipe_hash: $recipe_hash, fingerprint: $fingerprint}' \
  > "$INPUTS_FILE"

say "resolved"
echo "   build key   ${BUILD_KEY}"
echo "   fingerprint ${FINGERPRINT}"
echo "   written     ${INPUTS_FILE}"
