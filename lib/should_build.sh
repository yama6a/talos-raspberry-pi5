#!/usr/bin/env bash
# Decides whether the resolved inputs differ from the newest published build of this Talos version. Cheap:
# resolve_inputs.sh already did the work, this only fetches one release asset.
# Prints `build=true|false` plus a reason, and appends the same to $GITHUB_OUTPUT when CI set it.
# Set FORCE=true to always answer true.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require curl jq
load_inputs

_auth=()
[ -n "${GITHUB_TOKEN:-}" ] && _auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

decide() {
  printf 'build=%s\n' "$1"
  printf '%s\n' "$2"
  [ -n "${GITHUB_OUTPUT:-}" ] && printf 'build=%s\nreason=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  exit 0
}

[ "${FORCE:-false}" = "true" ] && decide true "forced"

# The newest release for this Talos version, by build revision.
RELEASES=$(curl -fsSL --retry 3 ${_auth[@]+"${_auth[@]}"} \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases?per_page=100" 2>/dev/null || true)
LATEST=$(printf '%s' "$RELEASES" \
  | jq -r --arg t "$TALOS_VERSION" '[.[]?.tag_name | select(startswith($t + "-"))] | sort_by(ltrimstr($t + "-") | tonumber) | last // ""' 2>/dev/null)
[ -n "$LATEST" ] || decide true "no release exists for ${TALOS_VERSION} yet"

PREV=$(curl -fsSL --retry 3 ${_auth[@]+"${_auth[@]}"} \
  "https://github.com/${GITHUB_REPOSITORY}/releases/download/${LATEST}/build-inputs.json" 2>/dev/null | jq -r '.fingerprint // ""' 2>/dev/null || true)
[ -n "$PREV" ] || decide true "${LATEST} has no readable build-inputs.json to compare against"

[ "$PREV" = "$FINGERPRINT" ] \
  && decide false "inputs are identical to ${LATEST} (fingerprint ${PREV:0:12})" \
  || decide true "inputs differ from ${LATEST} (${PREV:0:12} -> ${FINGERPRINT:0:12})"
